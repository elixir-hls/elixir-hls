defmodule EHLS.Syntax do
  @moduledoc false
  # Forms of Elixir that become simpler ones for the circuit, on the AST: `case` and `cond` into nested `if`s,
  # several clauses of a function into one `case`. A circuit gives a value for every input, so the last clause must
  # match everything: `_ ->`, a variable, or `true ->` in a `cond`.

  @doc "`body` with `case` and `cond` replaced by `if`s (the CPU function keeps them as written)."
  def lower(body) do
    Macro.prewalk(body, fn
      {:case, m, [scrutinee, [do: clauses]]} -> EHLS.Error.at(m[:line], fn -> lower_case(scrutinee, clauses) end)
      {:cond, m, [[do: clauses]]} -> EHLS.Error.at(m[:line], fn -> lower_cond(clauses) end)
      node -> node
    end)
  end

  defp lower_cond(clauses) do
    [{:->, m, [[last], value]} | rest] = Enum.reverse(clauses)

    unless last == true,
      do: EHLS.Error.at(m[:line], fn -> raise ArgumentError, "cond: the last clause must be true ->, as a circuit has a value for every input" end)

    Enum.reduce(rest, value, fn {:->, m, [[c], v]}, acc -> {:if, Keyword.take(m, [:line]), [c, [do: v, else: acc]]} end)
  end

  defp lower_case(scrutinee, clauses) do
    s = fresh(:case)
    [last | rest] = Enum.reverse(clauses)
    {last_binds, last_test, last_body, m} = clause(last, s)

    if last_test != nil,
      do: EHLS.Error.at(m[:line], fn -> raise ArgumentError, "case: the last clause must match everything (_ ->), as a circuit has a value for every input" end)

    tail = block(last_binds ++ [last_body])

    chain =
      Enum.reduce(rest, tail, fn c, acc ->
        {binds, test, body, m} = clause(c, s)

        case test do
          nil -> block(binds ++ [body])
          t -> {:if, Keyword.take(m, [:line]), [block(binds ++ [t]), [do: body, else: acc]]}
        end
      end)

    block([{:=, [], [s, scrutinee]}, chain])
  end

  defp block([one]), do: one
  defp block(list), do: {:__block__, [], list}

  # {what binds the pattern's variables, the test (nil: always), the body, the clause's meta}
  defp clause({:->, m, [[head], body]}, s) do
    {pattern, guard} =
      case head do
        {:when, _, [p, g]} -> {p, g}
        p -> {p, nil}
      end

    {pattern, guard, body} = own_names(pattern, guard, body)
    {binds, tests} = EHLS.Error.at(m[:line], fn -> pattern(pattern, s) end)
    tests = if guard == nil, do: tests, else: tests ++ [guard]
    {binds, conj(tests), body, m}
  end

  defp conj([]), do: nil
  defp conj(tests), do: Enum.reduce(tests, fn t, acc -> {:and, [], [acc, t]} end)

  defp pattern({:_, _, ctx}, _s) when is_atom(ctx), do: {[], []}
  defp pattern({v, _, ctx} = var, s) when is_atom(v) and is_atom(ctx), do: {[{:=, [], [var, s]}], []}
  defp pattern(n, s) when is_integer(n) or is_boolean(n), do: {[], [{:==, [], [s, n]}]}
  defp pattern({:-, _, [n]} = neg, s) when is_integer(n), do: {[], [{:==, [], [s, neg]}]}
  defp pattern({:^, _, [var]}, s), do: {[], [{:==, [], [s, var]}]}
  defp pattern({a, b}, s), do: pattern({:{}, [], [a, b]}, s)

  defp pattern({:{}, _, elems}, s) do
    vars = for _ <- elems, do: fresh(:elem)
    parts = Enum.zip(elems, vars) |> Enum.map(fn {e, v} -> pattern(e, v) end)
    {[{:=, [], [{:{}, [], vars}, s]} | Enum.flat_map(parts, &elem(&1, 0))], Enum.flat_map(parts, &elem(&1, 1))}
  end

  defp pattern(other, _s),
    do: raise(ArgumentError, "case: cannot match #{Macro.to_string(other)}: integers, variables, _, ^variable and tuples of them")

  # the pattern's variables are the clause's own, not to reach what follows the case
  defp own_names(pattern, guard, body) do
    names = bound(pattern)
    id = System.unique_integer([:positive])
    rename = fn ast ->
      Macro.prewalk(ast, fn
        {v, m, ctx} = n when is_atom(v) and is_atom(ctx) -> if(v in names, do: {:"hw__c#{id}_#{v}", m, ctx}, else: n)
        n -> n
      end)
    end

    {rename.(pattern), rename.(guard), rename.(body)}
  end

  defp bound(pattern) do
    {_, names} =
      Macro.prewalk(pattern, [], fn
        {:^, _, _}, acc -> {nil, acc}
        {:_, _, ctx} = n, acc when is_atom(ctx) -> {n, acc}
        {v, _, ctx} = n, acc when is_atom(v) and is_atom(ctx) -> {n, [v | acc]}
        n, acc -> {n, acc}
      end)

    names
  end

  defp fresh(what), do: {:"hw__#{what}#{System.unique_integer([:positive])}", [], nil}

  @doc """
  Several clauses of a function (or one with a pattern or a guard) as one head and body: `[{head, body, line}]`
  to `{head, body}`. Each clause repeats the types, and they must be the same.
  """
  def merge([{head, body, _line}] = clauses) do
    if plain?(head), do: {head, body}, else: merge_clauses(clauses)
  end

  def merge(clauses), do: merge_clauses(clauses)

  defp plain?({:"::", _, [{_, _, params}, _]}) when is_list(params), do: Enum.all?(params, &plain_param?/1)
  defp plain?(_), do: false

  defp plain_param?({:"::", _, [{v, _, ctx}, _]}) when is_atom(v) and is_atom(ctx), do: true
  defp plain_param?({:\\, _, [p, _]}), do: plain_param?(p)
  # a state holding a tuple(t, n), written as its parts: EHLS.TupleState takes it as it is
  defp plain_param?({:"::", _, [pat, type]}), do: tuple_state?(type) and vars?(pat)
  defp plain_param?(_), do: false

  defp tuple_state?(type), do: elem(Macro.prewalk(type, false, fn {:tuple, _, [_, _]} = n, _ -> {n, true}; n, a -> {n, a} end), 1)

  defp vars?({a, b}), do: vars?({:{}, [], [a, b]})
  defp vars?({:{}, _, ps}), do: Enum.all?(ps, &match?({v, _, c} when is_atom(v) and is_atom(c), &1))
  defp vars?(_), do: false

  defp merge_clauses(clauses) do
    parsed = for {head, body, line} <- clauses, do: EHLS.Error.at(line, fn -> parse(head, body, line) end)
    [%{name: name, types: types, defaults: defaults, ret: ret} | _] = parsed

    keys = fn ts -> Enum.map(ts, & &1.key) end

    for %{types: t, ret: r, line: line} <- parsed, keys.(t) != keys.(types) or r.key != ret.key do
      EHLS.Error.at(line, fn -> raise ArgumentError, "defhls #{name}: every clause has the same types" end)
    end

    vars = for i <- 1..length(types), do: {:"hw__a#{i}", [], nil}

    params =
      Enum.zip([vars, types, defaults])
      |> Enum.map(fn
        {v, t, nil} -> {:"::", [], [v, t.ast]}
        {v, t, d} -> {:\\, [], [{:"::", [], [v, t.ast]}, d]}
      end)

    for t <- types, t.key =~ ~r/tuple\(/ do
      raise ArgumentError, "defhls #{name}: a function with a tuple(t, n) in its state has one clause and no guard: test its parts in the body"
    end

    arms =
      for %{patterns: ps, guard: g, body: b, line: line} <- parsed do
        tuple = {:{}, [], ps}
        {:->, [line: line], [[if(g, do: {:when, [], [tuple, g]}, else: tuple)], b]}
      end

    {{:"::", [], [{name, [], params}, ret.ast]}, {:case, [], [{:{}, [], vars}, [do: arms]]}}
  end

  defp parse(head, body, line) do
    {head, guard} =
      case head do
        {:when, _, [h, g]} -> {h, g}
        h -> {h, nil}
      end

    case head do
      {:"::", _, [{name, _, params}, ret]} when is_atom(name) and is_list(params) ->
        parts = Enum.map(params, &param/1)

        %{
          name: name,
          line: line,
          guard: guard,
          body: body,
          patterns: Enum.map(parts, &elem(&1, 0)),
          types: Enum.map(parts, &type(elem(&1, 1))),
          defaults: Enum.map(parts, &elem(&1, 2)),
          ret: type(ret)
        }

      _ ->
        raise ArgumentError, "defhls expects `name(arg :: type) :: type`, got: #{Macro.to_string(head)}"
    end
  end

  defp param({:\\, _, [{:"::", _, [p, t]}, d]}), do: {p, t, d}
  defp param({:"::", _, [p, t]}), do: {p, t, nil}
  defp param(p), do: raise(ArgumentError, "defhls: bad parameter #{Macro.to_string(p)}")

  defp type(ast), do: %{ast: ast, key: Macro.to_string(ast)}
end
