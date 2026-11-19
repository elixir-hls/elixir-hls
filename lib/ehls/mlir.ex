defmodule EHLS.MLIR do
  @moduledoc """
  Translates the body of a `defhls` function (an Elixir AST) into MLIR (func + arith + cf +
  memref) for CIRCT `hlstool --dynamic-hw`. Host-only: used by the `defhls` macro at compile
  time.

  Supported: integer literals, variables and `=` bindings (also of tuples), tuples,
  `+ - *`, unary `-`, `&&& ||| ^^^ <<< >>>` (shifts by a constant; `>>>` also by an unsigned value), comparisons,
  `and or not`, `if/else`, `signed(x, n)` / `unsigned(x, n)`, a missing output (`{[v], s}` / `{[], s}` in a `defhls`), and for
  kernels with memories and tables: `elem(mem, i)`, `mem = put_elem(mem, i, v)` (at the top level
  of the body; read / write here, as EHLS.Compiler gives them), `table(@attr, i)`, `for k <- a..b, reduce: init do acc -> ... end` (also with
  tuples),
  `Enum.sum(for k <- a..b, do: e)`, and `Enum.reduce(a..b, init, fn k, acc -> ... end)`
  (unrolled: a pipeline instead of a loop).

  Widths: every value carries a width and signedness, derived from its operands so that no
  operation can overflow (`+` adds one bit, `*` adds the widths, `&&&` with a non-negative
  constant narrows to the constant, ...). The result is the exact integer, which the
  function's return type then wraps, like the CPU version. A `reduce` accumulator gets the
  width of one step plus log2 of the iteration count (it is meant for sums).

  Control flow: an `if` whose branches contain no loop is computed on both sides and
  selected (`arith.select`); otherwise it becomes branches (`cf.cond_br`) joining in a block
  whose arguments carry the result. A `reduce` is a loop (header, body, exit blocks).
  Memory indices wrap (the low bits of the index), like the CPU version.
  """

  defmodule V do
    @moduledoc false
    # An SSA value: name ("%3"), width, signedness; const holds a literal not yet materialised
    defstruct name: nil, w: 1, s: false, const: nil
  end

  @max_width 64
  # a memory space's words
  @mem 32

  @doc """
  Returns `{mlir_text, space}` for `func @name`. `params` is a list of `{var, type}` where a
  type is `{width, signed?}`, `{:tuple, [type]}` or `{:memory, size, {width, signed?}}`;
  `tables` a list of `{name, [integer]}` (`table(@name, i)`); `result` the type of the body's
  value. Every scalar becomes one port of `lane` bits (32 or 64, the kernel's), in order (tuples flattened). Tables and memories
  share one address space, one `memref<2^aw x i32>` argument after the scalars (several
  memref arguments crash hlstool of CIRCT 1.160 in some combinations): each region at a
  multiple of its (power of two) size. `space` describes it, or is nil:
  `%{aw: bits, regions: [%{kind: :rom | :ram, name:, base:, size:, values: (rom)}]}`.
  """
  def function(name, params, result, body, tables \\ [], lane \\ 32) do
    st = %{port: lane, n: 0, lines: [], env: %{}, arg: 0, blocks: [], label: nil, largs: "", nb: 0, depth: 0}
    {mems, scalars} = Enum.split_with(params, fn {_, t} -> match?({:memory, _, _}, t) end)

    {st, ports} =
      Enum.reduce(scalars, {st, []}, fn {var, type}, {st, ports} ->
        {value, st, ps} = bind_param(type, st)
        {%{st | env: Map.put(st.env, var, value)}, ports ++ ps}
      end)

    # the address space: tables, then memories, each region aligned to its size
    regions =
      Enum.map(tables, fn {t, values} -> %{kind: :rom, name: t, size: length(values), values: values} end) ++
        Enum.map(mems, fn {var, {:memory, size, elem}} -> %{kind: :ram, name: var, size: size, elem: elem} end)

    {regions, top} =
      regions
      |> Enum.sort_by(& -pow2(&1.size))
      |> Enum.map_reduce(0, fn r, at -> {Map.put(r, :base, at), at + pow2(r.size)} end)

    {st, ports, space} =
      if regions == [] do
        {st, ports, nil}
      else
        aw = addr_width(top)
        aname = "%arg#{st.arg}"
        space = %{aw: aw, regions: regions}

        env =
          Enum.reduce(regions, st.env, fn
            %{kind: :rom, name: t, size: size, values: values, base: base}, env ->
              lo = Enum.min(values)
              hi = Enum.max(values)
              elem = if lo < 0, do: {max(const(lo).w, const(hi).w + 1), true}, else: {const(hi).w, false}
              env
              |> Map.put({:table, t}, {:table, aname, size, base, aw, elem})
              |> Map.put({:table_values, t}, List.to_tuple(values))

            %{kind: :ram, name: var, size: size, elem: elem, base: base}, env ->
              Map.put(env, var, {:mem, aname, size, base, aw, elem})
          end)

        {%{st | arg: st.arg + 1, env: env}, ports ++ ["#{aname}: memref<#{pow2(top)}xi#{@mem}>"], space}
      end

    {value, st} = expr(body, st)
    {rs, st} = flatten_result(value, result, st)
    types = Enum.map_join(rs, ", ", fn _ -> "i#{st.port}" end)
    st = finish(st, "return #{Enum.map_join(rs, ", ", & &1.name)} : #{types}")

    # tables only read at constant indices were folded: no memory space then
    {ports, space} =
      if space && not Enum.any?(st.blocks, fn b -> Enum.any?(b.lines, &String.contains?(&1, "memref.")) end),
        do: {Enum.reject(ports, &String.contains?(&1, "memref<")), nil},
        else: {ports, space}

    blocks =
      st.blocks
      |> Enum.reverse()
      |> Enum.map(fn %{label: label, largs: largs, lines: lines} ->
        head = if label, do: ["  ^#{label}#{largs}:\n"], else: []
        [head, Enum.map(lines, &["    ", &1, "\n"])]
      end)

    text = [
      "module {\n",
      "  func.func @#{name}(#{Enum.join(ports, ", ")}) -> (#{types}) {\n",
      blocks,
      "  }\n",
      "}\n"
    ]

    {IO.iodata_to_binary(text), space}
  end

  defp pow2(n), do: Bitwise.bsl(1, addr_width(n))

  # a parameter of type t: its value (a V, a tuple of them or a memory) and the ports it takes
  defp bind_param({:tuple, types}, st) do
    {vs, st, ports} =
      Enum.reduce(types, {[], st, []}, fn t, {vs, st, ports} ->
        {v, st, ps} = bind_param(t, st)
        {vs ++ [v], st, ports ++ ps}
      end)

    {{:tuple, vs}, st, ports}
  end

  defp bind_param({w, s}, st) do
    if w > st.port, do: raise(ArgumentError, "defhls: types up to #{st.port} bits")
    name = "%arg#{st.arg}"
    st = %{st | arg: st.arg + 1}
    {v, st} = trunc_or_ext(%V{name: name, w: st.port, s: false}, w, false, st)
    {%{v | s: s}, st, ["#{name}: i#{st.port}"]}
  end

  defp addr_width(size), do: max(1, bit_len(size - 1))

  # the body's value against the result type: each scalar wrapped to its type, then extended
  # to a port
  defp flatten_result({:tuple, vs}, {:tuple, ts}, st) when length(vs) == length(ts) do
    Enum.zip(vs, ts)
    |> Enum.reduce({[], st}, fn {v, t}, {rs, st} ->
      {r, st} = flatten_result(v, t, st)
      {rs ++ r, st}
    end)
  end

  # emit(type): a flag (1 = output the value) and the value
  defp flatten_result(v, {:emit, spec}, st), do: flatten_result(v, {:tuple, [{1, false}, spec]}, st)

  # a memory in the result (the CPU side returns it with the state) has no port
  defp flatten_result({:mem, _, _, _, _, _}, {:memory, _, _}, st), do: {[], st}

  defp flatten_result(:skip_zero, spec, st), do: flatten_result(zeros_of(spec), spec, st)

  defp flatten_result(%V{} = v, {w, s}, st) do
    {r, st} = materialize(v, st)
    {r, st} = resize(r, max(r.w, w), st)
    {r, st} = trunc_or_ext(r, w, r.s, st)
    {r, st} = trunc_or_ext(%{r | s: s}, st.port, s, st)
    {[r], st}
  end

  defp flatten_result(v, t, _st),
    do: raise(ArgumentError, "defhls: the result does not match its type #{inspect(t)}: #{inspect(v)}")

  defp zeros_of({:tuple, ts}), do: {:tuple, Enum.map(ts, &zeros_of/1)}
  defp zeros_of(_), do: const(0)

  ## expressions

  # an error in a node is reported at its source line, the innermost one that has one
  defp expr({_, meta, _} = ast, st) when is_list(meta), do: EHLS.Error.at(meta[:line], fn -> expr_(ast, st) end)
  defp expr(ast, st), do: expr_(ast, st)

  defp expr_({:__block__, _, exprs}, st) do
    Enum.reduce(exprs, {nil, st}, fn e, {_, st} -> expr(e, st) end)
  end

  # tuple patterns: {a, b} is a literal 2-tuple in the AST, larger ones are {:{}, _, elems}
  defp expr_({:=, _, [{:{}, _, _} = pattern, e]}, st), do: match(pattern, e, st)
  defp expr_({:=, _, [{_, _} = pattern, e]}, st), do: match(pattern, e, st)

  defp expr_({:=, _, [{var, _, ctx}, e]}, st) when is_atom(var) and is_atom(ctx) do
    {v, st} = expr(e, st)
    {v, %{st | env: Map.put(st.env, var, v)}}
  end

  defp expr_({var, _, ctx}, st) when is_atom(var) and is_atom(ctx) do
    case Map.fetch(st.env, var) do
      {:ok, v} -> {v, st}
      :error -> raise ArgumentError, "defhls: unknown variable #{var}"
    end
  end

  defp expr_(c, st) when is_integer(c), do: {const(c), st}

  defp expr_({a, b}, st), do: expr({:{}, [], [a, b]}, st)

  # emit(v) / skip(): the result of a rate-changing kernel (see EHLS.defhls)
  defp expr_({:emit, _, [a]}, st) do
    {v, st} = expr(a, st)
    {{:tuple, [%V{const: 1, w: 1, s: false}, v]}, st}
  end

  # skip()'s value: zeros shaped like the emitted value (a tuple for frames), see conform/2
  defp expr_({:skip, _, []}, st), do: {{:tuple, [%V{const: 0, w: 1, s: false}, :skip_zero]}, st}

  defp expr_({:{}, _, elems}, st) do
    {vs, st} = Enum.reduce(elems, {[], st}, fn e, {vs, st} ->
      {v, st} = expr(e, st)
      {vs ++ [v], st}
    end)

    {{:tuple, vs}, st}
  end

  defp expr_({:-, _, [a]}, st), do: expr({:-, [], [0, a]}, st)

  defp expr_({op, _, [a, b]}, st) when op in [:+, :-, :*] do
    {va, st} = expr(a, st)
    {vb, st} = expr(b, st)
    arith(op, va, vb, st)
  end

  defp expr_({op, _, [a, b]}, st) when op in [:&&&, :|||, :^^^] do
    {va, st} = expr(a, st)
    {vb, st} = expr(b, st)
    bitwise(op, va, vb, st)
  end

  defp expr_({op, _, [a, k]}, st) when op in [:<<<, :>>>] do
    {va, st} = expr(a, st)

    case expr(k, st) do
      {%V{const: c}, st} when is_integer(c) and c >= 0 -> shift(op, va, c, st)
      {%V{s: false} = vk, st} when op == :>>> -> shift_by(va, vk, st)
      _ -> raise ArgumentError, "defhls: shift amounts are constants (or unsigned values for >>>)"
    end
  end

  defp expr_({op, _, [a, b]}, st) when op in [:<, :>, :<=, :>=, :==, :!=, :===, :!==] do
    {va, st} = expr(a, st)
    {vb, st} = expr(b, st)
    compare(op, va, vb, st)
  end

  defp expr_({op, _, [a, b]}, st) when op in [:and, :or] do
    {va, st} = expr(a, st)
    {vb, st} = expr(b, st)
    {va, st} = materialize(va, st)
    {vb, st} = materialize(vb, st)
    emit(if(op == :and, do: "arith.andi", else: "arith.ori"), "#{va.name}, #{vb.name} : i1", 1, false, st)
  end

  defp expr_({:not, _, [a]}, st), do: expr({:==, [], [a, false]}, st)
  defp expr_(b, st) when is_boolean(b), do: {%V{const: if(b, do: 1, else: 0), w: 1, s: false}, st}

  defp expr_({:if, _, [cond, clauses]}, st) do
    {c, st} = expr(cond, st)
    {c, st} = materialize(c, st)
    if c.w != 1, do: raise(ArgumentError, "defhls: if needs a boolean condition")
    then_ast = Keyword.fetch!(clauses, :do)
    else_ast = Keyword.get(clauses, :else, 0)

    if has_loop?(then_ast) or has_loop?(else_ast) do
      branch(c, then_ast, else_ast, st)
    else
      # branch-local bindings stay local, as in Elixir
      {t, st1} = expr(then_ast, %{st | depth: st.depth + 1})
      {e, st2} = expr(else_ast, %{st1 | env: st.env})
      select(c, t, e, %{st2 | env: st.env, depth: st.depth})
    end
  end

  # (the AST has `reduce:` and `do:` as two keyword lists)
  defp expr_({:for, m, [gen, opts, block]}, st) when is_list(opts) and is_list(block),
    do: expr({:for, m, [gen, opts ++ block]}, st)

  defp expr_({:for, _, [{:<-, _, [{k, _, kctx}, {:.., _, [a, b]}]}, opts]}, st)
       when is_atom(k) and is_atom(kctx) and is_integer(a) and is_integer(b) and b >= a do
    init = Keyword.fetch!(opts, :reduce)

    case Keyword.fetch!(opts, :do) do
      [{:->, _, [[pattern], body]}] -> reduce_loop(k, a, b, pattern, init, body, st)
      _ -> raise ArgumentError, "defhls: for needs `reduce: init do acc -> ... end`"
    end
  end

  # Enum.reduce(a..b, init, fn k, acc -> body end): unrolled, k a constant in each copy
  # (shifts by k become wiring, table(@t, k) a constant); the copies chain into a pipeline
  defp expr_({{:., _, [{:__aliases__, _, [:Enum]}, :reduce]}, _, [{:.., _, [a, b]}, init, {:fn, _, [{:->, _, [[{k, _, kc}, pattern], body]}]}]}, st)
       when is_integer(a) and is_integer(b) and b >= a and is_atom(k) and is_atom(kc) do
    {v0, st} = expr(init, st)

    Enum.reduce(a..b, {v0, st}, fn kk, {acc, st} ->
      env = st.env
      inner = %{st | env: env |> Map.put(k, const(kk)) |> then(&bind(pattern, acc, &1)), depth: st.depth + 1}
      {r, st} = expr(body, inner)
      {r, %{st | env: env, depth: st.depth - 1}}
    end)
  end

  # Enum.sum(for k <- a..b, do: e): a reduce from 0
  defp expr_({{:., _, [{:__aliases__, _, [:Enum]}, :sum]}, _, [{:for, m, [gen, [do: e]]}]}, st) do
    acc = {:__hw_sum, [], nil}
    expr({:for, m, [gen, [reduce: 0], [do: [{:->, [], [[acc], {:+, [], [acc, e]}]}]]]}, st)
  end

  # elem(t, i) / put_elem(t, i, v) on a tuple's value (registers): a constant index picks or replaces one element, no
  # circuit; a variable one compares it with each index, a select per element
  defp expr_({:elem, _, [t, i]}, st) do
    {tv, st} = expr(t, st)
    vs = tuple_values!(tv, "elem")
    {iv, st} = expr(i, st)

    case iv do
      %V{const: c} when is_integer(c) ->
        if c < 0 or c >= length(vs), do: raise(ArgumentError, "defhls: elem(t, #{c}) of a tuple of #{length(vs)}")
        {Enum.at(vs, c), st}

      _ ->
        [first | rest] = vs

        Enum.with_index(rest, 1)
        |> Enum.reduce({first, st}, fn {v, k}, {acc, st} ->
          {c, st} = compare(:==, iv, const(k), st)
          select(c, v, acc, st)
        end)
    end
  end

  defp expr_({:put_elem, _, [t, i, x]}, st) do
    {tv, st} = expr(t, st)
    vs = tuple_values!(tv, "put_elem")
    {iv, st} = expr(i, st)
    {xv, st} = expr(x, st)

    case iv do
      %V{const: c} when is_integer(c) ->
        if c < 0 or c >= length(vs), do: raise(ArgumentError, "defhls: put_elem(t, #{c}, v) of a tuple of #{length(vs)}")
        {{:tuple, List.replace_at(vs, c, xv)}, st}

      _ ->
        {vs, st} =
          Enum.with_index(vs)
          |> Enum.map_reduce(st, fn {v, k}, st ->
            {c, st} = compare(:==, iv, const(k), st)
            select(c, xv, v, st)
          end)

        {{:tuple, vs}, st}
    end
  end

  defp expr_({:read, _, [m, i]}, st) do
    {mem, st} = expr(m, st)
    unless match?({:mem, _, _, _, _, _}, mem), do: raise(ArgumentError, "defhls: read/2 needs a memory")
    load(mem, i, st)
  end

  defp expr_({:table, _, [{:@, _, [{tname, _, _}]}, i]}, st) do
    case Map.fetch(st.env, {:table, tname}) do
      {:ok, {:table, _, size, _, _, _} = t} ->
        case expr(i, st) do
          {%V{const: c}, _} when is_integer(c) ->
            values = Map.fetch!(st.env, {:table_values, tname})
            j = Bitwise.band(c, pow2(size) - 1)
            {const(if(j < tuple_size(values), do: elem(values, j), else: 0)), st}

          _ ->
            load(t, i, st)
        end

      :error ->
        raise ArgumentError, "defhls: unknown table @#{tname}"
    end
  end

  defp expr_({:write, _, [m, i, v]}, st) do
    if st.depth > 0, do: raise(ArgumentError, "defhls: write/3 only at the top level of the body")
    {{:mem, name, size, _, aw, {w, s}} = mem, st} = expr(m, st)
    {ix, st} = index(i, mem, st)
    {val, st} = expr(v, st)
    {val, st} = materialize(val, st)
    {val, st} = resize(val, max(val.w, w), st)
    {val, st} = trunc_or_ext(val, w, val.s, st)
    {val, st} = trunc_or_ext(val, @mem, s, st)
    st = line("memref.store #{val.name}, #{name}[#{ix}] : memref<#{Bitwise.bsl(1, aw)}xi#{@mem}>", st)
    _ = size
    {mem, st}
  end

  defp expr_({f, _, [a, n]}, st) when f in [:signed, :unsigned] and is_integer(n) and n > 0 do
    {va, st} = expr(a, st)

    case va do
      # a constant stays one: a shift by it, or a table read at it, needs no circuit
      %V{const: c} when is_integer(c) ->
        {const(if(f == :signed, do: EHLS.signed(c, n), else: EHLS.unsigned(c, n))), st}

      _ ->
        {va, st} = materialize(va, st)
        {va, st} = resize(va, max(va.w, n), st)
        {v, st} = trunc_or_ext(va, n, va.s, st)
        {%{v | s: f == :signed}, st}
    end
  end

  defp expr_({f, _, args} = call, _st) when is_atom(f) and is_list(args) do
    raise ArgumentError,
          "defhls: cannot call #{f}/#{length(args)} in #{Macro.to_string(call)}: only other defhls functions of the module"
  end

  defp expr_(other, _st), do: raise(ArgumentError, "defhls: unsupported expression #{Macro.to_string(other)}")

  defp match(pattern, e, st) do
    {v, st} = expr(e, st)
    {v, %{st | env: bind(pattern, v, st.env)}}
  end

  # {a, b, c} = value: bind the variables to the tuple's elements
  defp bind({a, b}, v, env), do: bind({:{}, [], [a, b]}, v, env)

  defp bind({:{}, _, pats}, {:tuple, vs}, env) when length(pats) == length(vs) do
    Enum.zip(pats, vs) |> Enum.reduce(env, fn {p, v}, env -> bind(p, v, env) end)
  end

  defp bind({:_, _, ctx}, _v, env) when is_atom(ctx), do: env
  defp bind({var, _, ctx}, v, env) when is_atom(var) and is_atom(ctx), do: Map.put(env, var, v)
  defp bind(p, _v, _env), do: raise(ArgumentError, "defhls: cannot match #{Macro.to_string(p)}")

  defp has_loop?(ast) do
    {_, found} = Macro.prewalk(ast, false, fn
      {:for, _, _} = n, _ -> {n, true}
      n, acc -> {n, acc}
    end)

    found
  end

  ## memories and tables

  # index expression -> an MLIR `index` value: the region's base | the index's low bits
  defp index(i, {_kind, _name, size, base, aw, _elem}, st) do
    rw = addr_width(size)
    {iv, st} = expr(i, st)
    {iv, st} = materialize(iv, st)
    {iv, st} = trunc_or_ext(iv, rw, iv.s, st)
    {iv, st} = trunc_or_ext(%{iv | s: false}, aw, false, st)

    {iv, st} =
      if base == 0 do
        {iv, st}
      else
        {b, st} = materialize(%V{const: base, w: aw, s: false}, st)
        emit("arith.ori", "#{iv.name}, #{b.name} : i#{aw}", aw, false, st)
      end

    {ix, st} = emit("arith.index_cast", "#{iv.name} : i#{aw} to index", aw, false, st)
    {ix.name, st}
  end

  defp load({_kind, name, _size, _base, aw, {w, s}} = region, i, st) do
    {ix, st} = index(i, region, st)
    {d, st} = emit("memref.load", "#{name}[#{ix}] : memref<#{Bitwise.bsl(1, aw)}xi#{@mem}>", @mem, false, st)
    {d, st} = trunc_or_ext(d, w, false, st)
    {%{d | s: s}, st}
  end

  ## control flow

  # end the current block with `term` and start block `label` (nil: none follows yet)
  defp finish(st, term, label \\ nil, largs \\ "") do
    block = %{label: st.label, largs: st.largs, lines: Enum.reverse([term | st.lines])}
    %{st | blocks: [block | st.blocks], lines: [], label: label, largs: largs}
  end

  defp new_label(st), do: {"bb#{st.nb + 1}", %{st | nb: st.nb + 1}}

  defp line(text, st), do: %{st | lines: [text | st.lines]}

  # if as branches joining in a block whose arguments are the (flattened) result
  defp branch(c, then_ast, else_ast, st) do
    # the shape and widths of the result: evaluate both sides once on the side
    {t0, _} = expr(then_ast, %{st | depth: st.depth + 1})
    {e0, _} = expr(else_ast, %{st | depth: st.depth + 1})
    {t0, e0} = conform(t0, e0)
    types = Enum.zip(leaves(t0), leaves(e0)) |> Enum.map(fn {t, e} -> common(t, e) end)
    if length(leaves(t0)) != length(leaves(e0)), do: raise(ArgumentError, "defhls: if branches of different shapes")

    {lt, st} = new_label(st)
    {le, st} = new_label(st)
    {lm, st} = new_label(st)
    st = finish(st, "cf.cond_br #{c.name}, ^#{lt}, ^#{le}", lt)
    {st, _} = branch_side(then_ast, types, t0, lm, st)
    st = %{st | label: le, largs: "", lines: []}
    {st, _} = branch_side(else_ast, types, t0, lm, st)

    {args, vals} =
      types
      |> Enum.with_index()
      |> Enum.map(fn {{w, s}, i} ->
        n = "%#{lm}_#{i}"
        {"#{n}: i#{w}", %V{name: n, w: w, s: s}}
      end)
      |> Enum.unzip()

    st = %{st | label: lm, largs: "(#{Enum.join(args, ", ")})", lines: []}
    {rebuild(t0, vals), st}
  end

  defp branch_side(ast, types, shape, merge, st) do
    env = st.env
    {v, st} = expr(ast, %{st | depth: st.depth + 1})
    v = fill_skip(v, shape)

    {names, st} =
      Enum.zip(leaves(v), types)
      |> Enum.reduce({[], st}, fn {x, {w, s}}, {ns, st} ->
        {x, st} = resize(x, w, st, s)
        {x, st} = materialize(x, st)
        {ns ++ [x.name], st}
      end)

    tys = Enum.map_join(types, ", ", fn {w, _} -> "i#{w}" end)
    st = finish(%{st | env: env, depth: st.depth - 1}, "cf.br ^#{merge}(#{Enum.join(names, ", ")} : #{tys})")
    {st, v}
  end

  # skip()'s placeholder takes the shape of the other side (zeros)
  defp conform(:skip_zero, :skip_zero), do: {const(0), const(0)}
  defp conform(:skip_zero, e), do: {zeros(e), e}
  defp conform(t, :skip_zero), do: {t, zeros(t)}

  defp conform({:tuple, ts}, {:tuple, es}) when length(ts) == length(es) do
    {ts, es} = Enum.zip(ts, es) |> Enum.map(fn {t, e} -> conform(t, e) end) |> Enum.unzip()
    {{:tuple, ts}, {:tuple, es}}
  end

  defp conform(t, e), do: {t, e}

  defp zeros({:tuple, vs}), do: {:tuple, Enum.map(vs, &zeros/1)}
  defp zeros(_), do: const(0)

  # a branch's value with the placeholder replaced by zeros shaped like `shape`
  defp fill_skip(:skip_zero, shape), do: zeros(shape)

  defp fill_skip({:tuple, vs}, {:tuple, ss}) when length(vs) == length(ss),
    do: {:tuple, Enum.zip(vs, ss) |> Enum.map(fn {v, sh} -> fill_skip(v, sh) end)}

  defp fill_skip(v, _shape), do: v

  defp leaves({:tuple, vs}), do: Enum.flat_map(vs, &leaves/1)
  defp leaves(%V{} = v), do: [v]

  defp rebuild(shape, vals), do: elem(rebuild_(shape, vals), 0)

  defp rebuild_({:tuple, vs}, vals) do
    {out, rest} = Enum.reduce(vs, {[], vals}, fn v, {out, rest} ->
      {x, rest} = rebuild_(v, rest)
      {out ++ [x], rest}
    end)

    {{:tuple, out}, rest}
  end

  defp rebuild_(%V{}, [v | rest]), do: {v, rest}

  # for k <- a..b, reduce: init do acc -> body end, as a loop. An integer accumulator gets
  # the width of one step plus log2 of the iteration count (sums); the elements of a tuple
  # accumulator keep the widths of the init and of one step, found by repeating the step
  # until they no longer change (bound them with signed/unsigned when they would grow).
  defp reduce_loop(k, a, b, pattern, init, body, st) do
    n = b - a + 1
    kw = max(1, bit_len(b + 1))
    {v0, st} = expr(init, st)
    l0 = leaves(v0)

    step = fn types ->
      vals = types |> Enum.with_index() |> Enum.map(fn {{w, s}, i} -> %V{name: "%acc#{i}", w: w, s: s} end)
      env = st.env |> Map.put(k, %V{name: "%k", w: kw, s: false}) |> then(&bind(pattern, rebuild(v0, vals), &1))
      {r, _} = expr(body, %{st | env: env, depth: st.depth + 1})
      if length(leaves(r)) != length(vals), do: raise(ArgumentError, "defhls: reduce step of another shape than its init")
      leaves(r)
    end

    types =
      case v0 do
        %V{} ->
          [r0] = step.([{v0.w, v0.s}])
          s = v0.s or r0.s
          [{max(sw(v0, s), sw(r0, s)) + bit_len(n), s}]

        _ ->
          fixpoint(Enum.map(l0, &{&1.w, &1.s}), step, 8)
      end

    if Enum.any?(types, fn {w, _} -> w > @max_width end),
      do: raise(ArgumentError, "defhls: reduce accumulator wider than #{@max_width} bits")

    {inits, st} =
      Enum.zip(l0, types)
      |> Enum.reduce({[], st}, fn {v, {w, s}}, {vs, st} ->
        {v, st} = resize(v, max(v.w, w), st, s)
        {v, st} = materialize(%{v | w: w}, st)
        {vs ++ [v], st}
      end)

    tys = Enum.map_join(types, ", ", fn {w, _} -> "i#{w}" end)
    {k0, st} = materialize(%V{const: a, w: kw, s: false}, st)
    {lh, st} = new_label(st)
    {lb, st} = new_label(st)
    {lx, st} = new_label(st)
    kn = "%#{lh}_k"
    accs = types |> Enum.with_index() |> Enum.map(fn {{w, s}, i} -> %V{name: "%#{lh}_acc#{i}", w: w, s: s} end)
    largs = Enum.map_join([%V{name: kn, w: kw} | accs], ", ", &"#{&1.name}: i#{&1.w}")
    st = finish(st, "cf.br ^#{lh}(#{Enum.map_join([k0 | inits], ", ", & &1.name)} : i#{kw}, #{tys})", lh, "(#{largs})")
    {limit, st} = materialize(%V{const: b + 1, w: kw, s: false}, st)
    {c, st} = emit("arith.cmpi", "ult, #{kn}, #{limit.name} : i#{kw}", 1, false, st)
    st = finish(st, "cf.cond_br #{c.name}, ^#{lb}, ^#{lx}", lb)

    env = st.env
    kv = %V{name: kn, w: kw, s: false}
    acc = rebuild(v0, accs)
    {r, st} = expr(body, %{st | env: env |> Map.put(k, kv) |> then(&bind(pattern, acc, &1)), depth: st.depth + 1})

    {rs, st} =
      Enum.zip(leaves(r), types)
      |> Enum.reduce({[], st}, fn {r, {w, s}}, {rs, st} ->
        {r, st} = materialize(r, st)
        {r, st} = resize(r, max(r.w, w), st, s)
        {r, st} = trunc_or_ext(r, w, s, st)
        {rs ++ [r], st}
      end)

    {one, st} = materialize(%V{const: 1, w: kw, s: false}, st)
    {k1, st} = emit("arith.addi", "#{kn}, #{one.name} : i#{kw}", kw, false, st)
    st = finish(%{st | env: env, depth: st.depth - 1}, "cf.br ^#{lh}(#{Enum.map_join([k1 | rs], ", ", & &1.name)} : i#{kw}, #{tys})", lx)
    {acc, st}
  end

  defp fixpoint(_types, _step, 0),
    do: raise(ArgumentError, "defhls: a reduce accumulator keeps growing; bound it with signed/unsigned")

  defp fixpoint(types, step, tries) do
    next =
      Enum.zip(types, step.(types))
      |> Enum.map(fn {{w, s}, r} -> common(%V{w: w, s: s}, r) end)

    if next == types, do: types, else: fixpoint(next, step, tries - 1)
  end

  # c ? t : e, element by element for tuples
  defp tuple_values!({:tuple, vs}, _f), do: vs
  defp tuple_values!(other, f), do: raise(ArgumentError, "defhls: #{f} takes a tuple, got #{inspect(other)}")

  defp select(c, t, e, st) when t == :skip_zero or e == :skip_zero do
    {t, e} = conform(t, e)
    select(c, t, e, st)
  end

  defp select(c, {:tuple, ts}, {:tuple, es}, st) when length(ts) == length(es) do
    {vs, st} =
      Enum.zip(ts, es)
      |> Enum.reduce({[], st}, fn {t, e}, {vs, st} ->
        {v, st} = select(c, t, e, st)
        {vs ++ [v], st}
      end)

    {{:tuple, vs}, st}
  end

  defp select(c, %V{} = t, %V{} = e, st) do
    {w, s} = common(t, e)
    {t, st} = resize(t, w, st, s)
    {e, st} = resize(e, w, st, s)
    {t, st} = materialize(t, st)
    {e, st} = materialize(e, st)
    emit("arith.select", "#{c.name}, #{t.name}, #{e.name} : i#{w}", w, s, st)
  end

  defp select(_c, t, e, _st),
    do: raise(ArgumentError, "defhls: if branches of different shapes: #{inspect(t)} / #{inspect(e)}")

  ## operations

  defp arith(op, a, b, st) do
    s = a.s or b.s or op == :-
    {wa, wb} = {sw(a, s), sw(b, s)}
    w = if op == :*, do: wa + wb, else: max(wa, wb) + 1
    binop(%{:+ => "arith.addi", :- => "arith.subi", :* => "arith.muli"}[op], a, b, w, s, st)
  end

  defp bitwise(:&&&, %V{const: c} = a, b, st) when is_integer(c) and c >= 0, do: mask(b, a, st)
  defp bitwise(:&&&, a, %V{const: c} = b, st) when is_integer(c) and c >= 0, do: mask(a, b, st)

  defp bitwise(op, a, b, st) do
    s = a.s or b.s
    w = max(sw(a, s), sw(b, s))
    binop(%{:&&& => "arith.andi", :||| => "arith.ori", :^^^ => "arith.xori"}[op], a, b, w, s, st)
  end

  # x &&& c with c >= 0: the result fits c's width and is non-negative
  defp mask(x, %V{} = m, st) do
    w = max(sw(x, x.s), m.w)
    {v, st} = binop("arith.andi", x, m, w, x.s, st)
    {v, st} = trunc_or_ext(v, m.w, false, st)
    {%{v | s: false}, st}
  end

  defp shift(:<<<, a, k, st) do
    {a, st} = materialize(a, st)
    w = a.w + k
    {a, st} = resize(a, w, st)
    {kc, st} = materialize(%V{const: k, w: w, s: false}, st)
    emit("arith.shli", "#{a.name}, #{kc.name} : i#{w}", w, a.s, st)
  end

  defp shift(:>>>, a, k, st) do
    {a, st} = materialize(a, st)
    {kc, st} = materialize(%V{const: k, w: a.w, s: false}, st)
    op = if a.s, do: "arith.shrsi", else: "arith.shrui"
    {v, st} = emit(op, "#{a.name}, #{kc.name} : i#{a.w}", a.w, a.s, st)
    trunc_or_ext(v, max(1, a.w - k), a.s, st)
  end

  # a >>> k with k a value (unsigned): the width stays (amounts past it are not expected)
  defp shift_by(a, k, st) do
    {a, st} = materialize(a, st)
    {k, st} = materialize(k, st)
    {k, st} = trunc_or_ext(k, a.w, false, st)
    op = if a.s, do: "arith.shrsi", else: "arith.shrui"
    emit(op, "#{a.name}, #{k.name} : i#{a.w}", a.w, a.s, st)
  end

  defp compare(op, a, b, st) do
    s = a.s or b.s
    w = max(sw(a, s), sw(b, s))
    {a, st} = resize(a, w, st, s)
    {b, st} = resize(b, w, st, s)
    {a, st} = materialize(a, st)
    {b, st} = materialize(b, st)
    p = if(s, do: "s", else: "u")

    pred =
      case op do
        :< -> p <> "lt"
        :> -> p <> "gt"
        :<= -> p <> "le"
        :>= -> p <> "ge"
        o when o in [:==, :===] -> "eq"
        o when o in [:!=, :!==] -> "ne"
      end

    emit("arith.cmpi", "#{pred}, #{a.name}, #{b.name} : i#{w}", 1, false, st)
  end

  defp binop(op, a, b, w, s, st) do
    if w > @max_width, do: raise(ArgumentError, "defhls: intermediate value wider than #{@max_width} bits")
    {a, st} = resize(a, w, st, s)
    {b, st} = resize(b, w, st, s)
    {a, st} = materialize(a, st)
    {b, st} = materialize(b, st)
    emit(op, "#{a.name}, #{b.name} : i#{w}", w, s, st)
  end

  ## widths and values

  # width a value needs when viewed with signedness s (an unsigned value gains a sign bit)
  defp sw(v, s), do: if(s and not v.s, do: v.w + 1, else: v.w)

  defp common(a, b) do
    s = a.s or b.s
    {max(sw(a, s), sw(b, s)), s}
  end

  defp const(c) when c >= 0, do: %V{const: c, w: max(1, bit_len(c)), s: false}
  defp const(c), do: %V{const: c, w: bit_len(-c - 1) + 1, s: true}

  defp bit_len(0), do: 0
  defp bit_len(n), do: 1 + bit_len(Bitwise.bsr(n, 1))

  # extend (by v's own signedness) to w bits; constants just change their width
  defp resize(v, w, st, s \\ nil)
  defp resize(%V{const: c} = v, w, st, s) when is_integer(c), do: {%{v | w: w, s: s || v.s}, st}
  defp resize(%V{w: w} = v, w, st, s), do: {%{v | s: s || v.s}, st}

  defp resize(v, w, st, s) when w > v.w do
    {v2, st} = trunc_or_ext(v, w, v.s, st)
    {%{v2 | s: s || v.s}, st}
  end

  defp trunc_or_ext(%V{const: c} = v, w, s, st) when is_integer(c), do: {%{v | w: w, s: s}, st}
  defp trunc_or_ext(%V{w: w} = v, w, _s, st), do: {v, st}

  defp trunc_or_ext(v, w, _s, st) when w < v.w,
    do: emit("arith.trunci", "#{v.name} : i#{v.w} to i#{w}", w, v.s, st)

  defp trunc_or_ext(v, w, s, st) do
    op = if s, do: "arith.extsi", else: "arith.extui"
    emit(op, "#{v.name} : i#{v.w} to i#{w}", w, v.s, st)
  end

  defp materialize(%V{const: c, w: w} = v, st) when is_integer(c) do
    # two's complement of c in w bits
    bits = Bitwise.band(c, Bitwise.bsl(1, w) - 1)
    lit = if bits >= Bitwise.bsl(1, w - 1) and w > 1, do: bits - Bitwise.bsl(1, w), else: bits
    args = if w == 1, do: if(bits == 1, do: "true", else: "false"), else: "#{lit} : i#{w}"
    emit("arith.constant", args, w, v.s, st)
  end

  defp materialize(v, st), do: {v, st}

  defp emit(op, args, w, s, st) do
    name = "%v#{st.n}"
    {%V{name: name, w: w, s: s}, %{st | n: st.n + 1, lines: ["#{name} = #{op} #{args}" | st.lines]}}
  end
end
