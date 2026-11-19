defmodule EHLS.Join do
  @moduledoc false
  # Two streams into one function (elixir-hls dev-notes "Streams at an instance's ends"): in a
  # definstance, `zip_with(a, b, &f/2)` (Elixir's Enum.zip_with: one element of each, together), or the
  # call form `f(a, b)` with both arguments streams. The circuit is a join block making one element
  # {x, y} of the two, then a generated kernel of one tuple argument, `<f>__zip`, calling f.
  #
  # A join can be anywhere in the body, its operands arguments, pipes, or joins themselves:
  # `left |> map(&g/1) |> zip_with(right, &mix/2) |> map(&h/1)`. The instance is built as a graph from
  # this (EHLS's build/3): each pipe between joins its stages, the joins linked between them.

  # what takes the stream before it and other arguments, none of them a stream
  @not_fns [:zip_with, :map, :transform, :chunk_every, :|>]

  @doc false
  # Every join made explicit, zip_with(a, b, &f/2) with its operands normalized the same way:
  #   * `f(a, b)` with both arguments streams, and `a |> f(b)` with b a stream;
  #   * `a |> zip_with(b, &f/2)`, the pipe giving the first stream.
  # A stream is an argument of the instance, a pipe from one, a join, or a call taking one first. The rest
  # is EHLS.Pipeline.normalize/1's (`f(x)` is `x |> f()`).
  def normalize(e, streams) do
    case EHLS.Pipeline.normalize(e) do
      {:|>, m, [lhs, rhs]} ->
        lhs = normalize(lhs, streams)

        case rhs do
          {:zip_with, zm, [b, fun]} -> {:zip_with, zm, [lhs, normalize(b, streams), fun]}
          {f, fm, [b]} when is_atom(f) and f not in @not_fns -> if(stream?(b, streams), do: zip(f, fm, lhs, normalize(b, streams)), else: {:|>, m, [lhs, rhs]})
          _ -> {:|>, m, [lhs, rhs]}
        end

      {:zip_with, m, [a, b, fun]} ->
        {:zip_with, m, [normalize(a, streams), normalize(b, streams), fun]}

      other ->
        other
    end
  end

  defp zip(f, m, a, b), do: {:zip_with, m, [a, b, {:&, [], [{:/, [], [{f, [], nil}, 2]}]}]}

  defp stream?({v, _, ctx}, streams) when is_atom(v) and is_atom(ctx), do: MapSet.member?(streams, v)
  defp stream?({:|>, _, [lhs, _]}, streams), do: stream?(lhs, streams)
  defp stream?({:zip_with, _, _}, _streams), do: true
  defp stream?({g, _, [first | _]}, streams) when is_atom(g), do: stream?(first, streams)
  defp stream?(_, _), do: false

  @doc false
  # the generated defhls `<f>__zip(x :: {t1, t2}) :: r`, f's two arguments taken from the tuple
  def kernel_def(gname, %{params: [{a, ta}, {b, tb}], ret: ret}, spec_ast) do
    x = {:hw__pair, [], nil}
    va = {:"hw__#{a}", [], nil}
    vb = {:"hw__#{b}", [], nil}
    head = {:"::", [], [{gname, [], [{:"::", [], [x, {:{}, [], [spec_ast.(ta), spec_ast.(tb)]}]}]}, spec_ast.(ret)]}
    gf = gname |> Atom.to_string() |> String.replace_suffix("__zip", "") |> String.to_atom()
    body = {:__block__, [], [{:=, [], [{:{}, [], [va, vb]}, x]}, {gf, [], [va, vb]}]}
    {head, body}
  end

  def kernel_def(gname, %{params: ps}, _spec_ast),
    do: raise(ArgumentError, "definstance: zip_with takes a function of two arguments, #{gname |> Atom.to_string() |> String.replace_suffix("__zip", "")} has #{length(ps)}")

  @doc false
  def repipe([first | rest]), do: Enum.reduce(rest, first, fn s, acc -> {:|>, [], [acc, s]} end)
end
