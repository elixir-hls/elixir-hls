defmodule Mix.Tasks.Ehls.NewTest do
  use ExUnit.Case

  setup do
    Mix.shell(Mix.Shell.Process)
    dir = Path.join(System.tmp_dir!(), "ehls_new_test_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  test "an application for tang25k", %{dir: dir} do
    path = Path.join(dir, "my-app")
    Mix.Tasks.Ehls.New.run([path])

    files =
      for f <- Path.wildcard(Path.join(path, "**/*"), match_dot: true), File.regular?(f),
          do: Path.relative_to(f, path)

    assert Enum.sort(files) ==
             ~w(.formatter.exs .gitignore README.md config/config.exs lib/my_app.ex mix.exs test/my_app_test.exs test/test_helper.exs)

    mix = File.read!(Path.join(path, "mix.exs"))
    assert mix =~ "defmodule MyApp.MixProject"
    assert mix =~ "app: :my_app,"
    assert mix =~ ~s({:atomvm_tang25k_hls, "~> 0.1"})
    lib = File.read!(Path.join(path, "lib/my_app.ex"))
    assert lib =~ "defmodule MyApp do"
    # what runs on the board: only what AtomVM's libraries have (IO.inspect/2 is not there)
    refute lib =~ ~r/IO\.inspect\([^)]*,\s*label:/
    assert File.read!(Path.join(path, "README.md")) =~ "mix ehls.run"
    config = File.read!(Path.join(path, "config/config.exs"))
    assert config =~ "config :elixir_hls, target: :tang25k, start: MyApp"
    assert config =~ ~s{import_config("local.exs")}
    assert File.read!(Path.join(path, ".gitignore")) =~ "/config/local.exs"

    # every Elixir file of it is Elixir
    for f <- files, Path.extname(f) in [".ex", ".exs"] do
      assert {:ok, _} = Code.string_to_quoted(File.read!(Path.join(path, f))), f
    end
  end

  test "--app, --module and --target", %{dir: dir} do
    path = Path.join(dir, "x")
    Mix.Tasks.Ehls.New.run([path, "--app", "blinky", "--module", "My.Blinky", "--target", "tang25k"])
    assert File.read!(Path.join(path, "lib/blinky.ex")) =~ "defmodule My.Blinky do"
    assert File.read!(Path.join(path, "test/blinky_test.exs")) =~ "My.Blinky.scale(7)"
  end

  test "refusals", %{dir: dir} do
    assert_raise Mix.Error, ~r/must start with a letter/, fn -> Mix.Tasks.Ehls.New.run([Path.join(dir, "1app")]) end

    assert_raise Mix.Error, ~r/not a module name/, fn ->
      Mix.Tasks.Ehls.New.run([Path.join(dir, "a"), "--module", "lower"])
    end

    assert_raise Mix.Error, ~r/no target "zynq"/, fn ->
      Mix.Tasks.Ehls.New.run([Path.join(dir, "a"), "--target", "zynq"])
    end

    assert_raise Mix.Error, ~r/expected PATH/, fn -> Mix.Tasks.Ehls.New.run([]) end
    File.mkdir_p!(Path.join(dir, "full"))
    File.write!(Path.join(dir, "full/f"), "")
    assert_raise Mix.Error, ~r/is not empty/, fn -> Mix.Tasks.Ehls.New.run([Path.join(dir, "full")]) end
  end
end
