defmodule EHLS.NIFRun do
  @moduledoc """
  On AtomVM: calls a `defhls` function that `mix ehls.compile --target cpu` compiled to C (the NIFs of
  `hwnif`, the kernel numbers and layouts of the generated `hw_nif`).

  A kernel's state is a binary this module hands back with every result, so a stream goes on from the
  state it ended in. A NIF is not interrupted by the VM, so an input is cut into chunks of `chunk`
  elements (default #{256}) and the VM runs its other processes between the calls; a kernel's step is
  bounded, so a chunk's time is `chunk` times a constant. The default is a guess until the time per
  element is measured on the board.

      {out, st} = EHLS.NIFRun.run(EHLS.NIFRun.init(:"Mod.fun"), binary)
      EHLS.NIFRun.call(:"Mod.fun", [1, 2, 3])        # a list in, a list out, from the initial state
  """

  @chunk 256

  @doc """
  The initial state of a kernel (`"Module.function"` as an atom): `{kernel number, state binary}`. `words`: its state words
  (a list of 32-bit unsigned integers, as `transform(init, ...)` gives them) where the state does not start from the
  function's own initial value.
  """
  def init(kernel, words \\ nil) do
    k = :hw_nif.kernel(kernel)
    {k, if(words == nil, do: :hwnif.init(k), else: :hwnif.init(k, words))}
  end

  @doc """
  Runs a binary of whole packed elements through the kernel from `state`: `{output binary, next state}`.
  `levels`: the integers of its level arguments.
  """
  def run(state, input, levels \\ [], chunk \\ @chunk)

  def run({k, st}, input, levels, chunk) do
    {in_bytes, _out, _levels, _state, max_in} = :hwnif.info(k)
    # at least one element, and no more than a call takes
    elements = if chunk < 1, do: 1, else: chunk
    size = elements * in_bytes
    size = if size > max_in, do: div(max_in, in_bytes) * in_bytes, else: size
    # an element larger than a call takes would make calls of no bytes, forever
    if size == 0, do: :erlang.error({:element_too_large, in_bytes, max_in})
    loop(k, st, input, levels, size, 0, byte_size(input), [])
  end

  defp loop(k, st, _input, _levels, _size, pos, total, acc) when pos >= total,
    do: {:erlang.list_to_binary(:lists.reverse(acc)), {k, st}}

  defp loop(k, st, input, levels, size, pos, total, acc) do
    n = if total - pos < size, do: total - pos, else: size
    {out, st} = :hwnif.run(k, st, :erlang.binary_part(input, pos, n), levels)
    loop(k, st, input, levels, size, pos + n, total, [out | acc])
  end

  @doc "A list of elements through the kernel from its initial state, a list out (as `EHLS.pack/2`'s layouts)."
  def call(kernel, elements, levels \\ []) do
    {in_layout, out_layout} = :hw_nif.layouts(kernel)
    {out, _state} = run(init(kernel), :hwstream.pack(elements, in_layout), levels)
    :hwstream.unpack(out, out_layout)
  end
end
