defmodule Mix.Tasks.Ehls.Compile do
  @shortdoc "Compiles defhls / definstance functions to SystemVerilog, checked in simulation"
  @moduledoc """
  Compiles the defhls functions and pipelines of Elixir files to SystemVerilog with CIRCT and
  checks every kernel in simulation (iverilog) against the same function run by Elixir:

      mix ehls.compile --out build file.ex...
      mix ehls.compile --out build --with blocks.ex app.ex   # --with: compiled along (e.g.
                                                            # EHLS.Blocks modules of packages)

  Writes to `<out>/hw`: per kernel `<kernel>.sv` (a CIRCT handshake module; with tables /
  memories also `<kernel>_space.v`), `<kernel>.sig` (JSON: types, state, the arguments after the first, memories),
  the simulation files; for the SoC backend `kernels.json`, `pipelines.json`,
  `peripherals.json`, `packages.json`; and, with a runtime backend, what it generates (e.g.
  `<out>/gen/hw_kernels.erl`: the indices for the generated runtime calls).

  `--target cpu` writes C for the CPU instead (`<out>/cpu/<kernel>.c`, see `EHLS.NIF`) and checks it
  against the Elixir functions with the host's C compiler; it needs no CIRCT, python3 or iverilog.

  Options: `--target` (`circuit`, default, or `cpu`), `--out` (default `build`), `--with FILE` (repeatable), `--vectors N` (random
  vectors per kernel, default 2000). Environment: `CIRCT_BIN` (required: the directory of the
  CIRCT 1.160 release binaries, hlstool + mlir-opt), `EHLS_DEVICE` / `EHLS_SOC` / `EHLS_RUNTIME`
  (the backends, `EHLS.Backend`), `PIPE_BUDGET` (ns; default: the device's). Needs python3
  and iverilog.

  ## The check in simulation

  No test is written by hand: for each kernel the inputs, the expected results and the testbench
  are made here, and the circuit runs in iverilog against them.

    * **Inputs:** edge values first, `0`, `1`, `0x7FFF`, `0x8000`, `0xFFFF`, `0x10000`,
      `0x7FFFFFFF`, `0x80000000`, `0xFFFFFFFF`, `0x80008000`, `0x7FFF7FFF` (and, for a kernel
      with 64-bit ports, `0x100000000`, `0x7FFFFFFFFFFF`, `0x800000000000`, `0xFFFFFFFFFFFF`,
      `0x7FFFFFFFFFFFFFFF`, `0x8000000000000000` and all ones); then `--vectors N` random ones. A
      random input covers the whole port, 32 or 64 bits, so bits beyond the argument's type come
      too: the circuit and the function both cut them, which is checked as well. A tuple gets the
      edge values at each of its values in turn, the others random, then random tuples. The seed is
      fixed, so every run has the same inputs.
    * **Expected results:** the same `defhls` function run by Elixir, on the BEAM, over the same
      inputs. The function is the specification.
    * **A kernel without state:** one input at a time, its result compared; `latency=a..b` is
      the fewest and the most clocks an input took.
    * **A kernel with state:** behind its state adapter, as in the SoC. The inputs go in two
      halves, each from the initial state, so a restart is checked too. The testbench leaves
      random gaps between the inputs it gives and between the outputs it takes, as data does not
      come every clock in a real circuit and whoever takes the output can make it wait. With a list as the output (`{[y], s}` / `{[], s}`), an input that gives nothing must give nothing.
      `clocks/word` is clocks per element.
    * **Levels** (a function's arguments besides the stream) are 0, or the integer they are placed with;
      tables and memories are in the simulation with their kernel.
    * **The verdict:** a line per kernel, `RESULT <kernel>: vectors=V errors=E ...`, where `V`
      counts the edge values and the random ones (11 + 2000 = 2011 by default; 2018 with 64-bit
      ports; for a tuple of k values, k times the edge values, e.g. 2 * 11 + 2000 = 2022). The first five differences are printed as `MISMATCH` lines, with what came and
      what was expected. A kernel with errors, or one that stops answering (`TIMEOUT`), stops the
      command there.

  Not checked here: a level changed while running, and the CPU ends (their DMA, in
  `test/sim_cpu_ends.py`). What a `definstance` places, its functions joined with the pipe,
  is checked by `mix ehls.sim`.
  """
  use Mix.Task

  @switches [out: :string, with: :keep, vectors: :integer, target: :string]

  @impl true
  def run(args) do
    {opts, files, _} = OptionParser.parse(args, strict: @switches)
    if files == [], do: Mix.raise("usage: mix ehls.compile [--out DIR] [--with FILE]... FILE.ex...")
    Mix.Task.run("compile")

    case opts[:target] do
      t when t in [nil, "circuit"] -> circuit(opts, files)
      "cpu" -> cpu(opts, files)
      t -> Mix.raise("--target #{t}: circuit or cpu")
    end
  end

  # --target cpu: each defhls as C for the CPU, built with the host's C compiler and checked against Elixir
  defp cpu(opts, files) do
    out = Path.join(out_dir(opts), "cpu")
    srcs = Enum.map(Keyword.get_values(opts, :with) ++ files, &Path.expand(&1, caller_dir()))
    hostc = Path.join(out_dir(opts), "hostc")
    File.rm_rf!(out)
    File.rm_rf!(hostc)
    File.mkdir_p!(out)
    File.mkdir_p!(hostc)
    pa = Enum.flat_map(String.split(ebin_paths(), ":"), &["-pa", &1])

    case System.cmd("elixirc", pa ++ ["-o", hostc | srcs], env: [{"EHLS_OUT_DIR", out}, {"EHLS_TARGET", "cpu"}, {"EHLS_PLACEMENT", to_string(EHLS.placement())}, {"EHLS_CPU", to_string(EHLS.cpu_code())}], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {log, _} -> Mix.raise("elixirc failed:\n" <> log)
    end

    Code.prepend_path(hostc)
    results = EHLS.NIF.check(out, opts[:vectors] || 2000)
    if results == [], do: Mix.raise("ehls.compile --target cpu: no defhls function in #{Enum.join(files, ", ")}")

    for {k, v, e} <- results, do: IO.puts("RESULT #{k}: vectors=#{v} errors=#{e} (cpu)")
    if Enum.any?(results, fn {_, _, e} -> e > 0 end), do: Mix.raise("ehls.compile --target cpu: a kernel differs from its function")

    # the runtime backend (EHLS_RUNTIME) builds the kernels in; no SoC or device is needed for the CPU
    runtime = EHLS.Backend.runtime()
    if runtime && function_exported?(runtime, :generate_nif, 1), do: runtime.generate_nif(out_dir(opts))
  end

  defp circuit(opts, files) do
    {device, _soc, runtime} = EHLS.Backend.check!()

    out = out_dir(opts)
    srcs = Enum.map(Keyword.get_values(opts, :with) ++ files, &Path.expand(&1, caller_dir()))
    priv = :code.priv_dir(:elixir_hls) |> to_string()

    env = [
      # elixir_hls' modules, then the project's (the same when run in elixir-hls itself)
      {"EHLS_EBIN", ebin_paths()},
      {"EHLS_PRIV", priv},
      {"OUT", out},
      {"CIRCT_BIN", circt_bin()},
      {"N", to_string(opts[:vectors] || System.get_env("N") || 2000)},
      {"PIPE_BUDGET", System.get_env("PIPE_BUDGET") || to_string(device.budget())},
      # elixirc does not read the application's config: where the instances go, from it or EHLS_PLACEMENT; circuits are
      # being made, so the FPGA unless one of them says otherwise
      {"EHLS_PLACEMENT", to_string(EHLS.placement(:fpga))},
      {"EHLS_CPU", to_string(EHLS.cpu_code())},
      {"DELAY_MODEL", JSON.encode!(device.delay_model())}
    ]

    {_, status} =
      System.cmd(Path.join(priv, "hls_compile.sh"), srcs, env: env, into: IO.stream(), stderr_to_stdout: true)

    if status != 0, do: Mix.raise("ehls.compile failed (#{status})")
    if runtime, do: runtime.generate(out)
    check_sources!(srcs, out)
  end

  @doc false
  def out_dir(opts), do: Path.expand(opts[:out] || "build", caller_dir())

  # what the block packages find in the sources (EHLS.Blocks.check_sources/2) stops the build
  defp check_sources!(srcs, out) do
    packages = Path.join([out, "hw", "packages.json"])
    packages = if File.exists?(packages), do: packages |> File.read!() |> JSON.decode!(), else: []

    errors =
      for p <- packages,
          # a package's module compiled for the application is not loaded here
          m = Module.concat([p["module"] || "Elixir.Nil"]),
          Code.ensure_loaded?(m) and function_exported?(m, :check_sources, 2),
          error <- m.check_sources(srcs, p["table"]),
          do: error

    if errors != [],
      do: Mix.raise(Enum.map_join(errors, "\n", fn {f, l, m} -> "#{f}:#{l}: #{m}" end))
  end

  # CIRCT_BIN, required: the directory of the CIRCT release binaries (hlstool, mlir-opt)
  defp circt_bin do
    dir =
      case System.get_env("CIRCT_BIN") do
        nil -> Mix.raise("CIRCT_BIN is not set: the directory of the CIRCT 1.160 release binaries (hlstool, mlir-opt)")
        "" -> Mix.raise("CIRCT_BIN is empty")
        d -> d
      end

    for tool <- ["hlstool", "mlir-opt"], not File.exists?(Path.join(dir, tool)),
        do: Mix.raise("CIRCT_BIN=#{dir}: no #{tool} there")

    dir
  end

  # paths are relative to where mix was started (EHLS_CALLER_DIR when run as a dependency
  # from another directory, e.g. `mix -C`), else the current directory
  defp caller_dir, do: System.get_env("EHLS_CALLER_DIR") || File.cwd!()

  # where elixir_hls' and the project's compiled modules are, ':'-separated: as a dependency the
  # project's compile path holds only the project's
  defp ebin_paths do
    [Path.join(to_string(:code.lib_dir(:elixir_hls)), "ebin"), Mix.Project.compile_path()]
    |> Enum.map(&Path.expand/1)
    |> Enum.uniq()
    |> Enum.join(":")
  end
end
