defmodule Mix.Tasks.Ehls.New do
  @shortdoc "Creates a new Elixir HLS application"

  @moduledoc """
  Creates a new Elixir HLS application: a Mix project with the target's dependency, a module with a `defhls`
  function placed by two `definstance`s, a test of them on the host, and the steps to the board in its README.

      mix ehls.new PATH [--app APP] [--module MODULE] [--target TARGET]

  The application is made in `PATH`, which must not exist or be empty.

  ## Options

    * `--app` - the OTP application name (default: the last part of `PATH`, `-` turned into `_`)
    * `--module` - the module's name (default: the application name camelized)
    * `--target` - the board: #{Enum.join(~w(tang25k), ", ")} (default: tang25k)

  ## Targets

    * `tang25k` - the Sipeed Tang Primer 25K, AtomVM on its LiteX SoC
      ([atomvm-tang25k-hls](https://github.com/elixir-hls/atomvm-tang25k-hls))

  ## Installing

      mix archive.install hex ehls_new
  """
  use Mix.Task
  import Mix.Generator

  @targets ~w(tang25k)
  @switches [app: :string, module: :string, target: :string]

  @impl true
  def run(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {opts, [path], []} -> generate(path, opts)
      {_, _, [{bad, _} | _]} -> Mix.raise("mix ehls.new: unknown option #{bad}")
      _ -> Mix.raise("mix ehls.new: expected PATH, as in: mix ehls.new my_app")
    end
  end

  defp generate(path, opts) do
    app = opts[:app] || path |> Path.expand() |> Path.basename() |> String.replace("-", "_")
    module = opts[:module] || Macro.camelize(app)
    target = opts[:target] || "tang25k"

    app =~ ~r/^[a-z][a-z0-9_]*$/ ||
      Mix.raise("mix ehls.new: the application name #{inspect(app)} must start with a letter and have only " <>
                  "lowercase letters, digits and _ (give one with --app)")

    module =~ ~r/^[A-Z]\w*(\.[A-Z]\w*)*$/ ||
      Mix.raise("mix ehls.new: #{inspect(module)} is not a module name (give one with --module)")

    target in @targets ||
      Mix.raise("mix ehls.new: no target #{inspect(target)}; the targets: #{Enum.join(@targets, ", ")}")

    if File.exists?(path) and File.ls!(path) != [] do
      Mix.raise("mix ehls.new: #{path} is not empty")
    end

    assigns = [app: app, module: module]

    for {file, content} <- files(target, assigns) do
      create_file(Path.join(path, file), content)
    end

    Mix.shell().info("""

    The application #{app} is in #{path}. Next:

        cd #{path}
        mix deps.get
        mix test

    The steps to the board are in its README.md.
    """)
  end

  defp files("tang25k", a) do
    [
      {"mix.exs", tang25k_mix_template(a)},
      {"config/config.exs", tang25k_config_template(a)},
      {"README.md", tang25k_readme_template(a)},
      {"lib/#{a[:app]}.ex", tang25k_lib_template(a)},
      {"test/test_helper.exs", test_helper_text()},
      {"test/#{a[:app]}_test.exs", test_template(a)},
      {".formatter.exs", formatter_text()},
      {".gitignore", gitignore_text()}
    ]
  end

  embed_template(:tang25k_mix, ~S"""
  defmodule <%= @module %>.MixProject do
    use Mix.Project

    def project do
      [
        app: :<%= @app %>,
        version: "0.1.0",
        elixir: "~> 1.18",
        deps: deps()
      ]
    end

    def application, do: []

    defp deps do
      [
        # the target, the Tang Primer 25K: it brings elixir-hls and atomvm-tang25k
        {:atomvm_tang25k_hls, "~> 0.1"}
      ]
    end
  end
  """)

  embed_template(:tang25k_config, ~S"""
  import Config

  # the board, the Sipeed Tang Primer 25K (atomvm-tang25k-hls); <%= @module %>.start/0 runs on it
  config :elixir_hls, target: :tang25k, start: <%= @module %>

  # the target's options, when they are needed:
  #   config :elixir_hls, gowin: [place: 2]        # Gowin's placement, when the default misses the timing
  #   config :elixir_hls, blocks: [:atomvm_tang25k_i2s]   # the block packages (default: every one among the deps)

  # this machine's paths (GOWIN_HOME, UART_PORT, ATOMVM_TANG25K, CIRCT_BIN; mix ehls.doctor lists them), kept out of
  # git: config :elixir_hls, gowin_home: "~/Gowin_V1.9.11.03_Education", ...
  if File.exists?(Path.join(__DIR__, "local.exs")), do: import_config("local.exs")
  """)

  embed_template(:tang25k_lib, ~S'''
  defmodule <%= @module %> do
    @moduledoc """
    A `defhls` function, on the CPU and in the FPGA: `scale/1` gives `x * 10 + 3`, so 7 gives 73.
    """
    use EHLS

    defhls scale(x :: u32) :: u32 do
      x * 10 + 3
    end

    # a value in, a value out: the CPU writes it, the circuit computes, the result is held
    definstance scale_hw(x :: u32) do
      scale(x)
    end

    # a stream: a list in, each value through scale/1, a list out
    definstance scale_stream(values) do
      values |> map(&scale/1)
    end

    # where the application starts on the board (AtomVM's IO has puts/1 and inspect/1, not inspect/2)
    def start do
      IO.puts("on the CPU: #{inspect(scale(7))}")
      IO.puts("in the FPGA: #{inspect(scale_hw(7))}")
      IO.puts("a stream: #{inspect(scale_stream([1, 2, 3]))}")
    end
  end
  ''')

  embed_template(:test, ~S"""
  defmodule <%= @module %>Test do
    use ExUnit.Case

    # on the host the instances run as Elixir functions; mix ehls.compile / mix ehls.sim check the circuits
    test "scale/1 and its instances" do
      assert <%= @module %>.scale(7) == 73
      assert <%= @module %>.scale_hw(7) == 73
      assert <%= @module %>.scale_stream([1, 2, 3]) == [13, 23, 33]
    end
  end
  """)

  embed_template(:tang25k_readme, ~S"""
  # <%= @app %>

  An Elixir HLS application for the Sipeed Tang Primer 25K: `lib/<%= @app %>.ex`, its `defhls` functions placed in
  the FPGA by `definstance`, called from Elixir on the board's CPU (AtomVM).

  ## On the host

  ```sh
  mix deps.get
  mix test                          # the functions and the instances, as Elixir
  mix ehls.compile lib/<%= @app %>.ex     # each function's circuit, checked in simulation against the function
  mix ehls.sim lib/<%= @app %>.ex         # the instances' circuits, called as the CPU calls them
  ```

  `mix ehls.compile` needs the CIRCT 1.160.0 binaries in `CIRCT_BIN` and Icarus Verilog (elixir-hls' README).

  ## On the board

  Once for the machine: the Gowin IDE, and the board's base, [atomvm-tang25k](https://github.com/elixir-hls/atomvm-tang25k)
  (its LiteX SoC and AtomVM), set up by `mix ehls.setup` (some tens of minutes; kept in `~/.cache/ehls`, shared by the
  projects of the machine). Where the Gowin IDE is goes into `config/local.exs` (not committed), unless it is found or
  in the environment:

  ```elixir
  import Config
  config :elixir_hls, gowin_home: "~/Gowin_V1.9.11.03_Education"
  ```

  Then:

  ```sh
  mix ehls.setup                    # once for the machine: the board's base
  mix ehls.doctor                   # what is set, what is missing
  mix ehls.run                      # build what changed, write AtomVM if the board lacks it, run, its console shown
  mix ehls.flash --standalone       # power on -> the application
  ```

  `mix ehls.build` builds alone (`--dry-run`: what would run); a change of the CPU's code only builds the
  application's pack, a change of a `defhls` function or a `definstance` the circuits and the SoC (Gowin, a few
  minutes) too. If the SoC misses the timing, `deps/atomvm_tang25k_hls/scripts/sweep_soc.sh` finds a placement for
  `config :elixir_hls, gowin: [place: ...]`. If a run fails right after a power-on or a flash write, run it again.
  """)

  embed_text(:test_helper, ~S"""
  ExUnit.start()
  """)

  embed_text(:formatter, ~S"""
  [inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"]]
  """)

  embed_text(:gitignore, ~S"""
  /_build/
  /deps/
  /build/
  /config/local.exs
  erl_crash.dump
  __pycache__/
  """)
end
