defmodule Mix.Tasks.Ehls.Sim do
  @shortdoc "Checks instances in simulation against their Elixir functions"
  @moduledoc """
  Compiles like `mix ehls.compile`, which checks each kernel by itself, then checks the instances:
  consecutive `defhls` stages with what is between them, from random words into the first to
  the words out of the last, in iverilog against the same stages run by Elixir, with random gaps
  between the inputs given and between the outputs taken, as in a real circuit. No board and no LiteX.

      mix ehls.sim --out build file.ex...

  An instance of levels (arguments with types) is called as the CPU calls it, its result checked
  after each call that waits for it, with calls that do not wait and stops and starts in between.

  A stage starts from the initial value it was given, a level is at the value it is wired to at first (an instance of levels' `initial:`, an integer, a pin's 0). What is in a block
  (a device, `ticks`, `hold`, ...) is not simulated: an instance is checked piece by piece between
  its blocks, its CPU ends included only as the words of the first and last stage. Takes the options
  of `mix ehls.compile`; `--vectors N` is also the number of elements into each piece (default 2000).
  """
  use Mix.Task

  import Bitwise

  @switches [out: :string, with: :keep, vectors: :integer]

  @impl true
  def run(args) do
    Mix.Tasks.Ehls.Compile.run(args)
    {opts, _, _} = OptionParser.parse(args, strict: @switches)
    out = Mix.Tasks.Ehls.Compile.out_dir(opts)
    hw = Path.join(out, "hw")
    Code.prepend_path(Path.join(out, "hostc"))
    kernels = hw |> Path.join("kernels.json") |> read() |> Map.new(&{&1["kernel"], &1})
    pipelines = hw |> Path.join("pipelines.json") |> read()
    n = opts[:vectors] || 2000
    :rand.seed(:exsss, {1, 2, 3})

    {levels, streams} = pipelines |> Enum.with_index() |> Enum.split_with(fn {p, _} -> p["level"] end)

    pieces =
      for {p, pi} <- streams, {first, last} <- pieces(p), do: {p, pi, first, last}

    results =
      for({p, pi, first, last} <- pieces, do: check(hw, kernels, p, pi, first, last, n)) ++
        for {p, pi} <- levels, do: check_level(hw, kernels[hd(p["stages"])["kernel"]], p, pi, n)

    for {p, _} <- streams, pieces(p) == [],
        do: Mix.shell().info("not simulated: #{p["name"]} has no defhls stage")

    if Enum.any?(results, &(&1 != :ok)), do: Mix.raise("ehls.sim: an instance differs from its Elixir functions")
    Mix.shell().info("#{length(results)} piece(s) of #{length(pipelines)} instance(s) in simulation")
  end

  # An instance of levels, called as the CPU does: n calls, each waiting for its result and checking it,
  # or not waiting (the next start then comes while it computes), and now and then a stop and a start,
  # after which the result is the initial one again. Every result held is checked against the call it
  # says it is for.
  defp check_level(hw, k, p, pi, n) do
    mod = Module.concat([k["module"]])
    fun = String.to_atom(k["function"])
    lane = (1 <<< (k["lane"] || 32)) - 1
    ni = length(flat_type(k["arg"]))
    bits = for t <- flat_type(k["ret"]), do: (1 <<< String.to_integer(String.slice(t, 1..-1//1))) - 1
    cut = fn vs -> Enum.zip_with(vs, bits, &(&1 &&& &2)) end
    initial = cut.(p["level"]["initial"])

    {ins, outs} =
      Enum.reduce(1..n, {[], [initial]}, fn _, {ins, outs} ->
        case :rand.uniform(10) do
          1 ->
            {[[2] | ins], [initial | outs]}

          r ->
            xs = for _ <- 1..ni, do: :rand.uniform(lane + 1) - 1
            y = cut.(flat(apply(mod, fun, [shape(xs, k["arg"])])))
            {[[if(r <= 4, do: 0, else: 1) | xs] | ins], [y | outs]}
        end
      end)

    base = Path.join(hw, "sim_#{pi}_0")
    write_hex(base <> ".in.hex", ins |> Enum.reverse() |> Enum.concat())
    write_hex(base <> ".out.hex", outs |> Enum.reverse() |> Enum.concat())
    lines = simulate(hw, pi, 0, 0)
    for l <- lines, do: Mix.shell().info(l)
    if Enum.any?(lines, &String.contains?(&1, "errors=0 ")), do: :ok, else: :failed
  end

  defp read(path), do: path |> File.read!() |> JSON.decode!()

  # the runs of kernel stages one after the other, each linked to the next, as {first, last} (a join is
  # a block: the pipes into it and out of it are pieces of their own)
  defp pieces(p) do
    linked = MapSet.new(for l <- p["links"], l["to"] == l["from"] + 1 and (l["port"] || 0) == 0 and (l["from_port"] || 0) == 0, do: l["from"])

    p["stages"]
    |> Enum.with_index()
    |> Enum.chunk_while([], fn {st, i}, run ->
      cond do
        not Map.has_key?(st, "kernel") -> {:cont, Enum.reverse(run), []}
        run != [] and MapSet.member?(linked, i - 1) -> {:cont, [i | run]}
        true -> {:cont, Enum.reverse(run), [i]}
      end
    end, fn run -> {:cont, Enum.reverse(run), []} end)
    |> Enum.reject(&(&1 == []))
    |> Enum.map(fn run -> {hd(run), List.last(run)} end)
  end

  defp check(hw, kernels, p, pi, first, last, n) do
    stages = Enum.slice(p["stages"], first..last)
    ks = Enum.map(stages, &kernels[&1["kernel"]])
    lane = fn k -> (1 <<< (k["lane"] || 32)) - 1 end
    words = for _ <- 1..(n * length(flat_type(hd(ks)["arg"]))), do: :rand.uniform(lane.(hd(ks)) + 1) - 1
    expected = Enum.zip(stages, ks) |> Enum.reduce(words, fn {st, k}, ws -> run_stage(st, k, ws) end)
    expected = Enum.map(expected, &(&1 &&& lane.(List.last(ks))))

    base = Path.join(hw, "sim_#{pi}_#{first}")
    write_hex(base <> ".in.hex", words)
    write_hex(base <> ".out.hex", expected)
    lines = simulate(hw, pi, first, last)
    Enum.each(lines, fn l -> Mix.shell().info(l) end)
    if Enum.any?(lines, &String.contains?(&1, "errors=0 ")), do: :ok, else: :failed
  end

  @doc false
  # the piece against the words in its .in.hex and .out.hex: the lines of the testbench's verdict
  def simulate(hw, pi, first, last) do
    base = Path.join(hw, "sim_#{pi}_#{first}")
    tb = base <> ".tb.sv"
    priv = :code.priv_dir(:elixir_hls) |> to_string()
    args = [Path.join(priv, "gen_pipeline_tb.py"), hw] ++ Enum.map([pi, first, last], &to_string/1)
    {files, 0} = System.cmd("python3", args ++ [base <> ".in.hex", base <> ".out.hex", tb])
    sim = base <> ".vvp"
    {log, 0} = System.cmd("iverilog", ["-g2012", "-o", sim, tb | String.split(files, "\n", trim: true)], stderr_to_stdout: true)
    if log != "", do: Mix.shell().info(log)
    {log, _} = System.cmd("vvp", ["-n", sim], stderr_to_stdout: true)
    log |> String.split("\n") |> Enum.filter(&String.match?(&1, ~r/^(RESULT|MISMATCH|TIMEOUT)/))
  end

  defp write_hex(path, words) do
    File.write!(path, Enum.map(words, &[:io_lib.format("~16.16.0b", [&1]), "\n"]))
  end

  # one stage on the CPU: the words in, as elements the function takes, the words out
  defp run_stage(st, k, words) do
    mod = Module.concat([k["module"]])
    fun = String.to_atom(k["function"])
    # a level at the value its stage is wired to at first (gen_manifest.py)
    params = for p <- st["args"] || k["args"], do: p["default"]
    frames = words |> Enum.chunk_every(length(flat_type(k["arg"])), length(flat_type(k["arg"])), :discard)
    frames = Enum.map(frames, &shape(&1, k["arg"]))

    if k["state"] == [] or k["pure"] do
      Enum.flat_map(frames, &flat(apply(mod, fun, [&1 | params])))
    else
      {out, _} =
        Enum.flat_map_reduce(frames, initial(st, k, mod, fun), fn x, state ->
          {y, state} = apply(mod, fun, [x, state | params])
          {flat(y), state}
        end)

      out
    end
  end

  # the stage's initial words in the shape of the function's state; a memory starts as zeros
  defp initial(st, k, mod, fun) do
    zero = apply(mod, fun, [:zero])
    words = st["init"] || k["init"]
    from_words = :"__hw_init_#{fun}__"

    cond do
      # a state holding tuples: as written, its values from the words, its tuples zeros
      function_exported?(mod, from_words, 1) ->
        apply(mod, from_words, [words])

      k["memories"] != [] ->
        put_elem(zero, 0, fill(elem(zero, 0), words) |> elem(0))

      true ->
        fill(zero, words) |> elem(0)
    end
  end

  defp fill(zero, words) when is_tuple(zero) do
    {items, rest} = zero |> Tuple.to_list() |> Enum.map_reduce(words, &fill/2)
    {List.to_tuple(items), rest}
  end

  defp fill(_zero, [w | rest]), do: {w, rest}

  defp flat_type(t) when is_list(t), do: Enum.flat_map(t, &flat_type/1)
  defp flat_type(t), do: [t]

  defp shape([x], t) when not is_list(t), do: x

  defp shape(words, t) do
    {items, []} = Enum.map_reduce(t, words, fn e, ws ->
      n = length(flat_type(e))
      {shape(Enum.take(ws, n), e), Enum.drop(ws, n)}
    end)

    List.to_tuple(items)
  end

  # a list: an output that may be missing ([] / [y]); a result is as wide as its type, here as a 64-bit word
  defp flat([]), do: []
  defp flat([y]), do: flat(y)
  defp flat(y) when is_tuple(y), do: y |> Tuple.to_list() |> Enum.flat_map(&flat/1)
  defp flat(y), do: [y &&& 0xFFFFFFFFFFFFFFFF]
end
