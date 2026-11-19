defmodule EHLS.Flash do
  @moduledoc """
  The record of what a board's flash holds: for each part (`:vm`, `:lib`, ...) the hash of the file last written
  there by `mix ehls.flash` or `mix ehls.run`. A board is told apart by its target and its port (the machine's
  `uart_port`, if the target has one), so one record serves every application on the machine: an AtomVM written
  for another application's SoC is seen as not matching.

  Kept in the user's cache (`~/.cache/ehls/flash.json`; another directory with `EHLS_CACHE_DIR`).
  """

  @doc "The parts among `parts` whose file differs from what the record says the board holds."
  def stale(project, parts) do
    images = project.target.flash_images(project)
    held = Map.get(read(), board(project), %{})

    for p <- parts, path = images[p] || Mix.raise("the target has no flash part #{inspect(p)}"),
        not File.exists?(path) or held[Atom.to_string(p)] != digest(path),
        do: p
  end

  @doc "Writes the parts with the target and records them."
  def write!(project, parts, opts \\ []) do
    parts = Enum.uniq(parts)
    images = project.target.flash_images(project)

    for p <- parts, not File.exists?(images[p] || ""),
        do: Mix.raise("nothing to write for #{p}: #{images[p]} missing (mix ehls.build)")

    project.target.flash(project, parts, opts)
    record(project, Map.new(parts, &{Atom.to_string(&1), digest(images[&1])}))
  end

  @doc "Forgets what the board holds (the next run writes every part it needs)."
  def forget(project), do: write_all(Map.delete(read(), board(project)))

  defp record(project, parts) do
    all = read()
    write_all(Map.put(all, board(project), Map.merge(Map.get(all, board(project), %{}), parts)))
  end

  defp board(project), do: "#{project.target.name()} #{EHLS.Machine.get(project, :uart_port) || "default"}"

  defp digest(path), do: :crypto.hash(:sha256, File.read!(path)) |> Base.encode16(case: :lower)

  defp path do
    Path.join(EHLS.Machine.cache_dir(), "flash.json")
  end

  defp read do
    case File.read(path()) do
      {:ok, s} -> JSON.decode!(s)
      _ -> %{}
    end
  end

  defp write_all(map) do
    File.mkdir_p!(Path.dirname(path()))
    File.write!(path(), JSON.encode!(map))
  end
end
