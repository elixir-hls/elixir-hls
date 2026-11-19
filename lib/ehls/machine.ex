defmodule EHLS.Machine do
  @moduledoc """
  The machine's settings, which differ from one computer to the next and stay out of what is committed: where
  CIRCT is (`CIRCT_BIN`), and the target's own (on the Tang Primer 25K `GOWIN_HOME`, `UART_PORT`, ...).

  Each is looked up in order:

    1. the environment variable (`CIRCT_BIN=...`): for CI and one-off overrides;
    2. the application's config, `config :elixir_hls, circt_bin: "..."`: kept out of git in `config/local.exs`, which
       `config/config.exs` imports when it exists (as `mix ehls.new` writes them);
    3. the user's config for every application of the machine, `~/.config/ehls/config.exs` (the same
       `config :elixir_hls, ...`; another file with `EHLS_USER_CONFIG`);
    4. found on the machine, where the setting knows how (`hlstool` on `PATH` for `CIRCT_BIN`);
    5. else not set: the step that needs it stops and says where it looked; `mix ehls.doctor` shows them all.

  A path beginning with `~` is expanded.
  """

  @typedoc """
  A setting: its key in the config, its environment variable, a function finding it on the machine (or nil) and
  what it is.
  """
  @type setting :: %{key: atom, env: String.t(), find: (-> String.t() | nil) | nil, doc: String.t()}

  @doc "elixir-hls' own settings."
  def own do
    [
      %{
        key: :circt_bin,
        env: "CIRCT_BIN",
        doc: "the directory of the CIRCT 1.160.0 binaries (hlstool, mlir-opt)",
        find: fn -> if p = System.find_executable("hlstool"), do: Path.dirname(p) end
      }
    ]
  end

  @doc "Every setting of the project: elixir-hls' and its target's."
  def settings(project), do: own() ++ project.target.settings()

  @doc "A setting's value and where it came from (`:env`, `:config`, `:user`, `:found`), or `{nil, nil}`."
  def lookup(%{} = s) do
    finders = [
      env: fn -> System.get_env(s.env) end,
      config: fn -> Application.get_env(:elixir_hls, s.key) end,
      user: fn -> user_config()[s.key] end,
      found: fn -> if f = s[:find], do: f.() end
    ]

    Enum.find_value(finders, {nil, nil}, fn {from, f} ->
      case f.() do
        v when v in [nil, ""] -> nil
        v -> {expand(v), from}
      end
    end)
  end

  @doc "A setting's value by key, or nil."
  def get(project, key) do
    case Enum.find(settings(project), &(&1.key == key)) do
      nil -> nil
      s -> s |> lookup() |> elem(0)
    end
  end

  @doc "A setting's value; raises, saying where it looked, when it is not set."
  def get!(project, key) do
    s = Enum.find(settings(project), &(&1.key == key)) || raise ArgumentError, "no machine setting #{inspect(key)}"

    case lookup(s) do
      {nil, nil} ->
        Mix.raise("""
        #{s.env} is not set: #{s.doc}.
        Looked in: the environment (#{s.env}), config :elixir_hls, #{s.key}: (config/local.exs), \
        #{user_config_path()}#{if s[:find], do: ", the machine", else: ""}.
        Set it in one of them (e.g. config/local.exs: config :elixir_hls, #{s.key}: "..."); mix ehls.doctor shows all.
        """)

      {v, _} ->
        v
    end
  end

  @doc "The environment for a target's scripts: each setting that is set, as its variable."
  def env(project) do
    for s <- settings(project), {v, _} = lookup(s), v != nil, do: {s.env, v}
  end

  @doc """
  The user's cache, shared by every application of the machine: what the flash holds (`EHLS.Flash`) and what a
  target sets up once (`mix ehls.setup`). `~/.cache/ehls` on Linux; another directory with `EHLS_CACHE_DIR`.
  """
  def cache_dir do
    System.get_env("EHLS_CACHE_DIR") || :filename.basedir(:user_cache, ~c"ehls") |> to_string()
  end

  @doc "The user's config file."
  def user_config_path do
    System.get_env("EHLS_USER_CONFIG") || Path.join(System.user_home!(), ".config/ehls/config.exs")
  end

  defp user_config do
    path = user_config_path()
    if File.regular?(path), do: Config.Reader.read!(path) |> Keyword.get(:elixir_hls, []), else: []
  end

  defp expand("~" <> _ = p), do: Path.expand(p)
  defp expand(v) when is_binary(v), do: v
  defp expand(v), do: to_string(v)
end
