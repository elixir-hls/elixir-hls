defmodule Mix.Tasks.Ehls.Run do
  @shortdoc "Builds what changed, sends the application to the board and shows its console"
  @moduledoc """
  Runs the application on its board:

      mix ehls.run                      # build what changed, write the flash parts the run needs, run
      mix ehls.run --seconds 30         # the console shown for 30 s (default 10)
      mix ehls.run --no-build           # as built
      mix ehls.run --no-flash           # trust what the board's flash holds

  First `mix ehls.build`. Then the parts the target needs in the flash for a run (on the Tang Primer 25K AtomVM and
  its library) are written when they differ from what the board holds (`EHLS.Flash`): an AtomVM built for another
  SoC is never left there. Then the target sends the application and starts it; nothing else of the flash changes.
  """
  use Mix.Task

  @switches [seconds: :integer, build: :boolean, flash: :boolean]

  @impl true
  def run(argv) do
    {opts, _} = OptionParser.parse!(argv, strict: @switches)
    project = EHLS.Project.load!()
    if Keyword.get(opts, :build, true), do: Mix.Tasks.Ehls.Build.build(project, [])

    if Keyword.get(opts, :flash, true) do
      case EHLS.Flash.stale(project, project.target.run_needs()) do
        [] ->
          :ok

        parts ->
          Mix.shell().info("== flash: #{Enum.join(parts, ", ")} (not what the board holds)")
          EHLS.Flash.write!(project, parts)
      end
    end

    project.target.run(project, seconds: opts[:seconds] || 10)
  end
end
