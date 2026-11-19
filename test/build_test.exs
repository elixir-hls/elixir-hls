defmodule EHLS.BuildTest do
  # the Mix tasks' parts (EHLS.Build, EHLS.Machine, EHLS.Flash) with a target that only records what it is asked
  use ExUnit.Case, async: false

  defmodule FakeTarget do
    @behaviour EHLS.Target
    def name, do: :fake
    def settings, do: [%{key: :uart_port, env: "EHLS_FAKE_PORT", doc: "a port", find: fn -> "/dev/found" end}]
    def steps(_), do: []
    def flash_images(p), do: %{vm: Path.join(p.build, "vm.bin"), lib: Path.join(p.build, "lib.avm")}
    def run_needs, do: [:vm, :lib]
    def flash(_, parts, _), do: send(self(), {:flashed, parts}) && :ok
    def run(_, _), do: :ok
  end

  setup do
    root = Path.join(System.tmp_dir!(), "ehls_build_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    cache = Path.join(root, "cache")
    System.put_env("EHLS_CACHE_DIR", cache)
    System.put_env("EHLS_USER_CONFIG", Path.join(root, "user_config.exs"))

    on_exit(fn ->
      File.rm_rf!(root)
      for v <- ~w(EHLS_CACHE_DIR EHLS_USER_CONFIG EHLS_FAKE_PORT), do: System.delete_env(v)
      Application.delete_env(:elixir_hls, :uart_port)
    end)

    project = %EHLS.Project{
      app: :demo,
      root: root,
      build: Path.join(root, "build"),
      start: Demo,
      config: [],
      target: FakeTarget
    }

    Mix.shell(Mix.Shell.Process)
    {:ok, project: project, root: root}
  end

  defp step(root, name, inputs, out) do
    %{
      name: name,
      inputs: inputs,
      exclude: [~r/sim_/],
      outputs: [out],
      run: fn ->
        send(self(), {:ran, name})
        File.mkdir_p!(Path.dirname(Path.join(root, out)))
        # the output: what the inputs say, so a later step sees a change only when this one's output changes
        text = for(g <- inputs, f <- Path.wildcard(Path.join(root, g)), do: File.read!(f)) |> Enum.join()
        File.write!(Path.join(root, out), String.upcase(text))
      end
    }
  end

  defp ran do
    receive do
      {:ran, n} -> [n | ran()]
    after
      0 -> []
    end
  end

  test "a step runs when its inputs change; a later step only when what it reads changes", %{project: p, root: root} do
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/a.ex"), "a")
    steps = [step(root, :kernels, ["lib/*.ex"], "build/hw/k.json"), step(root, :soc, ["build/hw/*"], "build/soc.bin")]

    assert EHLS.Build.run(p, steps) == [:kernels, :soc]
    assert ran() == [:kernels, :soc]

    # nothing changed
    assert EHLS.Build.run(p, steps) == []

    # the first step's output the same: the second is up to date (as the SoC after a change of the CPU's code)
    File.write!(Path.join(root, "lib/a.ex"), "A")
    assert EHLS.Build.run(p, steps) == [:kernels]

    # an excluded file changes nothing
    File.write!(Path.join(root, "build/hw/sim_x"), "random")
    assert EHLS.Build.run(p, steps) == []

    # a real change reaches both
    File.write!(Path.join(root, "lib/a.ex"), "b")
    assert EHLS.Build.run(p, steps) == [:kernels, :soc]

    # an output gone
    File.rm!(Path.join(root, "build/soc.bin"))
    assert EHLS.Build.reason(p, Enum.at(steps, 1)) == "build/soc.bin missing"
    assert EHLS.Build.run(p, steps) == [:soc]
  end

  test "--only, --force and --dry-run", %{project: p, root: root} do
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "lib/a.ex"), "a")
    steps = [step(root, :kernels, ["lib/*.ex"], "build/hw/k.json"), step(root, :soc, ["build/hw/*"], "build/soc.bin")]

    assert EHLS.Build.run(p, steps, dry_run: true) == [:kernels, :soc]
    assert ran() == []
    assert EHLS.Build.run(p, steps, only: [:kernels]) == [:kernels]
    assert EHLS.Build.run(p, steps, dry_run: true) == [:soc]
    EHLS.Build.run(p, steps)
    assert EHLS.Build.run(p, steps, only: [:soc], force: true) == [:soc]
    assert_raise Mix.Error, ~r/no step pack/, fn -> EHLS.Build.run(p, steps, only: [:pack]) end
  end

  test "a step that makes no output stops the build", %{project: p} do
    s = %{name: :bad, outputs: ["build/none"], run: fn -> :ok end}
    assert_raise Mix.Error, ~r/bad: ran but did not make build\/none/, fn -> EHLS.Build.run(p, [s]) end
  end

  test "a machine's setting: the environment, the config, the user's config, found", %{project: p, root: root} do
    assert EHLS.Machine.get(p, :uart_port) == "/dev/found"
    File.write!(Path.join(root, "user_config.exs"), ~s(import Config\nconfig :elixir_hls, uart_port: "/dev/user"\n))
    assert EHLS.Machine.get(p, :uart_port) == "/dev/user"
    Application.put_env(:elixir_hls, :uart_port, "/dev/config")
    assert EHLS.Machine.get(p, :uart_port) == "/dev/config"
    System.put_env("EHLS_FAKE_PORT", "/dev/env")
    assert EHLS.Machine.lookup(Enum.find(EHLS.Machine.settings(p), &(&1.key == :uart_port))) == {"/dev/env", :env}
    assert {"EHLS_FAKE_PORT", "/dev/env"} in EHLS.Machine.env(p)
  end

  test "a setting not set says where it looked", %{project: p} do
    defmodule NoFind do
      def name, do: :nofind
      def settings, do: [%{key: :nothing_here, env: "EHLS_NOTHING_HERE", doc: "nothing", find: nil}]
    end

    assert_raise Mix.Error, ~r/EHLS_NOTHING_HERE is not set: nothing.*config\/local.exs/s, fn ->
      EHLS.Machine.get!(%{p | target: NoFind}, :nothing_here)
    end
  end

  defmodule SetupTarget do
    @behaviour EHLS.Target
    def name, do: :setup_fake
    def settings, do: []
    def steps(_), do: []
    def flash_images(_), do: %{}
    def run_needs, do: []
    def flash(_, _, _), do: :ok
    def run(_, _), do: :ok
    def setup(_, opts), do: send(self(), {:setup, opts}) && :ok
  end

  test "mix ehls.setup: the target's setup, with --force; a target without one has nothing to set up",
       %{project: p} do
    Mix.Tasks.Ehls.Setup.setup(%{p | target: SetupTarget}, [])
    assert_received {:setup, [force: false]}
    Mix.Tasks.Ehls.Setup.setup(%{p | target: SetupTarget}, ["--force"])
    assert_received {:setup, [force: true]}

    Mix.Tasks.Ehls.Setup.setup(p, [])
    assert_received {:mix_shell, :info, ["the target :fake has nothing to set up"]}
  end

  test "the user's cache: EHLS_CACHE_DIR, else the platform's", %{root: root} do
    assert EHLS.Machine.cache_dir() == Path.join(root, "cache")
    System.delete_env("EHLS_CACHE_DIR")
    assert EHLS.Machine.cache_dir() == :filename.basedir(:user_cache, ~c"ehls") |> to_string()
  end

  test "the flash's record: only what differs is written", %{project: p} do
    File.mkdir_p!(p.build)
    File.write!(Path.join(p.build, "vm.bin"), "vm1")
    File.write!(Path.join(p.build, "lib.avm"), "lib1")

    assert EHLS.Flash.stale(p, [:vm, :lib]) == [:vm, :lib]
    EHLS.Flash.write!(p, [:vm, :lib])
    assert_received {:flashed, [:vm, :lib]}
    assert EHLS.Flash.stale(p, [:vm, :lib]) == []

    # another AtomVM (another SoC): only it
    File.write!(Path.join(p.build, "vm.bin"), "vm2")
    assert EHLS.Flash.stale(p, [:vm, :lib]) == [:vm]

    # another board (another port) holds nothing known
    System.put_env("EHLS_FAKE_PORT", "/dev/other")
    assert EHLS.Flash.stale(p, [:vm, :lib]) == [:vm, :lib]
    System.delete_env("EHLS_FAKE_PORT")

    EHLS.Flash.forget(p)
    assert EHLS.Flash.stale(p, [:vm, :lib]) == [:vm, :lib]
  end
end
