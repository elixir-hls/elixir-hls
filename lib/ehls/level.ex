defmodule EHLS.Level do
  @moduledoc false
  # A level instance: a `definstance` whose arguments have types. Its arguments and its result are levels,
  # values that only matter as their latest, not streams:
  #
  #     definstance k_hw(v :: u9), initial: 3 do
  #       v
  #     end
  #
  # The body is one of its arguments, a tuple of them, or a call of a defhls function of the module. It
  # becomes a kernel of its own (a generated defhls, `<name>__level`), fired by the CPU's write of the
  # arguments (way B of the design: elixir-hls #33). The circuit (hls_level_adapter.v) takes the words
  # the CPU wrote all in one clock at the start write, computes, and holds the result, `initial:` until
  # the first one and after a :start. It counts the start writes and holds, with the result, the count
  # of the write it is for, so a call waits for its own write. Here: the compile-time description; the calls
  # on the CPU are EHLS.__level_call__/5 and __level_value__/2, which run on the board.
  @doc false
  # does the head say a level instance? (an argument with a type)
  def level?(args), do: Enum.any?(args, &match?({:"::", _, [_, _]}, &1))

  @doc false
  # %{args: [{name, spec, var, type_ast}], ret: spec, initial: value, body: ast}
  def describe!(name, args, opts, body, fns, spec!) do
    args =
      for a <- args do
        case a do
          {:"::", _, [{v, _, ctx} = var, t]} when is_atom(v) and is_atom(ctx) ->
            if v == :out, do: raise(ArgumentError, "definstance #{name}: an argument cannot be called out, the name of the result")
            {v, spec!.(t), var, t}

          _ ->
            raise ArgumentError,
                  "definstance #{name}: an argument with a type is a level, one without a stream; levels and a stream in one instance are not there yet"
        end
      end

    names = Enum.map(args, &elem(&1, 0))
    if length(Enum.uniq(names)) != length(names), do: raise(ArgumentError, "definstance #{name}: two arguments of the same name")

    for {k, _} <- opts, k != :initial,
        do: raise(ArgumentError, "definstance #{name}: unknown option #{k} (a level instance takes initial:)")

    body = unblock(body)
    ret = ret!(name, body, Map.new(args, fn {v, spec, _, _} -> {v, spec} end), fns)
    initial = initial!(name, Keyword.get(opts, :initial, zero(ret)), ret)
    %{args: args, ret: ret, initial: initial, body: body}
  end

  defp unblock({:__block__, _, [e]}), do: unblock(e)
  defp unblock(e), do: e

  # the result's type: an argument's, a tuple of them, or what the called function gives
  defp ret!(name, body, args, fns) do
    case body do
      {v, _, ctx} when is_atom(v) and is_atom(ctx) and is_map_key(args, v) ->
        Map.fetch!(args, v)

      {a, b} ->
        {:tuple, [ret!(name, a, args, fns), ret!(name, b, args, fns)]}

      {:{}, _, items} ->
        {:tuple, Enum.map(items, &ret!(name, &1, args, fns))}

      {f, _, cargs} when is_atom(f) and is_list(cargs) and is_map_key(fns, f) ->
        %{params: params, ret: ret} = Map.fetch!(fns, f)

        if length(cargs) != length(params),
          do: raise(ArgumentError, "definstance #{name}: #{f} takes #{length(params)} argument(s), got #{length(cargs)}")

        ret

      other ->
        raise ArgumentError,
              "definstance #{name}: the body of an instance of levels is one of its arguments, a tuple of them, or a call of a defhls function of this module without state, got #{Macro.to_string(other)}"
    end
  end

  defp zero({:tuple, specs}), do: specs |> Enum.map(&zero/1) |> List.to_tuple()
  defp zero(_), do: 0

  # initial: a literal of the result's type, cut to it
  defp initial!(name, ast, ret) do
    value =
      try do
        {v, _} = Code.eval_quoted(ast)
        v
      rescue
        _ -> raise ArgumentError, "definstance #{name}: initial: is a literal, got #{Macro.to_string(ast)}"
      end

    cut(name, value, ret)
  end

  defp cut(_name, v, {w, s}) when is_integer(v) and is_integer(w), do: EHLS.wrap(v, w, s)

  defp cut(name, t, {:tuple, specs}) when is_tuple(t) and tuple_size(t) == length(specs),
    do: t |> Tuple.to_list() |> Enum.zip(specs) |> Enum.map(fn {v, s} -> cut(name, v, s) end) |> List.to_tuple()

  defp cut(name, v, spec),
    do: raise(ArgumentError, "definstance #{name}: initial: #{inspect(v)} is not a value of the result's type #{inspect(spec_text(spec))}")

  defp spec_text({:tuple, specs}), do: specs |> Enum.map(&spec_text/1) |> List.to_tuple()
  defp spec_text({n, s}), do: :"#{if s, do: "s", else: "u"}#{n}"

  @doc false
  # the generated defhls: one argument as it is, several as one tuple taken apart
  def kernel_def(gname, %{args: args, ret: ret, body: body}, spec_ast) do
    case args do
      [{_, _, var, t}] ->
        {{:"::", [], [{gname, [], [{:"::", [], [var, t]}]}, spec_ast.(ret)]}, body}

      _ ->
        x = {:hw__levels, [], nil}
        t = {:{}, [], Enum.map(args, &elem(&1, 3))}
        split = {:=, [], [{:{}, [], Enum.map(args, &elem(&1, 2))}, x]}
        {{:"::", [], [{gname, [], [{:"::", [], [x, t]}]}, spec_ast.(ret)]}, {:__block__, [], [split, body]}}
    end
  end

  # ---- a level wired into a function placed in a stream ----

  @doc false
  # The stages placing a function of several arguments in the stream, `map(&f(&1, src))` or (the pipe
  # gives the first) `f(src)`, each other argument a level (`g(:value)`, `Other.g(:value)`) or an integer:
  # each becomes a generated defhls of one argument, the levels its arguments after it (inputs the kernel
  # reads when it fires), and the stage says where each comes from (meta :ehls_wires). Returns
  # {chain, [{name, head, body}]}. `levels`: this module's instances of levels, name => %{ret, initial}.
  def place(chain, fns, levels, module, spec_ast, vars \\ %{}, klevels \\ %{}) do
    {stages, defs} =
      chain
      |> unpipe([])
      |> Enum.map_reduce([], fn stage, defs ->
        case placed(stage, fns, klevels) do
          nil ->
            {stage, defs}

          # a function with a state and levels: its own kernel, its levels' sources on the stage
          {:transform, f, init, opts, others, m} ->
            EHLS.Error.at(m[:line], fn ->
              ks = Map.fetch!(klevels, f)

              if length(others) != length(ks),
                do: raise(ArgumentError, "definstance: #{f} takes #{length(ks)} level(s) after its state, got #{length(others)}")

              wires =
                for {{{pv, spec}, other}, i} <- Enum.with_index(Enum.zip(ks, others), 1) do
                  case source!(f, pv, spec, other, i, {levels, vars}, module) do
                    {{c, nil}, nil} -> %{arg: Atom.to_string(pv), const: c, type: type_text(spec)}
                    {_, wire} -> %{wire | arg: Atom.to_string(pv)}
                  end
                end

              capture = {:&, [], [{:/, [], [{f, [], nil}, 2]}]}
              {{:transform, Keyword.put(m, :ehls_wires, wires), [init, capture | opts]}, defs}
            end)

          # a plain function placed with its accumulator: the kernel with a state made here
          {:accumulator, f, init, opts, others, m} ->
            EHLS.Error.at(m[:line], fn ->
              {mems, opts} = memory_opt(opts)

              {gname, head, body, wires} =
                if mems == [],
                  do: stateful_at(f, others, Map.fetch!(fns, f), {levels, vars}, module, spec_ast),
                  else: memory_at(f, mems, others, module)

              capture = {:&, [], [{:/, [], [{gname, [], nil}, 2]}]}
              m = m |> Keyword.put(:ehls_wires, wires) |> Keyword.put(:ehls_of, f)
              {{:transform, m, [init, capture | opts]}, [{gname, head, body} | defs]}
            end)

          {f, pos, others, m} ->
            EHLS.Error.at(m[:line], fn ->
              {gname, head, body, wires} = kernel_at(f, pos, others, Map.fetch!(fns, f), {levels, vars}, module, spec_ast)
              {{gname, m |> Keyword.put(:ehls_wires, wires) |> Keyword.put(:ehls_of, f), []}, [{gname, head, body} | defs]}
            end)
        end
      end)

    {repipe(stages), defs |> Enum.reverse() |> Enum.uniq_by(&elem(&1, 0))}
  end

  # a function of several arguments placed with transform: its second argument the accumulator (EHLS.Compiler, plain_form)
  defp placed({:transform, m, [init, {:&, _, [{:/, _, [{f, _, _}, 2]}]} | opts]}, fns, klevels)
       when is_atom(f) and is_map_key(fns, f) and not is_map_key(klevels, f),
       do: {:accumulator, f, init, opts, [], m}

  defp placed({:transform, m, [init, {:&, _, [{f, _, [{:&, _, [1]}, {:&, _, [2]} | others]}]} | opts]}, fns, klevels)
       when is_atom(f) and is_map_key(fns, f) and not is_map_key(klevels, f),
       do: {:accumulator, f, init, opts, others, m}

  # {function, position of the stream, the other arguments, meta}, nil for a stage of another kind
  defp placed({:transform, m, [init, {:&, _, [{f, _, [{:&, _, [1]}, {:&, _, [2]} | others]}]} | opts]}, _fns, klevels)
       when is_atom(f) and is_map_key(klevels, f),
       do: {:transform, f, init, opts, others, m}

  defp placed({:transform, m, [_init, {:&, _, [{:/, _, [{f, _, _}, 2]}]} | _]}, _fns, klevels) when is_atom(f) and is_map_key(klevels, f) do
    case Map.fetch!(klevels, f) do
      [] -> nil
      ks ->
        EHLS.Error.at(m[:line], fn ->
          raise ArgumentError,
                "definstance: #{f} takes level(s) after its state (#{Enum.map_join(ks, ", ", &elem(&1, 0))}): transform(init, &#{f}(&1, &2, #{Enum.map_join(ks, ", ", fn {pv, _} -> "#{pv}_hw(:value)" end)}))"
        end)
    end
  end

  defp placed({:map, m, [{:&, _, [{f, _, cargs}]}]}, fns, _klevels) when is_atom(f) and is_list(cargs) and is_map_key(fns, f) do
    case Enum.split_with(Enum.with_index(cargs), fn {a, _} -> match?({:&, _, [1]}, a) end) do
      {[{_, pos}], others} -> {f, pos, Enum.map(others, &elem(&1, 0)), m}
      _ -> EHLS.Error.at(m[:line], fn -> raise ArgumentError, "definstance: map(&#{f}(...)) takes the stream as &1, once" end)
    end
  end

  defp placed({f, m, args}, fns, _klevels) when is_atom(f) and is_list(args) and args != [] and is_map_key(fns, f) do
    if length(Map.fetch!(fns, f).params) == length(args) + 1, do: {f, 0, args, m}
  end

  defp placed(_, _, _), do: nil

  # transform's memory: [...] taken out of its options
  defp memory_opt([kw]) when is_list(kw) do
    case Keyword.pop(kw, :memory) do
      {nil, _} -> {[], [kw]}
      {mems, []} -> {mems!(mems), []}
      {mems, rest} -> {mems!(mems), [rest]}
    end
  end

  defp memory_opt(opts), do: {[], opts}

  defp mems!(mems) do
    unless is_list(mems) and mems != [] and Enum.all?(mems, &is_atom/1),
      do: raise(ArgumentError, "definstance: transform(init, &f/2, memory: [:hist]), the state's tuples by name")

    mems
  end

  # The generated defhls `<f>__m_<names>`: f with the tuples of its state named in memory: as memories (block RAM),
  # lowered by EHLS.TupleState; on the CPU it is f as written (the compiler's @hw_tuple_states)
  defp memory_at(f, mems, others, module) do
    if others != [], do: raise(ArgumentError, "definstance: transform(init, &#{f}(&1, &2, ...), memory: ...): levels with a memory are not there yet")
    mod = Module.concat([module])
    src0 = (Module.get_attribute(mod, :hw_tuple_sources) || %{})[f] ||
            raise(ArgumentError, "definstance: transform(init, &#{f}/2, memory: #{inspect(mems)}): #{f}'s state holds no tuple (tuple(t, n), or a tuple inside the state's tuple)")

    src =
      if length(src0.params) > 2,
        do: raise(ArgumentError, "definstance: transform(init, &#{f}/2, memory: ...): #{f} takes levels; levels with a memory are not there yet"),
        else: src0

    gname = :"#{f}__m_#{Enum.join(mems, "_")}"

    # an output that may be missing: [y] / [] as the kernel gives them, emit / skip
    body =
      if src.listed?,
        do: EHLS.Compiler.listed_out(src.body),
        else: src.body

    {lparams, {o, _st}, lbody, layout} = EHLS.TupleState.lower(f, src.params, src.ret_o, body, mems)

    out = if src.listed?, do: {:emit, [], [o]}, else: o

    tuples = Module.get_attribute(mod, :hw_tuple_states) || %{}
    Module.put_attribute(mod, :hw_tuple_states,
      Map.put(tuples, gname, %{params: src.params, ret: src.ret, body: src.body, guard: src.guard, layout: layout, listed?: src.listed?}))

    head = {:"::", [], [{gname, [], lparams}, out]}
    head = if src.guard, do: {:when, [], [head, src.guard]}, else: head
    {gname, head, lbody, []}
  end


  # The generated defhls `<f>__s<what the others are>` with a state: f(x, acc, levels...) -> {output, next acc}, its second
  # argument the state, the others levels or integers; and the wires of its level arguments
  defp stateful_at(f, others, %{params: params, ret: ret}, levels, module, spec_ast) do
    if length(params) < 2 or length(others) + 2 != length(params),
      do: raise(ArgumentError, "definstance: transform(init, &#{f}/2): #{f} takes the element, the state, then #{max(length(params) - 2, 0)} more")

    [{x_name, x_spec}, {_s_name, s_spec} | rest] = params

    out =
      case ret do
        {:tuple, [o, ^s_spec]} -> o
        _ -> raise ArgumentError, "definstance: transform(init, &#{f}/2): #{f} returns {output, next state}, its state #{type_text(s_spec)}"
      end

    if wide?(s_spec),
      do: raise(ArgumentError, "definstance: transform(init, &#{f}/2): the state of #{f} (#{type_text(s_spec)}) is up to 32 bits")

    {args, wires} =
      Enum.zip(rest, others)
      |> Enum.with_index(1)
      |> Enum.map(fn {{{p, spec}, other}, i} -> source!(f, p, spec, other, i, levels, module) end)
      |> Enum.unzip()

    x = {:hw__x, [], nil}
    st = {:hw__acc, [], nil}
    level_params = for {_, {var, spec, default}} <- Enum.filter(args, &match?({_, {_, _, _}}, &1)),
                       do: {:\\, [], [{:"::", [], [var, {:hw__level, [], [spec_ast.(spec)]}]}, default]}

    suffix = Enum.map_join(args, fn {_, {_, _, _}} -> "_l"; {c, nil} -> "_c#{c}" end) |> String.replace("-", "m")
    gname = :"#{f}__s#{suffix}"
    _ = x_name

    head =
      {:"::", [], [{gname, [], [{:"::", [], [x, spec_ast.(x_spec)]}, {:"::", [], [st, {:state, [], [spec_ast.(s_spec)]}]} | level_params]},
                   spec_ast.(out)]}

    {gname, head, {f, [], [x, st | Enum.map(args, &elem(&1, 0))]}, Enum.reject(wires, &is_nil/1)}
  end

  # the generated defhls `<f>__<pos><what the others are>` and the wires of its level arguments
  defp kernel_at(f, pos, others, %{params: params, ret: ret}, levels, module, spec_ast) do
    if length(others) + 1 != length(params),
      do: raise(ArgumentError, "definstance: #{f} takes #{length(params)} argument(s), got #{length(others) + 1}")

    {x_name, x_spec} = Enum.at(params, pos)
    rest = List.delete_at(params, pos)

    {args, wires} =
      Enum.zip(rest, others)
      |> Enum.with_index(1)
      |> Enum.map(fn {{{p, spec}, other}, i} -> source!(f, p, spec, other, i, levels, module) end)
      |> Enum.unzip()

    x = {:hw__x, [], nil}
    call_args = List.insert_at(Enum.map(args, &elem(&1, 0)), pos, x)
    params_ast = for {_, {var, spec, default}} <- Enum.filter(args, &match?({_, {_, _, _}}, &1)),
                     do: {:\\, [], [{:"::", [], [var, {:hw__level, [], [spec_ast.(spec)]}]}, default]}

    suffix = Enum.map_join(args, fn {_, {_, _, _}} -> "_l"; {c, nil} -> "_c#{c}" end) |> String.replace("-", "m")
    gname = :"#{f}__#{x_name}#{suffix}"
    head = {:"::", [], [{gname, [], [{:"::", [], [x, spec_ast.(x_spec)]} | params_ast]}, spec_ast.(ret)]}
    {gname, head, {f, [], call_args}, Enum.reject(wires, &is_nil/1)}
  end

  # an argument besides the stream: an integer, or a level read as the CPU reads it, g(:value)
  defp source!(_f, _p, _spec, c, _i, _levels, _module) when is_integer(c), do: {{c, nil}, nil}
  defp source!(_f, _p, _spec, {:-, _, [c]}, _i, _levels, _module) when is_integer(c), do: {{-c, nil}, nil}

  # a level argument of the stream function being defined (vars: name => spec), given where it is placed
  defp source!(f, p, {w, _} = spec, {v, _, ctx}, i, {_levels, vars}, _module)
       when w <= 32 and is_atom(v) and is_atom(ctx) and is_map_key(vars, v) do
    unless EHLS.Pipeline.widens?(Map.fetch!(vars, v), spec),
      do: raise(ArgumentError, "defhls: #{v} is #{type_text(Map.fetch!(vars, v))} and #{f}'s #{p} is #{type_text(spec)}, which would change the value")

    var = {:"hw__lv#{i}", [], nil}
    {{var, {var, spec, 0}}, %{arg: "hw__lv#{i}", var: v, type: type_text(spec)}}
  end

  # a pin's level (EHLS.GPIO): the pin is found when the circuits are put together (gen_manifest.py)
  defp source!(f, p, {w, _} = spec, {{:., _, [{:__aliases__, _, [:EHLS, :GPIO]}, :read]}, _, [pin]}, i, _levels, _module)
       when w <= 32 do
    unless is_atom(pin), do: raise(ArgumentError, "definstance: #{f}'s #{p}: EHLS.GPIO.read takes a pin's name, an atom")

    unless EHLS.Pipeline.widens?({1, false}, spec),
      do: raise(ArgumentError, "definstance: a pin gives u1 and #{f}'s #{p} is #{type_text(spec)}, which would change the value")

    var = {:"hw__lv#{i}", [], nil}
    {{var, {var, spec, 0}}, %{arg: "hw__lv#{i}", pin: Atom.to_string(pin), type: type_text(spec)}}
  end

  defp source!(f, p, {w, _} = spec, src, i, {levels, _vars}, module) when w <= 32 do
    {mod, name} =
      case src do
        {name, _, [:value]} when is_atom(name) ->
          {module, name}

        {{:., _, [{:__aliases__, _, parts}, name]}, _, [:value]} when is_atom(name) ->
          {inspect(Module.concat(parts)), name}

        other ->
          raise ArgumentError,
                "definstance: #{f}'s #{p} is #{Macro.to_string(other)}: an argument besides the stream is an integer or a level, read as the CPU reads it (g(:value), EHLS.GPIO.read(:pin))"
      end

    default =
      if mod == module do
        case Map.fetch(levels, name) do
          {:ok, %{on: :cpu}} ->
            raise ArgumentError,
                  "definstance: #{name} runs on the CPU (no backend that makes circuits, or on: :cpu), so no wire reaches it from " <>
                    "an instance in the FPGA: place it there too (definstance #{name}(...), on: :fpga)"

          {:ok, %{ret: {w, _} = ret, initial: initial}} when is_integer(w) ->
            unless EHLS.Pipeline.widens?(ret, spec),
              do: raise(ArgumentError, "definstance: #{name} gives #{type_text(ret)} and #{f}'s #{p} is #{type_text(spec)}, which would change the value")

            initial

          {:ok, %{ret: ret}} ->
            raise ArgumentError, "definstance: #{name} gives #{type_text(ret)}, a tuple: a level wired to #{f}'s #{p} is one value"

          :error ->
            raise ArgumentError, "definstance: #{name} is not an instance of levels of #{mod}"
        end
      else
        # checked when the circuits are put together (gen_manifest.py)
        0
      end

    var = {:"hw__lv#{i}", [], nil}
    {{var, {var, spec, default}}, %{arg: "hw__lv#{i}", from: "#{mod}.#{name}", type: type_text(spec)}}
  end

  defp source!(f, p, spec, _src, _i, _levels, _module),
    do: raise(ArgumentError, "definstance: #{f}'s #{p} is #{type_text(spec)}: a level wired to it is one value up to 32 bits")

  defp type_text({:tuple, specs}), do: "{" <> Enum.map_join(specs, ", ", &type_text/1) <> "}"
  defp type_text({n, s}), do: "#{if s, do: "s", else: "u"}#{n}"

  # the CPU reads a state in 32-bit words
  defp wide?({:tuple, specs}), do: Enum.any?(specs, &wide?/1)
  defp wide?({w, _}) when is_integer(w), do: w > 32
  defp wide?(_), do: false

  defp unpipe({:|>, _, [lhs, rhs]}, acc), do: unpipe(lhs, [rhs | acc])
  defp unpipe(first, acc), do: [first | acc]

  defp repipe([first | rest]), do: Enum.reduce(rest, first, fn s, acc -> {:|>, [], [acc, s]} end)
end

