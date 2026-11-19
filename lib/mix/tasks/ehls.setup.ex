defmodule Mix.Tasks.Ehls.Setup do
  @shortdoc "Sets up once what the target's builds need on this machine"
  @moduledoc """
  Sets up, once for the machine, what the target's builds need and the dependencies do not bring as they are (on
  the Tang Primer 25K the base atomvm-tang25k: its LiteX, AtomVM and host tools, some tens of minutes):

      mix ehls.setup
      mix ehls.setup --force            # again, from the start

  What is set up is kept in the user's cache (`EHLS.Machine.cache_dir/0`), one per version of what it is made from,
  so the applications of the machine share it and `mix deps.get` leaves it alone. Then `mix ehls.doctor` checks the
  rest and `mix ehls.build` builds.
  """
  use Mix.Task

  @switches [force: :boolean]

  @impl true
  def run(argv) do
    setup(EHLS.Project.load!(), argv)
  end

  @doc false
  def setup(project, argv) do
    {opts, _} = OptionParser.parse!(argv, strict: @switches)

    if function_exported?(project.target, :setup, 2) do
      :ok = project.target.setup(project, force: opts[:force] || false)
    else
      Mix.shell().info("the target #{inspect(project.target.name())} has nothing to set up")
    end
  end
end
