defmodule EHLS.CpuStage do
  @moduledoc false
  # `map(&f/1, on: :cpu)` in a `definstance`: the stage runs on the CPU, as C (`mix ehls.compile --target cpu`),
  # and the instance is cut there into two, `<name>__pre` (what comes before: its stream goes to the CPU) and
  # `<name>__post` (what comes after: its stream comes from the CPU), which are ordinary instances with CPU ends.
  # `<name>(:cpu_start, opts)` starts the process (EHLS.CpuDriver) that takes the stream from the one, through the NIF, to
  # the other. See EHLS.Pipeline, "Stages on the CPU".

  @doc """
  An instance `{head, opts, chain, line}` of a module: itself in a list, or, when stages say `on: :cpu`, the instances it is cut
  into; the quoted functions that start the drivers (`[]` when it was not cut); and the kernels to define for functions on the
  CPU with levels wired in, `{name, head, body}` (`place`, a chain -> `EHLS.Level.place/7` on it, made them, as in the FPGA).

  The stages are cut into runs, of the FPGA and of the CPU in turn: `a |> b |> cpu1 |> c |> cpu2 |> cpu3` is the FPGA's `a b`
  (`name__pre`), the CPU's `cpu1`, the FPGA's `c` (`name__1`), the CPU's `cpu2 cpu3` (one process runs the CPU stages that
  follow each other). The last run of the FPGA is `name__post`. Between an FPGA run and the next one there is a driver.
  """
  def split({head, opts, chain, line}, module, states, types \\ %{}, place \\ &{&1, []}) do
    {name, args} = EHLS.Pipeline.head!(head)
    # a stage's on: :fpga in an instance in the FPGA says where it is already
    chain = in_place(chain)
    instance = {head, opts, chain, line}
    stages = chain |> EHLS.Pipeline.normalize() |> unpipe([])

    if not Enum.any?(stages, &cpu?/1) do
      {[instance], [], []}
    else
      runs = runs(stages)

      case runs do
        [{:cpu, _} | _] ->
          raise ArgumentError, "definstance #{name}: a stage on the CPU needs the FPGA before it (a source, or the argument and something between)"

        [{:fpga, [{v, _, c}]}, {:cpu, _} | _] when is_atom(v) and is_atom(c) ->
          raise ArgumentError, "definstance #{name}: nothing between the argument and the stage on the CPU: call the NIF from the CPU, or place a stage before it"

        _ ->
          :ok
      end

      # the FPGA runs, named: __pre, __1, __2, ..., the last __post when the instance ends in the FPGA
      fpga = for {{:fpga, st}, i} <- Enum.with_index(Enum.filter(runs, &match?({:fpga, _}, &1))), do: {i, st}
      last_fpga = if match?({:fpga, _}, List.last(runs)), do: length(fpga) - 1
      iname = fn
        0 -> String.to_atom("#{name}__pre")
        i when i == last_fpga -> String.to_atom("#{name}__post")
        i -> String.to_atom("#{name}__#{i}")
      end

      instances =
        for {i, st} <- fpga do
          if i == 0 do
            {{iname.(0), [], args}, Keyword.put(opts, :cut_of, name), repipe(st), line}
          else
            input = {:cpu_in, [], nil}
            {{iname.(i), [], [input]}, [], repipe([input | st]), line}
          end
        end

      # a driver for each CPU run: from the FPGA run before it to the one after (none: the results go to `to:`)
      hops =
        for {{:cpu, group}, j} <- Enum.with_index(Enum.filter(runs, &match?({:cpu, _}, &1))) do
          before = Enum.at(fpga, j) |> elem(1)
          after_ = case Enum.at(fpga, j + 1) do
            nil -> nil
            {_, st} -> st
          end

          fs = for st <- group, do: function!(name, module, st, states, place)
          made = for {_, _, _, defs} <- fs, {g, _, _} <- defs, do: g
          kernels!(name, module, for({f, _, _, _} <- fs, f not in made, do: f))
          kernels = for {f, init, wires, _} <- fs, do: {String.to_atom("#{inspect(module)}.#{f}"), init, wires}
          cut_types!(name, List.last(before), for({f, _, _, _} <- fs, f not in made, do: f), if(after_, do: hd(after_)), types)
          {{iname.(j), if(after_, do: iname.(j + 1)), kernels}, Enum.flat_map(fs, &elem(&1, 3))}
        end

      {instances, [driver(name, module, Enum.map(hops, &elem(&1, 0)))], Enum.flat_map(hops, &elem(&1, 1))}
    end
  end

  # [{:fpga, stages} | {:cpu, stages}], in turn
  defp runs(stages) do
    stages
    |> Enum.chunk_by(&cpu?/1)
    |> Enum.map(fn [first | _] = run -> {if(cpu?(first), do: :cpu, else: :fpga), run} end)
  end

  # The stream crosses the cut as packed bytes (EHLS.packed_size/1), so what comes out of the stage before must be exactly
  # what f takes, and what f gives exactly what the stage after takes: a widening the FPGA does for free (u8 to u16) would
  # change the size of an element. Between CPU stages too (one gives what the next takes). Only where both are known (a
  # defhls function on each side).
  defp cut_types!(name, before, fs, after_, types) do
    ends = [stage_function(before) | Enum.map(fs, &{&1, nil})] ++ [stage_function(after_)]

    ends
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [a, b] ->
      with {g, _} <- a, {h, _} <- b, {_, g_out} <- types[g], {h_in, _} <- types[h],
           do: same!(name, g, "gives", g_out, h, "takes", h_in)
    end)
  end

  defp same!(_name, _a, _, t, _b, _, t), do: :ok

  defp same!(name, a, va, ta, b, vb, tb) do
    raise ArgumentError,
          "definstance #{name}: #{a} #{va} #{EHLS.type_name(ta)} and #{b} #{vb} #{EHLS.type_name(tb)}: across the cut to the CPU the stream " <>
            "is packed bytes, so the types must be the same; put a map between them to change it"
  end

  # the defhls function a stage names, if it is one (map(&g/1), transform(init, &g/2), g())
  defp stage_function({:map, _, [f | _]}), do: named(f)
  defp stage_function({:transform, _, [_init, f | _]}), do: named(f)
  defp stage_function({g, _, args}) when is_atom(g) and (args == [] or is_atom(args)), do: {g, nil}
  defp stage_function(_), do: nil

  defp named({:&, _, [{:/, _, [{f, _, _}, _]}]}) when is_atom(f), do: {f, nil}
  defp named({f, _, c}) when is_atom(f) and is_atom(c), do: {f, nil}
  defp named(_), do: nil

  # map(&f/1, on: :fpga) / transform(init, &f/2, on: :fpga) without the on:, wherever they are in the body
  defp in_place(chain) do
    Macro.prewalk(chain, fn
      {:map, m, [f, opts]} = st when is_list(opts) -> if fpga_opt?(opts), do: off(:map, m, [f], opts), else: st
      {:transform, m, [init, f, opts]} = st when is_list(opts) -> if fpga_opt?(opts), do: off(:transform, m, [init, f], opts), else: st
      other -> other
    end)
  end

  defp fpga_opt?(opts), do: Keyword.keyword?(opts) and Keyword.get(opts, :on) == :fpga

  defp off(stage, m, args, opts) do
    case Keyword.delete(opts, :on) do
      [] -> {stage, m, args}
      rest -> {stage, m, args ++ [rest]}
    end
  end

  # `map(&f/1, on: :cpu)`
  defp cpu?({:map, _, [_f, o]}) when is_list(o), do: Keyword.get(o, :on) == :cpu
  defp cpu?({:transform, _, args}) when is_list(args), do: is_list(List.last(args)) and Keyword.keyword?(List.last(args)) and Keyword.get(List.last(args), :on) == :cpu
  defp cpu?(_), do: false

  # Each function on the CPU runs as its kernel's C, so it must be one: a defhls of several plain arguments (a level after
  # the stream, `volume(frame :: u32, gain :: u9)`) is a kernel only where its level is wired in, as `map(&volume(&1, g(:value)))`
  defp kernels!(name, module, fs) do
    kernels = Module.get_attribute(module, :hw_cpu) || %{}

    for f <- fs, not Map.has_key?(kernels, f) do
      raise ArgumentError,
            "definstance #{name}: #{f} on the CPU takes its other arguments where it is placed, as in the FPGA: " <>
              "map(&#{f}(&1, g(:value)), on: :cpu), each an integer or a level; or its second argument as a state: " <>
              "transform(init, &#{f}/2, on: :cpu)"
    end
  end

  # {the kernel, its initial state words (nil: the function's own), the wires of its levels (EHLS.Level.place; nil: none),
  # the kernels made for it, to define}: a function with levels wired in is placed as in the FPGA, a kernel made for it
  defp function!(name, module, {:map, m, [f, opts]} = stage, states, place) do
    only_on!(name, opts)

    case place.({:map, m, [f]}) do
      {{g, gm, []}, defs} when is_atom(g) ->
        {g, nil, gm[:ehls_wires], defs}

      {_, []} ->
        f = fun!(name, f, stage)
        # a kernel with a state (memory, or a list for a missing output); a plain function of several arguments is kernels!'s
        if Map.has_key?(states, f) and Map.has_key?(Module.get_attribute(module, :hw_cpu) || %{}, f),
          do: raise(ArgumentError, "definstance #{name}: #{f} has a state: transform(init, &#{f}/2, on: :cpu)")
        {f, nil, nil, []}
    end
  end

  defp function!(name, _module, {:transform, m, [init, f, opts]} = stage, states, place) do
    only_on!(name, opts)

    # a plain function placed with its accumulator: the kernel made for it keeps its second argument as the state
    {wires, g, defs} =
      case place.({:transform, m, [init, f]}) do
        {{:transform, tm, [_, g | _]}, defs} -> {tm[:ehls_wires], fun!(name, g, stage), defs}
      end

    spec =
      case defs do
        [] -> Map.get(states, g)
        _ -> Map.get(states, fun!(name, f, stage))
      end || raise(ArgumentError, "definstance #{name}: #{g} has no state: map(&#{g}/1, on: :cpu)")

    {g, EHLS.__init_words__(init, spec), wires, defs}
  end

  defp function!(name, _module, other, _states, _place),
    do: raise(ArgumentError, "definstance #{name}: on: :cpu goes with map(&f/1, on: :cpu) or transform(init, &f/2, on: :cpu), not #{Macro.to_string(other)}")

  # what a function's levels are, read by the driver before each batch: an integer, or an instance of levels read as the CPU
  # reads it (a pin's level wired into a function on the CPU is not there yet)
  defp level_reads(name, wires) do
    for w <- wires do
      cond do
        Map.has_key?(w, :const) ->
          w.const

        Map.has_key?(w, :from) ->
          [mod, lname] = String.split(w.from, ~r/\.(?=[^.]+$)/)
          quote(do: apply(unquote(Module.concat([mod])), unquote(String.to_atom(lname)), [:value]))

        true ->
          raise ArgumentError, "definstance #{name}: a pin's level wired into a function on the CPU is not there yet"
      end
    end
  end

  defp fun!(_name, {:&, _, [{:/, _, [{f, _, _}, n]}]}, _) when is_atom(f) and n in [1, 2], do: f
  defp fun!(_name, {f, _, c}, _) when is_atom(f) and is_atom(c), do: f
  defp fun!(_name, {:&, _, [{f, _, [{:&, _, [1]}, {:&, _, [2]} | _]}]}, _) when is_atom(f), do: f
  defp fun!(name, _, stage), do: raise(ArgumentError, "definstance #{name}: &f/1 or &f/2 expected in #{Macro.to_string(stage)}")

  # the stage runs on the CPU: there is no circuit whose state could be named and read
  defp only_on!(name, opts) do
    case Keyword.keys(opts) -- [:on] do
      [] -> :ok
      other -> raise ArgumentError, "definstance #{name}: a stage on the CPU takes only on: (not #{Enum.join(other, ", ")})"
    end
  end

  defp unpipe({:|>, _, [lhs, rhs]}, acc), do: unpipe(lhs, [rhs | acc])
  defp unpipe(first, acc), do: [first | acc]

  defp repipe([first | rest]), do: Enum.reduce(rest, first, fn s, acc -> {:|>, [], [acc, s]} end)

  # name(:cpu_start, opts) -> the driver's pid (a list of them when there are several); name(:cpu_stop, pid or pids)
  defp driver(name, module, hops) do
    rt = EHLS.runtime()

    specs =
      for {pre, post, kernels3} <- hops do
        kernels = for {k, init, _} <- kernels3, do: {k, init}

        # the levels wired in, read before each batch, unless levels: says otherwise
        wired = for {k, _, wires} <- kernels3, wires not in [nil, []], do: {k, level_reads(name, wires)}

        levels =
          if wired != [] do
            clauses =
              for({k, reads} <- wired, do: {:->, [], [[k], reads]}) ++ [{:->, [], [[{:_, [], nil}], []]}]

            quote do
              fn kernel ->
                case kernel do
                  unquote(clauses)
                end
              end
            end
          end

        # cancels what the FPGA's ends have in flight when the driver stops (their instances are `<module>.<name>`)
        cancel =
          if rt do
            pre_key = String.to_atom("#{inspect(module)}.#{pre}")
            post_key = post && String.to_atom("#{inspect(module)}.#{post}")

            quote do
              fn ->
                unquote(rt).end_cancel(:hw_kernels.cpu_end(unquote(pre_key), :out))
                unquote(if post_key, do: quote(do: unquote(rt).end_cancel(:hw_kernels.cpu_end(unquote(post_key), :cpu_in))))
                :ok
              end
            end
          end

        quote do
          %{
            name: unquote(name),
            kernels: unquote(kernels),
            pre: unquote(pre),
            post: unquote(post),
            request: fn n -> unquote(pre)(:request, :out, n) end,
            cancel: unquote(cancel),
            send: unquote(if post, do: quote(do: fn bin -> unquote(post)(:send, :cpu_in, bin) end)),
            opts: unquote(if levels, do: quote(do: Keyword.put_new(opts, :levels, unquote(levels))), else: quote(do: opts))
          }
        end
      end

    quote do
      @doc false
      def unquote(name)(:cpu_start, opts) when is_list(opts) do
        # not called by name: the driver is the target's (priv/backend/atomvm/lib), not on this computer
        pids = for spec <- unquote(specs), do: apply(EHLS.CpuDriver, :start, [spec])

        case pids do
          [pid] -> pid
          pids -> pids
        end
      end

      def unquote(name)(:cpu_stats, pids), do: apply(EHLS.CpuDriver, :stats, [pids])

      def unquote(name)(:cpu_stop, pids) do
        for pid <- List.wrap(pids), do: send(pid, :cpu_stop)
        :ok
      end
    end
  end
end
