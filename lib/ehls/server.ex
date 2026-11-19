defmodule EHLS.Server do
  @moduledoc """
  A process that owns an instance, for an application with a supervision tree. `definstance` declares the circuit; this is
  the runtime face a program uses to own one, where it wants one (as `Ecto.Repo` is beside `Ecto.Schema`):

      children = [
        {EHLS.Server, instance: {MyApp, :radio}, name: Radio, topics: [:presses], cpu: [batch: 8192]}
      ]

      EHLS.Server.call(Radio, [samples])        # radio(samples), in the server
      EHLS.Server.call(Radio, [:state, :level]) # radio(:state, :level)
      EHLS.Server.cast(Radio, [:stop])          # radio(:stop), not waiting for it
      EHLS.Server.subscribe(Radio, :presses)    # {:presses, value} to this process too

  - **Starting:** `init/1` stops and starts the instance, so a supervised application starts from the initial state
    (an instance in the FPGA runs from reset and keeps its state across a program replaced without a reset).
  - **Callers queue** in the server's mailbox, one call at a time, instead of `{:error, :busy}` from an end already in
    use. A call that raises answers `{:error, {kind, reason}}` and the server goes on; a time-out is counted.
  - **Events:** with `topics:` the server subscribes once (`EHLS.PubSub.subscribe/2`) and hands each event on to any number
    of processes (`subscribe/2`), beyond the few subscribers a topic has in the FPGA.
  - **A function on the CPU** (`on: :cpu`): with `cpu: opts` the server starts the drivers between the circuits
    (`instance(:cpu_start, opts)`) and stops them when it stops.
  - `stats/1`: calls, casts, errors, time-outs.

  It costs one message more per call: calling the instance directly stays, for what is in a hurry. One server per
  instance (it is one circuit).

  How it differs from a `GenServer` of your own:

  - **You do not write its callbacks.** `EHLS.Server` is the callback module; it is called with `call/3` / `cast/2`, as an
    `Agent` is with `Agent.get` and the like, not with messages of your own.
  - **Its state is the circuit's.** Read it through the server (`EHLS.Server.call(Radio, [:state, :level])`);
    `:sys.get_state` shows only the server's own bookkeeping.
  - **There is one circuit.** A second server for the same instance does not make a second state: both drive the one
    circuit. Two of them are two `definstance`.
  - **A restart starts the circuit from its initial state,** as a restarted GenServer loses its state; but while the
    server is down the circuit goes on running, as it does from reset.
  - **The instance can still be called directly** (`radio(samples)`), past the server's queue.
  """
  use GenServer

  @timeout 5000

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Starts a server owning `instance: {module, name}`; `name:` registers it."
  def start_link(opts) do
    case Keyword.fetch(opts, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, opts, name: name)
      :error -> GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc "The instance called with `args` in the server: `call(s, [x])` is `instance(x)`, `call(s, [:value])` `instance(:value)`."
  def call(server, args, timeout \\ @timeout) when is_list(args), do: GenServer.call(server, {:call, args}, timeout)

  @doc "As `call/3`, not waiting for the result."
  def cast(server, args) when is_list(args), do: GenServer.cast(server, {:cast, args})

  @doc "`instance(:value)`."
  def value(server), do: call(server, [:value])

  @doc "The events of `topic` (one of the server's `topics:`) to this process too, as `{topic, value}`."
  def subscribe(server, topic) when is_atom(topic), do: GenServer.call(server, {:subscribe, topic, self()})

  @doc "No more events of `topic` from the server to this process."
  def unsubscribe(server, topic) when is_atom(topic), do: GenServer.call(server, {:unsubscribe, topic, self()})

  @doc "`%{calls:, casts:, errors:, timeouts:}` so far."
  def stats(server), do: GenServer.call(server, :stats)

  @impl true
  def init(opts) do
    {module, name} =
      case Keyword.fetch(opts, :instance) do
        {:ok, {m, n}} when is_atom(m) and is_atom(n) -> {m, n}
        _ -> raise ArgumentError, "EHLS.Server: instance: {module, name} of a definstance"
      end

    # from the initial state (an instance cut by a function on the CPU has no :stop / :start of its own: its parts do)
    restart(module, name)

    topics = Keyword.get(opts, :topics, [])
    for t <- topics, do: :ok = EHLS.PubSub.subscribe(t)

    cpu =
      case Keyword.fetch(opts, :cpu) do
        {:ok, cpu_opts} -> apply(module, name, [:cpu_start, cpu_opts])
        :error -> nil
      end

    {:ok,
     %{module: module, name: name, topics: topics, cpu: cpu, subscribers: %{}, calls: 0, casts: 0, errors: 0, timeouts: 0}}
  end

  @impl true
  def handle_call({:call, args}, _from, st) do
    {reply, st} = run(args, %{st | calls: st.calls + 1})
    {:reply, reply, st}
  end

  def handle_call({:subscribe, topic, pid}, _from, st) do
    if topic in st.topics do
      subs = Map.get(st.subscribers, topic, [])
      subs = if pid in subs, do: subs, else: [pid | subs]
      {:reply, :ok, %{st | subscribers: Map.put(st.subscribers, topic, subs)}}
    else
      {:reply, {:error, {:not_a_topic_of_the_server, topic}}, st}
    end
  end

  def handle_call({:unsubscribe, topic, pid}, _from, st) do
    subs = Map.get(st.subscribers, topic, []) -- [pid]
    {:reply, :ok, %{st | subscribers: Map.put(st.subscribers, topic, subs)}}
  end

  def handle_call(:stats, _from, st) do
    {:reply, %{calls: st.calls, casts: st.casts, errors: st.errors, timeouts: st.timeouts}, st}
  end

  @impl true
  def handle_cast({:cast, args}, st) do
    {_reply, st} = run(args, %{st | casts: st.casts + 1})
    {:noreply, st}
  end

  # an event of one of the topics: to every process that asked for it
  @impl true
  def handle_info({topic, _value} = event, st) when is_atom(topic) do
    if topic in st.topics, do: for(pid <- Map.get(st.subscribers, topic, []), do: send(pid, event))
    {:noreply, st}
  end

  def handle_info(_other, st), do: {:noreply, st}

  @impl true
  def terminate(_reason, st) do
    if st.cpu != nil, do: apply(st.module, st.name, [:cpu_stop, st.cpu])
    for t <- st.topics, do: EHLS.PubSub.unsubscribe(t)
    :ok
  end

  defp restart(module, name) do
    apply(module, name, [:stop])
    apply(module, name, [:start])
  catch
    :error, reason when reason in [:function_clause, :undef] -> :ok
  end

  defp run(args, st) do
    try do
      {apply(st.module, st.name, args), st}
    catch
      :error, :timeout -> {{:error, :timeout}, %{st | timeouts: st.timeouts + 1}}
      kind, reason -> {{:error, {kind, reason}}, %{st | errors: st.errors + 1}}
    end
  end
end
