defmodule EHLS.Project do
  @moduledoc """
  The application the Mix tasks build: its name, directory, start module, settings (`config :elixir_hls`) and
  target (`EHLS.Target`).

      config :elixir_hls,
        target: :tang25k,       # the board (else the only target among the dependencies)
        start: MyApp,           # the module whose start/0 runs on the board (else the app's name camelized)
        gowin: [place: 2],      # the target's own options (here Gowin's placement)
        blocks: [:atomvm_tang25k_i2s]   # the block packages (else every dependency that is one)

  The machine's paths (`GOWIN_HOME`, `CIRCT_BIN`, ...) are not here but in `EHLS.Machine`.
  """

  @enforce_keys [:app, :root, :build, :start, :config, :target]
  defstruct [:app, :root, :build, :start, :config, :target]

  @type t :: %__MODULE__{
          app: atom,
          root: Path.t(),
          build: Path.t(),
          start: module,
          config: keyword,
          target: module
        }

  @doc "The current Mix project, its dependencies and itself compiled and its config loaded."
  def load! do
    Mix.Task.run("compile", [])
    from_mix()
  end

  @doc false
  # the current Mix project as it is (no compile): for the tests and the tasks after their compile
  def from_mix(target \\ nil) do
    app = Mix.Project.config()[:app] || Mix.raise("this directory is not a Mix project of an application")
    root = File.cwd!()
    config = Application.get_all_env(:elixir_hls)

    %__MODULE__{
      app: app,
      root: root,
      build: Path.join(root, "build"),
      start: config[:start] || Module.concat([Macro.camelize(Atom.to_string(app))]),
      config: config,
      target: target || EHLS.Target.find!(config[:target])
    }
  end

  @doc "The directory of a dependency, or nil."
  def dep_path(name), do: Mix.Project.deps_paths()[name]

  @doc "The directories of the dependencies, `name => directory`."
  def deps, do: Mix.Project.deps_paths()
end
