defmodule EHLS.PubSub do
  @moduledoc """
  Topics: what instances publish and processes or other instances receive, as `Phoenix.PubSub`, written with the module
  as it is.

  In a `definstance`:

  - `x |> EHLS.PubSub.broadcast(topic)` ends a pipe: each element is an event of `topic`, one value up to 32 bits, of one
    type for all its publishers;
  - `EHLS.PubSub.subscribe(topic)` starts one: the events of `topic` as a stream, in the FPGA, from any instance of the
    module.

  ```elixir
  definstance presses do
    changes(:button0, :rising) |> transform(0, &count/2) |> EHLS.PubSub.broadcast(:presses)
  end

  definstance lit do
    EHLS.PubSub.subscribe(:presses) |> map(&low_bit/1) |> pin_out(:led0)
  end
  ```

  On the CPU a process receives a topic's events as messages with `subscribe/2` (below). `EHLS.Pipeline`, "Events",
  has the rest: what each event is, how the circuit hands them over, the topics of a module.
  """

  # the runtime's queue of events runs on the board: nothing here that AtomVM's library lacks (Keyword); hw_kernels is
  # generated for the application
  @compile {:no_warn_undefined, :hw_kernels}
  defp opt(opts, key, default) do
    case :lists.keyfind(key, 1, opts) do
      {^key, v} -> v
      false -> default
    end
  end

  @doc """
  Receive the events of `topic`: the elements an instance gives to `EHLS.PubSub.broadcast(topic)` (`EHLS.Pipeline`,
  "Events"), each as a message `{topic, value}` to this process. Any number of processes can subscribe
  to a topic (up to 4 at once today). Returns `:ok`, or `{:error, :full}`. Needs the runtime backend (on
  the board); without one it raises.

      EHLS.PubSub.subscribe(:presses)

      def handle_info({:presses, n}, st), do: ...

  `opts`, as a socket's:

    * `active: true` (every event, the default), `:once` (the next one) or `n` (the next n): the events
      after them are kept (16 at most) until this process subscribes again, and come then, oldest first; a
      `{:ehls_lost, topic, n}` before them says how many did not fit.
    * `timestamps: true`: `{topic, value, t}`, t when the event came in the FPGA, in microseconds on the
      clock of `:erlang.monotonic_time(:microsecond)` (the event's time in the FPGA, not its message's).

  Subscribing again changes the options, and gives what was kept.

      EHLS.PubSub.subscribe(:presses, active: :once, timestamps: true)

      def handle_info({:presses, n, t}, st) do
        EHLS.PubSub.subscribe(:presses, active: :once, timestamps: true)    # the next one
        ...
  """
  def subscribe(topic, opts \\ []) when is_atom(topic) and is_list(opts) do
    active =
      case opt(opts, :active, true) do
        true -> -1
        :once -> 1
        n when is_integer(n) and n > 0 -> n
        other -> raise ArgumentError, "EHLS.PubSub.subscribe(#{inspect(topic)}): active: true, :once or a positive integer, not #{inspect(other)}"
      end

    stamps =
      case opt(opts, :timestamps, false) do
        s when is_boolean(s) -> s
        other -> raise ArgumentError, "EHLS.PubSub.subscribe(#{inspect(topic)}): timestamps: true or false, not #{inspect(other)}"
      end

    case event_runtime() do
      nil ->
        raise ArgumentError, "EHLS.PubSub.subscribe(#{inspect(topic)}): events come from a board, with a runtime backend (EHLS_RUNTIME)"

      rt ->
        {id, bits, signed} = :hw_kernels.topic(topic)

        case rt.event_subscribe(id, topic, bits, signed, self(), active, stamps) do
          :ok -> :ok
          :full -> {:error, :full}
        end
    end
  end

  @doc "No more events of `topic` for this process."
  def unsubscribe(topic) when is_atom(topic) do
    case event_runtime() do
      nil ->
        raise ArgumentError, "EHLS.PubSub.unsubscribe(#{inspect(topic)}): events come from a board, with a runtime backend (EHLS_RUNTIME)"

      rt ->
        {id, _bits, _signed} = :hw_kernels.topic(topic)
        rt.event_unsubscribe(id, self())
    end
  end

  # on the board, the runtime module the generated hw_kernels names; nil on a computer (no hw_kernels)
  defp event_runtime do
    if :erlang.function_exported(:hw_kernels, :runtime, 0) or match?({:module, _}, :code.ensure_loaded(:hw_kernels)),
      do: :hw_kernels.runtime()
  end
end
