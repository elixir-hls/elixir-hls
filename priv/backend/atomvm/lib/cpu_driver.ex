defmodule EHLS.CpuDriver do
  @moduledoc """
  A `definstance` with a stage `on: :cpu` is cut into two instances of the FPGA, `<name>__pre` and `<name>__post`
  (`EHLS.CpuStage`); this process takes the stream from the one, through the NIF (`EHLS.NIFRun`), to
  the other. Started by `<name>(:cpu_start, opts)`, stopped by `<name>(:cpu_stop, pid)`.

  It keeps two requests open at `__pre` and gives `__post` up to two results: an end starts its next transfer itself the
  moment one is done (the NIF's completion handler), so the FPGA's stream goes on while this process waits for the VM
  (AtomVM has one scheduler, and a NIF call is not interrupted). The results go out from a process of their own, so
  that one comes free while this one computes. A stage that is last gives its results to the process in `to:` as
  `{name, :out, binary}`.

  The two ends may run at rates a little apart (a tuner's crystal and an I2S output's): what comes in faster than
  `__post` takes waits in memory. `hold:` results at most (given to `__post` and waiting, default 3); beyond that the
  oldest waiting one is dropped, a batch's worth of the stream skipped now and then rather than a delay that grows.

  `<name>(:cpu_stats, pids)` tells whether the CPU keeps up: for each driver `%{batches:, bytes_in:, bytes_out:, busy_ms:, elapsed_ms:, held_max:, dropped:}` (`held_max`: the most results held at once; `dropped`: results dropped for `hold:`).
  A `busy_ms` near `elapsed_ms` means the CPU stage is the bottleneck: the FPGA waits for it (`overflow: :wait`), or drops
  (`overflow: :drop`) what it cannot hold. A smaller `batch:` shortens the delay, a larger one costs less per element.

  Several stages on the CPU that follow each other run in this one process, one after the other on each batch.

  `opts`: `batch:` (elements per request, default 256; a request's elements are also the time that a late process is
  covered for, so a sink that plays at its own rate wants batches longer than the VM is ever late), `hold:` (above), `chunk:` (elements per NIF call, default `batch`; the VM runs its
  other processes between calls, see `EHLS.NIFRun`), `levels:` (a function of one argument, the kernel as `:"Module.function"`,
  returning its level arguments' integers before each batch; default none), `to:` (the pid of a last stage's results),
  `timeout:` (ms to wait for the FPGA's DMA to take a result, default 5000; a quiet source is waited for without limit).
  """

  @batch 256
  @hold 3
  @timeout 5000

  # AtomVM grows a process' heap by what it needs at the moment by default: a batch's binaries would cost a collection
  # after another
  def start(spec), do: :erlang.spawn_opt(fn -> init(spec) end, [:link | spawn_opts()])

  defp spawn_opts, do: if(:erlang.system_info(:machine) == ~c"ATOM", do: [{:atomvm_heap_growth, :fibonacci}], else: [])

  defp init(%{opts: opts} = spec) do
    # the sender, linked: one dies, both do
    spec = if spec[:send], do: sender(Map.put(spec, :post, spec[:post])), else: Map.put(spec, :sender, nil)
    batch = opt(opts, :batch, @batch)
    states = init_all(spec.kernels)
    # two requests open: the end starts the second itself the moment the first is done, so the part before the cut is
    # read on while this process waits for the VM (a source that cannot wait would lose what does not fit its buffer)
    ask(spec, batch)
    ask(spec, batch)
    loop(spec, states, batch, %{batches: 0, bytes_in: 0, bytes_out: 0, busy_ms: 0, start: now()})
  end

  @doc "The statistics of drivers (a pid or a list), in the same order."
  def stats(pids) when is_list(pids), do: for(pid <- pids, do: stats(pid))

  def stats(pid) do
    # an answer that came after an earlier call gave up is old: dropped, so at most one ever waits in the mailbox
    flush_stats(pid)
    send(pid, {:cpu_stats, self()})

    receive do
      {:cpu_stats, ^pid, stats} -> stats
    after
      1000 -> :timeout
    end
  end

  defp flush_stats(pid) do
    receive do
      {:cpu_stats, ^pid, _old} -> flush_stats(pid)
    after
      0 -> :ok
    end
  end

  defp now, do: :erlang.monotonic_time(:millisecond)

  defp init_all([]), do: []
  defp init_all([{kernel, words} | rest]), do: [EHLS.NIFRun.init(kernel, words) | init_all(rest)]

  # The two ends go each at its own pace: a batch from `pre` is asked for again at once (its FPGA part may hold only a few
  # elements while no request is open, and a source that cannot wait loses the rest) and its result handed to a sender,
  # a process of its own that gives the results to `post` one transfer at a time, the next as soon as the one before has
  # gone. Its own process: while this one works on a batch (a NIF call is not interrupted) the sender is free to start
  # the next transfer, so a sink that plays at its own rate (i2s_out) is not left waiting.
  defp loop(spec, states, batch, stats) do
    pre = spec.pre

    receive do
      {^pre, :out, bin} ->
        ask(spec, batch)
        chunk = opt(spec.opts, :chunk, batch)
        t0 = now()
        {out, states} = through(spec.kernels, states, bin, chunk, opt(spec.opts, :levels, nil))
        busy = now() - t0
        give(spec, out)

        loop(spec, states, batch, %{
          stats
          | batches: stats.batches + 1,
            bytes_in: stats.bytes_in + byte_size(bin),
            bytes_out: stats.bytes_out + byte_size(out),
            busy_ms: stats.busy_ms + busy
        })

      {:cpu_stats, from} ->
        send(from, {:cpu_stats, self(), %{batches: stats.batches, bytes_in: stats.bytes_in, bytes_out: stats.bytes_out, busy_ms: stats.busy_ms,
                                          elapsed_ms: now() - stats.start} |> Map.merge(held(spec))})
        loop(spec, states, batch, stats)

      :cpu_stop ->
        stop(spec)
    end
  end

  # a result: to `to:` when the stage is the last, else to the sender for `post`
  defp give(%{sender: nil, name: name, opts: opts}, out) do
    case opt(opts, :to, nil) do
      nil -> :erlang.exit({:no_to, name})
      pid -> send(pid, {name, :out, out})
    end
  end

  defp give(%{sender: sender}, out), do: send(sender, {:cpu_out, out})

  defp held(%{sender: nil}), do: %{held_max: 0, dropped: 0}

  defp held(%{sender: sender}) do
    send(sender, {:cpu_held, self()})

    receive do
      {:cpu_held, ^sender, most, dropped} -> %{held_max: most, dropped: dropped}
    after
      1000 -> %{held_max: :timeout, dropped: :timeout}
    end
  end

  defp sender(spec) do
    me = self()
    hold = opt(spec.opts, :hold, @hold)
    pid = :erlang.spawn_opt(fn -> send_loop(Map.put(spec, :hold, hold), me, [], 0, {0, 0}, 0) end, [:link | spawn_opts()])
    Map.put(spec, :sender, pid)
  end

  # The results not yet given (newest first), how many, {the most held at once, how many dropped}, and how many transfers
  # are given (the end takes one more while one is read, and starts it itself the moment the first is done: the stream
  # after the cut goes on even when this process runs late)
  defp send_loop(spec, driver, queue, n, {most, dropped}, given) do
    post = spec.post

    receive do
      {:cpu_out, out} ->
        {queue, n, given} = give_next(spec, [out | queue], n + 1, given)
        {queue, n, dropped} = within(queue, n, given, spec.hold, dropped)
        send_loop(spec, driver, queue, n, {max(most, n + given), dropped}, given)

      {^post, :cpu_in, :sent} ->
        {queue, n, given} = give_next(spec, queue, n, given - 1)
        send_loop(spec, driver, queue, n, {most, dropped}, given)

      {:cpu_held, from} ->
        send(from, {:cpu_held, self(), most, dropped})
        send_loop(spec, driver, queue, n, {most, dropped}, given)

      :cpu_stop ->
        :ok
    after
      # the FPGA's DMA has not taken a transfer it was given; nothing to give is waited for without limit
      if(given > 0, do: opt(spec.opts, :timeout, @timeout), else: :infinity) -> :erlang.exit({:timeout, driver})
    end
  end

  # at most `hold` results held: the oldest waiting ones dropped
  defp within(queue, n, given, hold, dropped) when n > 0 and n + given > hold do
    [_oldest | rest] = :lists.reverse(queue)
    within(:lists.reverse(rest), n - 1, given, hold, dropped + 1)
  end

  defp within(queue, n, _given, _hold, dropped), do: {queue, n, dropped}

  # the oldest results to `post` while it takes them (two at most); {:error, :busy}: the next :sent makes room
  defp give_next(_spec, [], 0, given), do: {[], 0, given}
  defp give_next(_spec, queue, n, given) when given >= 2, do: {queue, n, given}

  defp give_next(spec, queue, n, given) do
    [oldest | rest] = :lists.reverse(queue)

    case spec.send.(oldest) do
      :ok -> give_next(spec, :lists.reverse(rest), n - 1, given + 1)
      {:error, :busy} -> {queue, n, given}
      other -> :erlang.exit({:send, other})
    end
  end

  # what is in flight on the FPGA's ends is cancelled, so that the next start finds them free, and a batch that arrived
  # meanwhile is dropped
  defp stop(spec) do
    if spec.sender, do: send(spec.sender, :cpu_stop)
    if spec.cancel, do: spec.cancel.()
    flush(spec.pre)
    :ok
  end

  defp flush(pre) do
    receive do
      {^pre, :out, _} -> flush(pre)
    after
      0 -> :ok
    end
  end

  # the batch through each kernel in turn, each with its own state
  defp through([], [], bin, _chunk, _levels), do: {bin, []}

  defp through([{kernel, _} | kernels], [state | states], bin, chunk, levels) do
    lv = if levels == nil, do: [], else: levels.(kernel)
    {out, state} = EHLS.NIFRun.run(state, bin, lv, chunk)
    {out, rest} = through(kernels, states, out, chunk, levels)
    {out, [state | rest]}
  end

  defp ask(spec, batch) do
    case spec.request.(batch) do
      :ok -> :ok
      other -> :erlang.exit({:request, other})
    end
  end

  defp opt(opts, key, default) do
    case :lists.keyfind(key, 1, opts) do
      {^key, v} -> v
      false -> default
    end
  end
end
