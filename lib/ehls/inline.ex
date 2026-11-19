defmodule EHLS.Inline do
  @moduledoc false
  # A defhls calling a defhls, for the circuit: a definition makes no circuit, so the call is replaced by
  # the callee's body, on the AST, before the translation to MLIR. Its arguments and result are
  # wrapped to its types with signed/2 and unsigned/2, as its CPU function does, and its variables get names
  # of their own, per call. A callee's body has its own calls replaced already: callees
  # are processed before their callers.

  @doc "The function's description for later calls."
  def describe(params, ret, body), do: %{params: params, ret: ret, body: body}

  @doc """
  `body` with the calls of `fns` (name => `describe/3`) replaced. `self`: the function being defined,
  `others`: the defhls functions that cannot be called, having state, a memory, a param or emit.
  """
  def calls(body, self, fns, others) do
    Macro.prewalk(body, fn
      {^self, meta, args} = node when is_list(args) ->
        EHLS.Error.at(meta[:line], fn ->
          raise ArgumentError, "defhls #{self}: it calls itself (#{Macro.to_string(node)}): a circuit has a fixed size"
        end)

      {f, meta, args} = node when is_atom(f) and is_list(args) ->
        cond do
          f == :@ ->
            node

          Map.has_key?(fns, f) ->
            EHLS.Error.at(meta[:line], fn -> expand(f, args, Map.fetch!(fns, f), meta) end)

          f in others ->
            EHLS.Error.at(meta[:line], fn ->
              raise ArgumentError, "defhls #{self}: cannot call #{f}, which has a state (a memory, or a list as the output) or a param"
            end)

          true ->
            node
        end

      node ->
        node
    end)
  end

  defp expand(f, args, %{params: params, ret: ret, body: body}, meta) do
    if length(args) != length(params),
      do: raise(ArgumentError, "#{f} takes #{length(params)} argument(s), got #{length(args)}")

    id = System.unique_integer([:positive])
    binds = for {{p, spec}, arg} <- Enum.zip(params, args), do: assign(name(f, id, p), arg, spec)
    {:__block__, Keyword.take(meta, [:line]), binds ++ [wrapped(rename(body, f, id), ret)]}
  end

  defp assign(var, arg, spec), do: {:=, [], [var_ast(var), wrapped(arg, spec)]}

  # the value wrapped to the type: a tuple taken apart first
  defp wrapped(ast, {w, s}) when is_integer(w), do: {if(s, do: :signed, else: :unsigned), [], [ast, w]}
  # an output that may be missing (emit / skip): cut where the kernel gives it, at its port
  defp wrapped(ast, {:emit, _}), do: ast

  defp wrapped(ast, {:tuple, specs}) do
    vars = for {_, i} <- Enum.with_index(specs), do: var_ast(:"hw__t#{System.unique_integer([:positive])}_#{i}")
    elems = for {v, s} <- Enum.zip(vars, specs), do: wrapped(v, s)
    {:__block__, [], [{:=, [], [{:{}, [], vars}, ast]}, {:{}, [], elems}]}
  end

  defp var_ast(name), do: {name, [], nil}
  defp name(f, id, v), do: :"hw__#{f}#{id}_#{v}"

  # every variable of the body, not the tables' names
  defp rename({:@, _, _} = n, _f, _id), do: n
  defp rename({:_, _, ctx} = n, _f, _id) when is_atom(ctx), do: n
  defp rename({v, m, ctx}, f, id) when is_atom(v) and is_atom(ctx), do: {name(f, id, v), m, ctx}
  defp rename({a, m, args}, f, id), do: {rename(a, f, id), m, rename(args, f, id)}
  defp rename({a, b}, f, id), do: {rename(a, f, id), rename(b, f, id)}
  defp rename(l, f, id) when is_list(l), do: Enum.map(l, &rename(&1, f, id))
  defp rename(x, _f, _id), do: x
end
