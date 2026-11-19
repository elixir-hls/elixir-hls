defmodule EHLS.CpuInstance do
  @moduledoc false
  # An instance placed on the CPU (EHLS.Pipeline, "Placement"): a process, registered under the instance's key
  # (`:"Module.name"`), that holds each stage's state between calls. The module defines
  #   __cpu_step_<name>__(list, states) -> {list, states}   the stages over a list, from the states
  #   __cpu_init_<name>__() -> states                         the initial states
  #   __cpu_read_<name>__(states, what, n)                    what f(:value, h) / f(:state, n) read
  #   __cpu_source_<name>__() -> nil | {:ticks, rate}         where its stream comes from, if not from calls
  #   __cpu_buffer_<name>__(), __cpu_pack_<name>__(list)       the elements that may wait; the output packed
  # and the instance's functions call this module. Runs on the BEAM and on AtomVM: no Enum, no Keyword.
  #
  # A source (ticks) runs on a timer from the process's start (its first call, or f(:start)). What comes out of an
  # instance with a source and no sink waits in the process for f(:out, n) / f(:request, :out, n); when `buffer`
  # elements wait, the source waits too (as overflow: :wait in the FPGA).

  @timeout 5000
  # elements of a source per timer at most, so that a fast source does not hold the VM
  @max_batch 1024

  @doc "A list through the instance; `{:ok, list}`, or `{:error, :stopped}`."
  def call(key, module, name, list, opts) do
    pid = ensure(key, module, name)
    ref = make_ref()
    send(pid, {:cpu_call, self(), ref, list})
    wait(pid, ref, opt(opts, :timeout, @timeout))
  end

  @doc "`:start` (from the initial states, running) or `:stop` (calls answer `{:error, :stopped}`, a source stops)."
  def control(key, module, name, what) when what == :start or what == :stop do
    pid = ensure(key, module, name)
    ref = make_ref()
    send(pid, {:cpu_control, self(), ref, what})
    wait(pid, ref, @timeout)
  end

  @doc "What the module's `__cpu_read_<name>__(states, what, n)` gives of the current states (`:value` / `:state`)."
  def read(key, module, name, args) do
    pid = ensure(key, module, name)
    ref = make_ref()
    send(pid, {:cpu_read, self(), ref, args})
    wait(pid, ref, @timeout)
  end

  @doc "The next `n` elements of an instance with a source, waiting for them: `{:ok, list}`."
  def out(key, module, name, n, opts) do
    pid = ensure(key, module, name)
    ref = make_ref()
    send(pid, {:cpu_out, self(), ref, n})
    wait(pid, ref, opt(opts, :timeout, @timeout))
  end

  @doc "Asks for the next `n` elements; `{tag, :out, list}` comes to the caller when they are there."
  def request(key, module, name, n, tag) do
    pid = ensure(key, module, name)
    send(pid, {:cpu_request, self(), tag, n})
    :ok
  end

  @doc "A join over lists: f of the elements taken together, and what each side has more (it waits for the next call)."
  def zip_with(a, b, f), do: zip_with(a, b, f, [])

  defp zip_with([x | xs], [y | ys], f, acc), do: zip_with(xs, ys, f, [f.(x, y) | acc])
  defp zip_with(xs, ys, _f, acc), do: {:lists.reverse(acc), xs, ys}

  @doc "The first `n` 64-bit little-endian words of a NIF kernel's state binary (its state words come first)."
  def words(_bin, 0), do: []
  def words(<<w::little-unsigned-64, rest::binary>>, n), do: [w | words(rest, n - 1)]

  @doc false
  def opt(opts, key, default) do
    case :lists.keyfind(key, 1, opts) do
      {^key, v} -> v
      false -> default
    end
  end

  # the process watched: one that dies (a kernel missing from the firmware, a stage that fails where nothing catches it)
  # is said at once, not after the timeout
  defp wait(pid, ref, timeout) do
    mon = :erlang.monitor(:process, pid)

    receive do
      {^ref, {:raise, kind, reason}} ->
        :erlang.demonitor(mon, [:flush])
        :erlang.raise(kind, reason, [])

      {^ref, reply} ->
        :erlang.demonitor(mon, [:flush])
        reply

      {:DOWN, ^mon, :process, _, reason} ->
        :erlang.error({:instance_down, reason})
    after
      timeout ->
        :erlang.demonitor(mon, [:flush])
        # the instance forgets the asker and says so; a reply sent before that is dropped here, so that nothing late
        # stays in the caller's mailbox (the instance sends in order: a reply, then the cancel's answer)
        send(pid, {:cpu_cancel, self(), ref})
        drop_late(pid, ref)
        :erlang.error(:timeout)
    end
  end

  defp drop_late(pid, ref) do
    mon = :erlang.monitor(:process, pid)
    drop_late(pid, ref, mon)
  end

  defp drop_late(pid, ref, mon) do
    receive do
      {^ref, :cancelled} -> :erlang.demonitor(mon, [:flush])
      {^ref, _late} -> drop_late(pid, ref, mon)
      {:DOWN, ^mon, :process, _, _} -> :ok
    after
      @timeout -> :erlang.demonitor(mon, [:flush])
    end
  end

  # AtomVM grows a process' heap by what it needs at the moment by default, so a call's lists cost a collection
  # after another (time growing with the square of a call's length); its heap grows as a Fibonacci series instead
  defp spawn_opts do
    case :erlang.system_info(:machine) do
      ~c"ATOM" -> [{:atomvm_heap_growth, :fibonacci}]
      _ -> []
    end
  end

  # the instance's process, started at its first use (an instance in the FPGA runs from reset; this one from its first call)
  defp ensure(key, module, name) do
    case :erlang.whereis(key) do
      :undefined ->
        pid = :erlang.spawn_opt(fn -> init(module, name) end, spawn_opts())

        try do
          :erlang.register(key, pid)
          pid
        catch
          # another caller started it first
          :error, :badarg ->
            :erlang.exit(pid, :kill)
            :erlang.whereis(key)
        end

      pid ->
        pid
    end
  end

  defp fun(prefix, name), do: :erlang.binary_to_atom(prefix <> :erlang.atom_to_binary(name, :utf8) <> "__", :utf8)

  defp init(module, name) do
    s = %{
      module: module,
      name: name,
      step: fun("__cpu_step_", name),
      read: fun("__cpu_read_", name),
      init: fun("__cpu_init_", name),
      source: apply(module, fun("__cpu_source_", name), []),
      buffer: apply(module, fun("__cpu_buffer_", name), []),
      overflow: apply(module, fun("__cpu_overflow_", name), []),
      states: nil,
      running: false,
      # a source: elements given so far, its start (ms), the timer's generation (a stop makes old timers stale)
      count: 0,
      t0: 0,
      gen: 0,
      # elements waiting for f(:out) / f(:request) (newest first), and the askers in order
      out: [],
      nout: 0,
      askers: []
    }

    # an instance with a source starts with f(:start) (or an EHLS.Server's init/1), as its timer is its time; one fed by
    # calls runs from its first call
    # (start/1 makes the states; one with a source has them for :value / :state before its start)
    loop(if s.source == nil, do: start(s), else: %{s | states: apply(module, s.init, [])})
  end

  defp start(s) do
    s = %{s | states: apply(s.module, s.init, []), running: true, count: 0, out: [], nout: 0, gen: s.gen + 1, t0: now()}

    case s.source do
      {:ticks, _} -> tick_later(s)
      nil -> s
    end
  end

  defp now, do: :erlang.monotonic_time(:millisecond)

  defp tick_later(%{source: {:ticks, rate}} = s) do
    ms = if rate >= 1000, do: 1, else: div(1000, rate)
    :erlang.send_after(ms, self(), {:cpu_tick, s.gen})
    s
  end

  defp loop(s) do
    receive do
      {:cpu_call, from, ref, list} ->
        if s.running do
          try do
            {out, states} = apply(s.module, s.step, [list, s.states])
            send(from, {ref, {:ok, out}})
            loop(%{s | states: states})
          catch
            # a call with what the stages do not take: the caller gets the error, the instance keeps its states
            kind, reason ->
              send(from, {ref, {:raise, kind, reason}})
              loop(s)
          end
        else
          send(from, {ref, {:error, :stopped}})
          loop(s)
        end

      {:cpu_tick, gen} when gen == s.gen and s.running ->
        loop(tick(s))

      {:cpu_tick, _} ->
        loop(s)

      # a stopped instance answers at once: nothing more will come until a start
      {:cpu_out, from, ref, _n} when not s.running ->
        send(from, {ref, {:error, :stopped}})
        loop(s)

      {:cpu_request, from, _tag, _n} when not s.running ->
        send(from, {s.name, :out, {:error, :stopped}})
        loop(s)

      {:cpu_out, from, ref, n} ->
        loop(serve(%{s | askers: s.askers ++ [{:reply, from, ref, n, []}]}))

      {:cpu_request, from, tag, n} ->
        loop(serve(%{s | askers: s.askers ++ [{:message, from, tag, n, []}]}))

      {:cpu_cancel, from, ref} ->
        send(from, {ref, :cancelled})
        loop(%{s | askers: drop_asker(s.askers, ref)})

      {:cpu_read, from, ref, args} ->
        try do
          send(from, {ref, apply(s.module, s.read, [s.states | args])})
        catch
          kind, reason -> send(from, {ref, {:raise, kind, reason}})
        end

        loop(s)

      {:cpu_control, from, ref, :start} ->
        send(from, {ref, :ok})
        loop(start(s))

      {:cpu_control, from, ref, :stop} ->
        send(from, {ref, :ok})
        loop(stopped(s))
    end
  end

  # the elements the source owes since its start, as many as there is room for and a batch takes
  defp tick(%{source: {:ticks, rate}} = s) do
    due = div((now() - s.t0) * rate, 1000) - s.count
    room = if s.overflow == :drop, do: @max_batch, else: s.buffer - s.nout
    n = min3(due, room, @max_batch)

    if n > 0 do
      try do
        apply(s.module, s.step, [seq(s.count, n), s.states])
      catch
        # a stage that fails stops the instance (its states kept, readable); what waits for it is answered
        _kind, _reason -> :failed
      else
        {out, states} ->
          out = room_for(out, s)
          s = serve(%{s | states: states, count: s.count + n, out: :lists.reverse(out, s.out), nout: s.nout + length(out)})
          tick_later(s)
      end
      |> case do
        :failed -> stopped(s)
        s -> s
      end
    else
      tick_later(s)
    end
  end

  # overflow: :wait gives only what there is room for (the source waits: room was counted before); :drop gives what
  # was due, and what does not fit is dropped (the counts go on, as a circuit's source that cannot wait)
  defp room_for(out, %{overflow: :drop} = s), do: :lists.sublist(out, s.buffer - s.nout)
  defp room_for(out, _s), do: out

  # stopped: the timer stale, the askers answered
  defp stopped(s) do
    for {how, to, tag, _n, _got} <- s.askers do
      case how do
        :reply -> send(to, {tag, {:error, :stopped}})
        :message -> send(to, {s.name, :out, {:error, :stopped}})
      end
    end

    %{s | running: false, gen: s.gen + 1, askers: []}
  end

  defp drop_asker([], _ref), do: []
  defp drop_asker([{_, _, ref, _, _} | rest], ref), do: rest
  defp drop_asker([a | rest], ref), do: [a | drop_asker(rest, ref)]

  # the counts c, c+1, ... as ticks gives them (u32, wrapping)
  defp seq(_c, 0), do: []
  defp seq(c, n), do: [Bitwise.band(c, 0xFFFFFFFF) | seq(c + 1, n - 1)]

  defp min3(a, b, c), do: min(a, min(b, c))

  # the askers in order: each takes what is there, up to what it still needs, and is answered when it has all of it, so
  # that one asking for more than `buffer` elements gets them as the source goes on
  defp serve(%{askers: [{how, to, tag, n, got} | rest]} = s) when s.nout > 0 or n == 0 do
    k = min(n, s.nout)
    {taken, left} = :lists.split(k, :lists.reverse(s.out))
    got = got ++ taken
    s = %{s | out: :lists.reverse(left), nout: s.nout - k}

    if k == n do
      case how do
        :reply -> send(to, {tag, {:ok, got}})
        # as from an instance in the FPGA: the packed format
        :message -> send(to, {s.name, :out, apply(s.module, fun("__cpu_pack_", s.name), [got])})
      end

      serve(%{s | askers: rest})
    else
      %{s | askers: [{how, to, tag, n - k, got} | rest]}
    end
  end

  defp serve(s), do: s
end
