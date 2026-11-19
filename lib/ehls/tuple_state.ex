defmodule EHLS.TupleState do
  @moduledoc false
  # A defhls whose state holds tuples, placed with `transform(init, &f/2, memory: [:hist])`: the tuples named there
  # become memories (block RAM) instead of registers. `f(x :: t, {pos, hist} :: {u8, tuple(s16, 8)})` returning
  # `{output, {pos2, hist2}}`, hist2 made from hist by put_elem. On the CPU the function is the Elixir one as written.
  # For the circuit it is lowered here to the compiler's memory kernel: each named tuple a memory argument after the
  # state, elem(m, i) a read, and the writes of put_elem done at the end of the step, as a register takes its next value
  # (every read in the body sees the tuple as it came in; a read of a tuple already rewritten in the step takes the value
  # written at that index). What is left of the state is the kernel's state; an empty one is a u1 that stays 0.
  #
  # lower(name, params, ret, body, mems) -> {params, ret, body, layout}
  #   mems: the state's variables to make memories (a whole state of one variable: that variable)
  #   layout: %{shape: :whole | [{:mem, var, n} | {:val, pattern}], mems: [{var, etype, n}]}

  def lower(name, [x, {:"::", sm, [pat, stype]} | levels], ret, body, mems) do
    mems_and_vals = bind!(name, pat, stype, mems)
    {internal_state, mems} = internal(mems_and_vals)
    {out_t, next_t} = result!(name, ret)

    unless Macro.to_string(next_t) == Macro.to_string(stype),
      do: raise(ArgumentError, "defhls #{name}: the state is #{Macro.to_string(stype)} and the result gives #{Macro.to_string(next_t)} as the next one")

    sp = {:hw__sp, [], nil}
    mem_params = for {v, et, n} <- mems, do: {:"::", [], [mvar(v), {:memory, [], [et, pow2(n)]}]}
    state_param = {:"::", sm, [sp, {:state, [], [internal_state.type]}]}
    bind = internal_state.bind.(sp)
    body = lower_body(name, body, mems_and_vals, internal_state)
    layout = %{shape: shape(pat, mems_and_vals), mems: mems}
    {[x, state_param | mem_params] ++ levels, {out_t, internal_state.type}, prepend(bind, body), layout}
  end

  def lower(name, _params, _ret, _body, _mems),
    do: raise(ArgumentError, "transform(init, &#{name}/2, memory: [...]): #{name} takes the element and a state")

  # the kernel's memory for the tuple v (a name of its own: v itself is not a value in the circuit)
  defp mvar(v), do: {:"hw__m_#{v}", [], nil}

  # a type of n values of one type: tuple(t, n), or {t, t, ...} written out; {element type, n} or nil
  defp one_type({:tuple, _, [t, n]}), do: {t, n}
  defp one_type({a, b}), do: one_type({:{}, [], [a, b]})

  defp one_type({:{}, _, [t | _] = ts}) do
    if Enum.all?(ts, &(Macro.to_string(&1) == Macro.to_string(t))), do: {t, length(ts)}
  end

  defp one_type(_), do: nil

  # the state's parts, each named in memory: a memory of a tuple of one type, the others values
  defp bind!(name, {v, _, c}, stype, mems) when is_atom(v) and is_atom(c) do
    unless mems == [v], do: raise(ArgumentError, "transform(init, &#{name}/2, memory: #{inspect(mems)}): #{name}'s state is #{v}")
    {et, n} = one_type(stype) || raise(ArgumentError, "transform(init, &#{name}/2, memory: [:#{v}]): #{v} is no tuple of one type (tuple(t, n))")
    [{:mem, v, et, n!(name, n)}]
  end

  defp bind!(name, pat, stype, mems) do
    pats =
      case pat do
        {a, b} -> [a, b]
        {:{}, _, ps} -> ps
        _ -> raise ArgumentError, "transform(init, &#{name}/2, memory: [...]): the state is written as its parts, {pos, hist} :: {u8, tuple(s16, 8)}"
      end

    types =
      case stype do
        {a, b} -> [a, b]
        {:{}, _, ts} -> ts
        _ -> raise ArgumentError, "defhls #{name}: the state's pattern #{Macro.to_string(pat)} and its type #{Macro.to_string(stype)}"
      end

    unless length(pats) == length(types), do: raise(ArgumentError, "defhls #{name}: the state's pattern has #{length(pats)} parts, its type #{length(types)}")

    names = for {v, _, c} <- pats, is_atom(v) and is_atom(c), do: v

    for m <- mems, m not in names,
        do: raise(ArgumentError, "transform(init, &#{name}/2, memory: [:#{m}]): no part #{m} in #{name}'s state #{Macro.to_string(pat)}")

    for {p, t} <- Enum.zip(pats, types) do
      case p do
        {v, _, c} when is_atom(v) and is_atom(c) ->
          if v in mems do
            {et, n} = one_type(t) || raise(ArgumentError, "transform(init, &#{name}/2, memory: [:#{v}]): #{v} is no tuple of one type (tuple(t, n))")
            {:mem, v, et, n!(name, n)}
          else
            {:val, p, t}
          end

        p ->
          {:val, p, t}
      end
    end
  end

  defp n!(name, n) do
    unless is_integer(n) and n > 0, do: raise(ArgumentError, "defhls #{name}: tuple(type, n), n a positive integer")
    n
  end

  # a memory's size in the circuit: n rounded up to a power of two (its index wraps to it)
  defp pow2(n), do: if(Bitwise.band(n, n - 1) == 0, do: n, else: Bitwise.bsl(1, length(Integer.digits(n - 1, 2))))

  # what is left of the state: its type, and how its parts are bound from the kernel's state variable
  defp internal(parts) do
    vals = for {:val, p, t} <- parts, do: {p, t}
    mems = for {:mem, v, et, n} <- parts, do: {v, et, n}

    st =
      case vals do
        [] -> %{type: {:u1, [], nil}, bind: fn _ -> [] end, next: fn [] -> 0 end}
        [{p, t}] -> %{type: t, bind: fn sp -> [{:=, [], [p, sp]}] end, next: fn [e] -> e end}
        many -> %{type: {:{}, [], Enum.map(many, &elem(&1, 1))}, bind: fn sp -> [{:=, [], [{:{}, [], Enum.map(many, &elem(&1, 0))}, sp]}] end,
                  next: fn es -> {:{}, [], es} end}
      end

    {st, mems}
  end

  # the whole state one memory: a state that is one variable (h :: tuple(u8, 4)); {hist} is a tuple of one part
  defp shape({v, _, c}, [{:mem, _, _, _}]) when is_atom(v) and is_atom(c), do: :whole
  defp shape(_pat, parts), do: for(p <- parts, do: (case p, do: ({:mem, v, _, n} -> {:mem, v, n}; {:val, p, _} -> {:val, p})))

  defp result!(_name, {o, s}), do: {o, s}
  defp result!(name, _), do: raise(ArgumentError, "defhls #{name}: the result is {output, next_state}")

  defp prepend(stmts, {:__block__, m, es}), do: {:__block__, m, stmts ++ es}
  defp prepend([], e), do: e
  defp prepend(stmts, e), do: {:__block__, [], stmts ++ [e]}

  # The body: the statements, the versions of each tuple (its writes so far), the result {output, next state}
  defp lower_body(name, body, parts, st) do
    es = case body, do: ({:__block__, _, es} -> es; e -> [e])
    {stmts, [last]} = Enum.split(es, -1)
    mems = for {:mem, v, _, _} <- parts, into: %{}, do: {v, {v, []}}
    ctx = %{name: name, versions: mems, n: 0}

    {out, ctx} =
      Enum.reduce(stmts, {[], ctx}, fn s, {acc, ctx} ->
        {new, ctx} = statement(s, ctx)
        {acc ++ new, ctx}
      end)

    # the result: {output, next state} written out, or an if choosing between two of them
    {pre, o, nexts, _ctx} =
      case last do
        {o, n} ->
          result(o, n, parts, ctx)

        {:if, _, [c, [do: {oa, na}, else: {ob, nb}]]} ->
          {cs, c} = expr_stmt(c, ctx)
          cv = {:hw__c, [], nil}
          {pa, oa, nas, ctx} = result(oa, na, parts, ctx)
          {pb, ob, nbs, ctx} = result(ob, nb, parts, ctx)

          nexts =
            for {{a, b}, part} <- Enum.zip(Enum.zip(nas, nbs), parts) do
              case part do
                {:val, _, _} -> quote(do: if(unquote(cv), do: unquote(a), else: unquote(b)))
                {:mem, _, _, _} -> {:either, cv, a, b}
              end
            end

          {cs ++ [{:=, [], [cv, c]}] ++ pa ++ pb, quote(do: if(unquote(cv), do: unquote(oa), else: unquote(ob))), nexts, ctx}

        _ ->
          raise ArgumentError,
                "defhls #{name}: with a tuple(t, n) in the state the body ends in {output, next_state} written out, " <>
                  "or an if choosing between two of them"
      end

    out_var = {:hw__out, [], nil}
    next_var = {:hw__next, [], nil}
    vals = for {e, {:val, _, _}} <- Enum.zip(nexts, parts), do: e
    o_stmts = []

    # the writes, after every read of the step. An if's: each branch's, its value the branch's when it is chosen and
    # the word as it is otherwise (so the one not chosen writes back what is there), all values found before a write
    {values, writes} =
      for {{:mem, v, _, _}, e} <- Enum.zip(parts, nexts), reduce: {[], []} do
        {vs, ws} ->
          case e do
            {:version, ^v, wl} ->
              {vs, ws ++ for({wi, wx} <- wl, do: {:=, [], [mvar(v), {:write, [], [mvar(v), wi, wx]}]})}

            {:either, cv, {:version, ^v, wa}, {:version, ^v, wb}} ->
              chosen = for({wi, wx} <- wa, do: {wi, wx, true}) ++ for({wi, wx} <- wb, do: {wi, wx, false})

              {done, vals_stmts} =
                Enum.reduce(chosen, {[], []}, fn {wi, wx, a?}, {done, stmts} ->
                  current = Enum.reduce(done, {:read, [], [mvar(v), wi]}, fn {di, dv}, acc ->
                    quote(do: if(unquote(wi) == unquote(di), do: unquote(dv), else: unquote(acc)))
                  end)

                  t = {:"hw__cw#{length(done)}_#{v}", [], nil}
                  value = if a?, do: quote(do: if(unquote(cv), do: unquote(wx), else: unquote(current))),
                                 else: quote(do: if(unquote(cv), do: unquote(current), else: unquote(wx)))
                  {done ++ [{wi, t}], stmts ++ [{:=, [], [t, value]}]}
                end)

              {vs ++ vals_stmts, ws ++ for({wi, t} <- done, do: {:=, [], [mvar(v), {:write, [], [mvar(v), wi, t]}]})}

            {:either, _, {:version, a, _}, {:version, b, _}} ->
              raise ArgumentError, "defhls #{name}: the next #{v} is made from #{if a == v, do: b, else: a}: a tuple goes on in its own place; that would be a copy, not there yet"

            {:version, other, _} ->
              raise ArgumentError, "defhls #{name}: the next #{v} is made from #{other}: a tuple goes on in its own place; that would be a copy, not there yet"
          end
      end

    {:__block__, [],
     out ++ pre ++ o_stmts ++
       [{:=, [], [out_var, o]}, {:=, [], [next_var, st.next.(vals)]}] ++ values ++ writes ++ [{out_var, next_var}]}
  end

  # {statements, output, next parts} of one {output, next state}
  defp result(o, n, parts, ctx) do
    {pre, nexts, ctx} = next_parts(n, parts, ctx)
    {s, o} = expr_stmt(o, ctx)
    {pre ++ s, o, nexts, ctx}
  end

  # the next state's parts: a tuple as a version, a value as an expression
  defp next_parts(next, parts, ctx) do
    es =
      case {parts, next} do
        # a state that is a tuple of one part, {h}: its next one {put_elem(h, i, x)}
        {[_], {:{}, _, [e]}} -> [e]
        {[_], e} -> [e]
        {_, {a, b}} -> [a, b]
        {_, {:{}, _, es}} -> es
        _ -> raise ArgumentError, "defhls #{ctx.name}: the next state is written as its parts, {pos + 1, put_elem(hist, i, x)}"
      end

    unless length(es) == length(parts), do: raise(ArgumentError, "defhls #{ctx.name}: the next state has #{length(es)} parts, the state #{length(parts)}")

    {pre, nexts, ctx} =
      Enum.reduce(Enum.zip(es, parts), {[], [], ctx}, fn
        {e, {:mem, _, _, _}}, {pre, ns, ctx} ->
          {stmts, v, ctx} = version!(e, ctx)
          {pre ++ stmts, ns ++ [v], ctx}

        {e, {:val, _, _}}, {pre, ns, ctx} ->
          {stmts, e} = expr_stmt(e, ctx)
          {pre ++ stmts, ns ++ [e], ctx}
      end)

    {pre, nexts, ctx}
  end

  # a statement: a new version of a tuple (put_elem, or another name for one), or anything else, its reads made reads
  defp statement({:=, _, [{v, _, c}, rhs]} = s, ctx) when is_atom(v) and is_atom(c) do
    if version?(rhs, ctx) do
      {stmts, {:version, m, ws}, ctx} = version!(rhs, ctx)
      {stmts, %{ctx | versions: Map.put(ctx.versions, v, {m, ws})}}
    else
      {stmts, rhs} = expr_stmt(rhs, ctx)

      if Map.has_key?(ctx.versions, v),
        do: raise(ArgumentError, "defhls #{ctx.name}: #{v} names a tuple of the state; another value would need another name")

      _ = s
      {stmts ++ [{:=, [], [{v, [], c}, rhs]}], ctx}
    end
  end

  defp statement(s, ctx) do
    {stmts, s} = expr_stmt(s, ctx)
    {stmts ++ [s], ctx}
  end

  defp version?({v, _, c}, ctx) when is_atom(v) and is_atom(c), do: Map.has_key?(ctx.versions, v)
  defp version?({:put_elem, _, [a, _, _]}, ctx), do: version?(a, ctx)
  defp version?({:|>, _, [a, {:put_elem, _, [_, _]}]}, ctx), do: version?(a, ctx)
  defp version?(_, _), do: false

  # {statements binding the write's index and value, {:version, memory, writes}, ctx}
  defp version!({v, _, c}, ctx) when is_atom(v) and is_atom(c) do
    case Map.fetch(ctx.versions, v) do
      {:ok, {m, ws}} -> {[], {:version, m, ws}, ctx}
      :error -> raise ArgumentError, "defhls #{ctx.name}: #{v} is no tuple of the state"
    end
  end

  defp version!({:|>, _, [a, {:put_elem, m, [i, x]}]}, ctx), do: version!({:put_elem, m, [a, i, x]}, ctx)

  defp version!({:put_elem, _, [a, i, x]}, ctx) do
    {s1, {:version, m, ws}, ctx} = version!(a, ctx)
    {s2, i} = expr_stmt(i, ctx)
    {s3, x} = expr_stmt(x, ctx)
    k = ctx.n
    wi = {:"hw__wi#{k}", [], nil}
    wx = {:"hw__wx#{k}", [], nil}
    {s1 ++ s2 ++ s3 ++ [{:=, [], [wi, i]}, {:=, [], [wx, x]}], {:version, m, ws ++ [{wi, wx}]}, %{ctx | n: k + 1}}
  end

  defp version!(e, ctx),
    do: raise(ArgumentError, "defhls #{ctx.name}: the next tuple is the one of the state with put_elem, got #{Macro.to_string(e)}; a new tuple would be a copy, not there yet")

  # an expression: elem(t, j) of a tuple of the state a read (with the writes of its version so far before it); any
  # other use of a tuple of the state, or put_elem below the top level, stops the compile
  defp expr_stmt(e, ctx) do
    e =
      Macro.prewalk(e, fn
        {:elem, _, [a, j]} = n ->
          if version?(a, ctx) do
            {[], {:version, m, ws}, _} = version!(a, ctx)
            Enum.reduce(ws, {:read, [], [mvar(m), j]}, fn {wi, wx}, acc -> quote(do: if(unquote(j) == unquote(wi), do: unquote(wx), else: unquote(acc))) end)
          else
            n
          end

        {:put_elem, _, [a | _]} = n ->
          if version?(a, ctx),
            do: raise(ArgumentError, "defhls #{ctx.name}: put_elem of a tuple of the state at the top level of the body, or in the next state"),
            else: n

        {v, _, c} = n when is_atom(v) and is_atom(c) ->
          if Map.has_key?(ctx.versions, v),
            do: raise(ArgumentError, "defhls #{ctx.name}: #{v}, a tuple of the state, is read with elem(#{v}, i) and goes on with put_elem"),
            else: n

        n ->
          n
      end)

    {[], e}
  end

  @doc false
  # the state from the circuit's state words: the values' zeros filled in order, then the tuples (zeros) at their places
  def fill(zeros, words) do
    Enum.map_reduce(zeros, words, &fill_one/2)
  end

  defp fill_one(z, words) when is_tuple(z) do
    {items, rest} = z |> Tuple.to_list() |> Enum.map_reduce(words, &fill_one/2)
    {List.to_tuple(items), rest}
  end

  defp fill_one(_z, [w | rest]), do: {w, rest}

  @doc false
  def assemble(vals, mems, size) do
    {parts, []} =
      Enum.map_reduce(0..(size - 1), vals, fn i, vs ->
        case List.keyfind(mems, i, 0) do
          {^i, n} -> {:erlang.make_tuple(n, 0), vs}
          nil -> {hd(vs), tl(vs)}
        end
      end)

    List.to_tuple(parts)
  end
end
