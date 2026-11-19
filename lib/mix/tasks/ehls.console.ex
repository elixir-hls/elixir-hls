defmodule Mix.Tasks.Ehls.Console do
  @shortdoc "Shows the board's console"
  @moduledoc """
  Shows the board's console (what the application prints) until interrupted (Ctrl+C twice):

      mix ehls.console

  The port is the target's (on the Tang Primer 25K the machine's `uart_port`, `EHLS.Machine`). Close it before
  `mix ehls.run` on a target whose run sends the application through the same port (the Tang Primer 25K's does).
  """
  use Mix.Task

  @impl true
  def run(_argv) do
    project = EHLS.Project.load!()

    if function_exported?(project.target, :console, 1),
      do: project.target.console(project),
      else: Mix.raise("the target #{inspect(project.target.name())} has no console")
  end
end
