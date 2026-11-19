defmodule EHLS.Check do
  @moduledoc """
  On the board: runs a defhls function on the CPU and an instance made of it in the FPGA over the
  same words and compares. The input's elements are of 4 bytes (`u32`, `s18`, ...): the binaries going in
  are 32-bit words. The output's elements have the size the circuit's binary shows. Builds binaries from byte lists and runs in a Fibonacci-heap process:
  AtomVM may collect garbage on every binary operation and its default heap growth makes
  building large terms quadratic.
  """
  import Bitwise

  @doc "Compares `fun` (a defhls function/1) on the CPU and `instance` (its circuit) for `words`; prints one line."
  def compare(label, fun, instance, words) do
    in_process(fn ->
      input = to_binary(words)
      t0 = :erlang.monotonic_time(:millisecond)
      output = instance.(input)
      t1 = :erlang.monotonic_time(:millisecond)
      expected = packed_like(output, Enum.map(words, fun))
      t2 = :erlang.monotonic_time(:millisecond)
      ok = if output == expected, do: "OK", else: "MISMATCH"

      IO.puts("#{label} n=#{length(words)} #{ok}: FPGA #{t1 - t0} ms, CPU #{t2 - t1} ms")
      output == expected
    end)
  end

  @doc """
  Compares a stateful defhls function (`fun/2`) on the CPU and `instance` for `words`: the whole
  stream from `init` (a stage's initial value; all zeros by default), then the same stream in two
  halves, the state going on.
  """
  def compare_stream(label, fun, instance, words, init \\ nil) do
    in_process(fn ->
      {:name, name} = :erlang.fun_info(fun, :name)
      {:module, mod} = :erlang.fun_info(fun, :module)
      init = init || apply(mod, name, [:zero])
      input = to_binary(words)
      restart(instance)
      t0 = :erlang.monotonic_time(:millisecond)
      output = instance.(input)
      t1 = :erlang.monotonic_time(:millisecond)
      {ys, _} = EHLS.run_cpu(fun, words, init)
      expected = packed_like(output, ys)
      t2 = :erlang.monotonic_time(:millisecond)
      {first, second} = :erlang.split_binary(input, div(byte_size(input), 8) * 4)
      restart(instance)
      continued = instance.(first) <> instance.(second)
      ok = if output == expected and continued == expected, do: "OK", else: "MISMATCH"

      IO.puts("#{label} n=#{length(words)} #{ok}: FPGA #{t1 - t0} ms, CPU #{t2 - t1} ms")
      ok == "OK"
    end)
  end

  @doc "Values -> binary, each in `size` bytes, little-endian (the packed format of a scalar)"
  def to_binary(values, size \\ 4), do: :erlang.list_to_binary(for v <- values, do: bytes(v, size))

  # written out: a comprehension over a range for each value was 50 times slower on AtomVM
  defp bytes(v, 1), do: [v &&& 255]
  defp bytes(v, 2), do: [v &&& 255, v >>> 8 &&& 255]
  defp bytes(v, 4), do: [v &&& 255, v >>> 8 &&& 255, v >>> 16 &&& 255, v >>> 24 &&& 255]
  defp bytes(v, 8), do: [bytes(v, 4), bytes(v >>> 32, 4)]

  # as the circuit's output: each value in the bytes it gives per value
  defp packed_like(output, []), do: to_binary([], max(byte_size(output), 1))
  defp packed_like(output, values), do: to_binary(values, max(div(byte_size(output), length(values)), 1))

  @doc "Pseudo-random 32-bit words (small-integer arithmetic only)"
  def words(n), do: for(i <- 1..n, do: rem(i * 7919, 65536) ||| rem(i * 104_729, 65536) <<< 16)

  defp restart(instance) do
    instance.(:stop)
    instance.(:start)
  end

  defp in_process(fun) do
    parent = self()
    :erlang.spawn_opt(fn -> send(parent, {:hw_check, fun.()}) end, [{:atomvm_heap_growth, :fibonacci}])

    receive do
      {:hw_check, result} -> result
    end
  end
end
