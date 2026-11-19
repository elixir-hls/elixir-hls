defmodule Mix.Tasks.Ehls.Doctor do
  @shortdoc "Checks the tools and the machine's settings a build and a run need"
  @moduledoc """
  Checks what a build and a run need on this machine, and says what is missing:

      mix ehls.doctor

  The machine's settings (`EHLS.Machine`: each with its value and where it came from), elixir-hls' tools (python3,
  iverilog, CIRCT) and the target's checks (on the Tang Primer 25K the Gowin IDE, openFPGALoader, Zephyr, the base
  atomvm-tang25k, the port). Exits with status 1 when one fails.
  """
  use Mix.Task

  @impl true
  def run(_argv) do
    project = EHLS.Project.load!()
    info("target: #{inspect(project.target.name())} (#{inspect(project.target)}), start: #{inspect(project.start)}")
    info("\nthe machine's settings:")

    for s <- EHLS.Machine.settings(project) do
      case EHLS.Machine.lookup(s) do
        {nil, nil} -> info("  #{s.env}: not set (#{s.doc})")
        {v, from} -> info("  #{s.env}: #{v} (#{from})")
      end
    end

    target_checks =
      if function_exported?(project.target, :checks, 1), do: project.target.checks(project), else: []

    info("\nchecks:")

    failed =
      Enum.reject(own_checks(project) ++ target_checks, fn {label, check} ->
        case safe(check) do
          :ok ->
            info("  ok    #{label}")
            true

          {:error, why} ->
            info("  FAIL  #{label}: #{why}")
            false
        end
      end)

    if failed == [],
      do: info("\nall good"),
      else: Mix.raise("#{length(failed)} check(s) failed")
  end

  defp info(msg), do: Mix.shell().info(msg)

  defp safe(check) do
    check.()
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp own_checks(project) do
    [
      {"python3", fn -> exe("python3") end},
      {"iverilog (the circuits' simulations)", fn -> exe("iverilog") end},
      {"CIRCT 1.160.0 (CIRCT_BIN: hlstool, mlir-opt)",
       fn ->
         case EHLS.Machine.get(project, :circt_bin) do
           nil ->
             {:error, "CIRCT_BIN not set and no hlstool on PATH"}

           dir ->
             missing = for t <- ~w(hlstool mlir-opt), not File.exists?(Path.join(dir, t)), do: t
             if missing == [], do: :ok, else: {:error, "#{dir} has no #{Enum.join(missing, ", ")}"}
         end
       end}
    ]
  end

  defp exe(name), do: if(System.find_executable(name), do: :ok, else: {:error, "#{name} not on PATH"})
end
