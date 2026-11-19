defmodule Mix.Tasks.Ehls.Build do
  @shortdoc "Builds the application for its board, only what changed"
  @moduledoc """
  Builds the application for its target's board: the target's steps (on the Tang Primer 25K the circuits, the SoC,
  AtomVM and the application's pack), each only when its inputs changed since it last ran (`EHLS.Build`):

      mix ehls.build
      mix ehls.build --dry-run          # what would run
      mix ehls.build --only soc         # one step alone (--only kernels,pack for two)
      mix ehls.build --force            # every step (or those of --only) whatever changed

  The target is found among the dependencies (`EHLS.Target`); the application's settings are in
  `config :elixir_hls` (`EHLS.Project`), the machine's paths in `EHLS.Machine`. Then `mix ehls.run` sends it to the
  board, `mix ehls.flash --standalone` writes it into the flash.
  """
  use Mix.Task

  @switches [only: :string, force: :boolean, dry_run: :boolean]

  @impl true
  def run(argv) do
    {opts, _} = OptionParser.parse!(argv, strict: @switches)
    project = EHLS.Project.load!()
    build(project, opts)
  end

  @doc false
  def build(project, opts) do
    only = opts[:only] && opts[:only] |> String.split(",", trim: true) |> Enum.map(&String.to_atom/1)
    EHLS.Build.run(project, project.target.steps(project), only: only, force: opts[:force], dry_run: opts[:dry_run])
  end
end
