defmodule Mix.Tasks.Ehls.Deps do
  @shortdoc "Prints the project's dependencies and their directories"
  @moduledoc """
  Prints one line per dependency of the current project, `name directory`, for a target's
  scripts to find the packages, the target and elixir-hls wherever Mix put them (`deps/`
  after `mix deps.get`, or the directory of a `path:` dependency):

      mix ehls.deps
  """
  use Mix.Task

  @impl true
  def run(_args) do
    for {name, path} <- Enum.sort(Mix.Project.deps_paths()), do: IO.puts("#{name} #{path}")
  end
end
