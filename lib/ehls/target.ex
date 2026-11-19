defmodule EHLS.Target do
  @moduledoc """
  A board an application runs on, as the Mix tasks see it (`mix ehls.build`, `mix ehls.run`, `mix ehls.flash`,
  `mix ehls.console`, `mix ehls.doctor`, `mix ehls.setup`): the tasks are elixir-hls', the work is the target's.

  A target package (atomvm-tang25k-hls for the Sipeed Tang Primer 25K) has a module with `@behaviour EHLS.Target`;
  the tasks find it among the application's dependencies. With several, `config :elixir_hls, target: :tang25k`
  picks one by its `c:name/0` (or a module name).

  For those writing a target: the callbacks below; the steps of a build are `t:EHLS.Build.step/0`, the machine's
  settings `t:EHLS.Machine.setting/0`.
  """

  @typedoc "What a flash part writes: `:vm`, `:lib`, `:bitstream`, `:app`, ..."
  @type part :: atom

  @doc "The target's name, as `config :elixir_hls, target:` gives it (e.g. `:tang25k`)."
  @callback name() :: atom

  @doc "The machine's settings the target needs besides elixir-hls' own (`EHLS.Machine`)."
  @callback settings() :: [EHLS.Machine.setting()]

  @doc "The steps of a build, in order (`EHLS.Build`)."
  @callback steps(EHLS.Project.t()) :: [EHLS.Build.step()]

  @doc "The files each flash part writes, for the record of what the board holds."
  @callback flash_images(EHLS.Project.t()) :: %{part => Path.t()}

  @doc "The flash parts a run needs in the board (e.g. `[:vm, :lib]`); `mix ehls.run` writes those that changed."
  @callback run_needs() :: [part]

  @doc "Writes the given parts to the board's flash."
  @callback flash(EHLS.Project.t(), [part], keyword) :: :ok

  @doc "Sends the application to the board, starts it and shows its console (options: `seconds:`)."
  @callback run(EHLS.Project.t(), keyword) :: :ok

  @doc """
  Sets up once what the target's builds need on this machine and is not in the dependencies as Mix fetched them (on
  the Tang Primer 25K the base's LiteX, AtomVM and host tools), for `mix ehls.setup` (options: `force: true` to do it
  again). Kept outside the application (`EHLS.Machine.cache_dir/0`), so the applications of the machine share it.
  """
  @callback setup(EHLS.Project.t(), keyword) :: :ok

  @doc "Shows the board's console until interrupted."
  @callback console(EHLS.Project.t()) :: :ok

  @doc "The target's checks for `mix ehls.doctor`: a label and a function giving `:ok` or `{:error, why}`."
  @callback checks(EHLS.Project.t()) :: [{String.t(), (-> :ok | {:error, String.t()})}]

  @doc "The board's parts for `EHLS.GPIO` (a JSON file), or nil."
  @callback board_gpio() :: Path.t() | nil

  @optional_callbacks setup: 2, console: 1, checks: 1, board_gpio: 0

  @doc """
  The target of the current Mix project: `config :elixir_hls, target:` (a name or a module), else the only target
  among the dependencies. Raises when there is none, or several and no choice.
  """
  def find!(choice \\ Application.get_env(:elixir_hls, :target)) do
    if is_atom(choice) and String.starts_with?(Atom.to_string(choice), "Elixir."),
      do: Code.ensure_loaded!(choice),
      else: by_name(choice, candidates())
  end

  defp by_name(choice, candidates) do
    case {choice, candidates} do
      {_, []} ->
        raise Mix.Error,
          message:
            "no target among the dependencies: add a target package (e.g. :atomvm_tang25k_hls) to mix.exs " <>
              "and run mix deps.get"

      {nil, [m]} ->
        m

      {nil, ms} ->
        raise Mix.Error,
          message:
            "several targets among the dependencies (#{names(ms)}): choose one with config :elixir_hls, target: ..."

      {name, ms} ->
        Enum.find(ms, &(&1.name() == name)) ||
          raise Mix.Error, message: "no target #{inspect(name)} among the dependencies (#{names(ms)})"
    end
  end

  @doc "The target if one is found, else nil (for the compile on the host, which needs none)."
  def find do
    if Code.ensure_loaded?(Mix.Project) and Mix.Project.get() do
      try do
        find!()
      rescue
        _ -> nil
      end
    end
  end

  defp names(ms), do: Enum.map_join(ms, ", ", &inspect(&1.name()))

  # the modules of the dependencies with @behaviour EHLS.Target
  defp candidates do
    for {app, _} <- Mix.Project.deps_paths(),
        Application.load(app) in [:ok, {:error, {:already_loaded, app}}],
        {:ok, mods} <- [:application.get_key(app, :modules)],
        m <- mods,
        target?(m),
        uniq: true,
        do: m
  end

  defp target?(m) do
    Code.ensure_loaded?(m) and
      __MODULE__ in (m.module_info(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten())
  end
end
