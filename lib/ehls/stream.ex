defmodule EHLS.Stream do
  @moduledoc """
  The functions an instance joins with the pipe, named and taking their arguments as Elixir's `Stream` does.

  In a `definstance` (and in a stream function, a `defhls` taking `stream(t)`) they are written without the module,
  `x |> map(&f/1)`, or with it, `x |> EHLS.Stream.map(&f/1)`; there each places its function where the instance runs, as
  a circuit in the FPGA or on the CPU. Called as functions, on a list or any enumerable, they give what the instance
  gives: the same as `Stream`'s, lazily. So a pipe can be tried in `iex` or `mix test` as it is written:

  ```elixir
  [1, 2, 3] |> EHLS.Stream.map(&MyApp.twice/1) |> Enum.to_list()     # [2, 4, 6]
  ```

  The last argument, `opts`, says how the function is placed and is not `Stream`'s: `on: :cpu | :fpga` (where it runs,
  `EHLS.Pipeline`, "Placement") and, for `transform/4`, `name:` and `memory:`. Called as functions they are checked and do nothing else.

  What an instance joins besides these has no counterpart in `Stream`: the topics, `EHLS.PubSub.broadcast(topic)` and
  `EHLS.PubSub.subscribe(topic)` (`EHLS.PubSub`); one state for several lines (`EHLS.Agent`); `ticks`, `hold` and the
  devices (`EHLS.Pipeline`).
  """

  @placement [:on]

  @doc """
  Each element through `f`, as `Stream.map/2`.

  `f` is a `defhls` of the element, `&f/1`, or of several arguments with the element as one of them and each other an
  integer or a level, `&scale(&1, gain_hw(:value))` (`EHLS.Pipeline`, "Instances of levels").
  """
  def map(enum, f, opts \\ []) when is_function(f, 1) do
    check!(opts, @placement)
    Stream.map(enum, f)
  end

  @doc """
  The elements for which `f` is true, as `Stream.filter/2`.

  A `defhls` gives an integer: 0 is false, as `false` and `nil` are.
  """
  def filter(enum, f, opts \\ []) when is_function(f, 1) do
    check!(opts, @placement)
    Stream.filter(enum, &(f.(&1) not in [0, false, nil]))
  end

  @doc """
  Each element through `f` with a state, from `acc`, as `Stream.transform/3`.

  `f` is a `defhls` of the element and the state, `&f/2`, returning `{output, next_state}`; the output is a list of at most
  one element, `{[y], s}` or `{[], s}`, as `Stream.transform/3`'s, or the element itself, `{y, s}`, when there is always
  one. Placed, the state is the circuit's registers, from `acc` (written with literals). With `name: n` the CPU reads it
  while the instance runs, `my_inst(:state, n)`. With `memory: [:hist]` the tuple `hist` of the state is the FPGA's
  memory instead (`EHLS.defhls`, "Tuples in the state"); read with `name:`, the state comes whole, the memory word by
  word, each word as it is when read: while it runs, the values (taken at one clock) and the memory's words may
  come from different steps.
  """
  def transform(enum, acc, f, opts \\ []) when is_function(f, 2) do
    check!(opts, [:name, :memory | @placement])

    Stream.transform(enum, acc, fn x, s ->
      case f.(x, s) do
        {ys, s} when is_list(ys) -> {ys, s}
        {y, s} -> {[y], s}
      end
    end)
  end

  @doc """
  One element of each, together, through `f`, as `Stream.zip_with/3`.

  `f` is a `defhls` of two arguments. In a pipe the first stream comes from the pipe, `a |> zip_with(b, &f/2)`; `f(a, b)`
  with both arguments streams is the same.
  """
  def zip_with(a, b, f, opts \\ []) when is_function(f, 2) do
    check!(opts, @placement)
    Stream.zip_with(a, b, f)
  end

  @doc """
  Chunks of `count` elements, a new one every `step`, through the function that follows, as
  `Stream.chunk_every/4` with `:discard`, each chunk a tuple: a value of a fixed size, as a circuit has them (a circuit
  has no lists).

  Placed, it is followed by `map(&f/1)`, `f` a `defhls` of a chunk, `defhls f(w :: tuple(t, count)) :: r`, reading
  `elem(w, i)` (0 the oldest): `x |> chunk_every(32, 4, :discard) |> map(&fir/1)` is an FIR filter computed for
  every fourth element, one kernel with a ring buffer of the last 32 and its arithmetic used in turn. The first chunk
  is out once `count` elements have come; a chunk shorter than `count` is never out, so `:discard` is written, as in
  Elixir it says the same. A step over the count leaves out the elements between the chunks.
  """
  def chunk_every(enum, count, step, :discard) when is_integer(count) and is_integer(step) and count >= 1 and step >= 1 do
    enum |> Stream.chunk_every(count, step, :discard) |> Stream.map(&List.to_tuple/1)
  end

  @doc """
  Takes every element and gives nothing on, as `Stream.run/1`: the end of a pipe kept for what its functions do, their
  state read with `my_inst(:state, n)` or their events. Returns `:ok`.
  """
  def run(enum, opts \\ []) do
    check!(opts, [])
    Stream.run(enum)
  end

  defp check!(opts, keys) do
    unless is_list(opts) and Keyword.keyword?(opts), do: raise(ArgumentError, "options are a keyword list, got #{inspect(opts)}")

    case Keyword.keys(opts) -- keys do
      [] -> :ok
      other -> raise ArgumentError, "unknown option(s) #{inspect(other)}: #{inspect(keys)}"
    end
  end
end
