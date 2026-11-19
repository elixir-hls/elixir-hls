defmodule Mix.Tasks.Ehls.Flash do
  @shortdoc "Writes the board's flash: what it lacks, or the application standalone"
  @moduledoc """
  Writes the board's flash, after `mix ehls.build`:

      mix ehls.flash                    # the parts a run needs that differ from what the board holds
      mix ehls.flash --standalone       # also the bitstream and the application: power on -> the application
      mix ehls.flash vm lib             # these parts, whatever the board holds
      mix ehls.flash --forget           # forget what the board holds (after writing it another way)

  The parts are the target's (`c:EHLS.Target.flash_images/1`; on the Tang Primer 25K `bitstream`, `vm`, `lib`,
  `app`). What was written is recorded (`EHLS.Flash`), for `mix ehls.run` and the next `mix ehls.flash`.
  Option `--no-build`: as built.
  """
  use Mix.Task

  @switches [standalone: :boolean, build: :boolean, forget: :boolean]

  @impl true
  def run(argv) do
    {opts, parts} = OptionParser.parse!(argv, strict: @switches)
    project = EHLS.Project.load!()

    if opts[:forget] do
      EHLS.Flash.forget(project)
      Mix.shell().info("forgot what the board holds")
    else
      if Keyword.get(opts, :build, true), do: Mix.Tasks.Ehls.Build.build(project, [])
      known = Map.keys(project.target.flash_images(project))

      parts =
        case parts do
          [] ->
            needs = project.target.run_needs()
            wanted = if opts[:standalone], do: needs ++ (known -- needs), else: needs
            EHLS.Flash.stale(project, wanted)

          names ->
            for n <- names do
              Enum.find(known, &(Atom.to_string(&1) == n)) ||
                Mix.raise("no flash part #{n}; the parts: #{Enum.join(known, ", ")}")
            end
        end

      if parts == [],
        do: Mix.shell().info("the board holds all of it already"),
        else: EHLS.Flash.write!(project, parts)
    end
  end
end
