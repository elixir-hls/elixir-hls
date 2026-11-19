defmodule EHLS.Build do
  @moduledoc """
  A build that knows what changed: a target's steps (`c:EHLS.Target.steps/1`) run in order, each only when its inputs
  changed since it last ran, or an output is missing.

  A step's inputs are files (globs, relative to the application's directory or absolute) and values (options it is
  built with); their hash is kept in `build/.ehls/<step>.sha256` once the step succeeds. A later step's inputs are
  often an earlier one's outputs, so a change runs only what it reaches: a change of the CPU's code remakes the
  circuits' files the same as before, and the SoC after them does not run again.
  """

  @typedoc """
  A step: its name, what it does (for the messages), its inputs (`inputs:` globs, `exclude:` regexes on their
  paths, `values:` any term), the files it makes (`outputs:`), the machine's settings it needs (`needs:`, checked
  before it runs) and the function that runs it.
  """
  @type step :: %{
          required(:name) => atom,
          required(:run) => (-> any),
          optional(:doc) => String.t(),
          optional(:inputs) => [String.t()],
          optional(:exclude) => [Regex.t()],
          optional(:values) => term,
          optional(:outputs) => [Path.t()],
          optional(:needs) => [atom]
        }

  @doc """
  Runs the steps that need it. Options: `only:` (step names: those alone), `force:` (run them whatever changed),
  `dry_run:` (say what would run, run nothing). Returns the names of the steps run (or that would run).
  """
  def run(project, steps, opts \\ []) do
    only = opts[:only]

    case only && only -- Enum.map(steps, & &1.name) do
      [_ | _] = unknown ->
        Mix.raise("no step #{Enum.map_join(unknown, ", ", &to_string/1)}; the steps: #{Enum.map_join(steps, ", ", & &1.name)}")

      _ ->
        :ok
    end

    {ran, _} =
      Enum.reduce(steps, {[], false}, fn s, {ran, earlier?} ->
        if only && s.name not in only do
          {ran, earlier?}
        else
          case {reason(project, s, opts), opts[:dry_run]} do
            {nil, true} when earlier? ->
              info("#{s.name}: decided after the steps before it")
              {ran, earlier?}

            {nil, _} ->
              info("#{s.name}: up to date")
              {ran, earlier?}

            {why, true} ->
              info("#{s.name}: would run (#{why})")
              {[s.name | ran], true}

            {why, _} ->
              for key <- s[:needs] || [], do: EHLS.Machine.get!(project, key)
              info("== #{s.name}#{if s[:doc], do: ": " <> s.doc, else: ""} (#{why})")
              s.run.()

              for o <- s[:outputs] || [], not File.exists?(abs(project, o)),
                  do: Mix.raise("#{s.name}: ran but did not make #{o}")

              write_stamp(project, s)
              {[s.name | ran], true}
          end
        end
      end)

    Enum.reverse(ran)
  end

  @doc "Why a step has to run, or nil when it is up to date."
  def reason(project, s, opts \\ []) do
    stamp = stamp_path(project, s)

    cond do
      opts[:force] -> "--force"
      not File.exists?(stamp) -> "first build"
      o = Enum.find(s[:outputs] || [], &(not File.exists?(abs(project, &1)))) -> "#{o} missing"
      File.read!(stamp) != hash(project, s) -> "inputs changed"
      true -> nil
    end
  end

  @doc "The hash of a step's inputs (files and values)."
  def hash(project, s) do
    files =
      for g <- s[:inputs] || [],
          f <- Path.wildcard(abs(project, g), match_dot: false),
          File.regular?(f),
          not Enum.any?(s[:exclude] || [], &Regex.match?(&1, f)),
          uniq: true,
          do: f

    acc =
      Enum.reduce(Enum.sort(files), :crypto.hash_init(:sha256), fn f, acc ->
        acc |> :crypto.hash_update(Path.relative_to(f, project.root)) |> :crypto.hash_update(<<0>>)
        |> :crypto.hash_update(File.read!(f)) |> :crypto.hash_update(<<0>>)
      end)

    acc
    |> :crypto.hash_update(:erlang.term_to_binary(s[:values]))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp write_stamp(project, s) do
    path = stamp_path(project, s)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, hash(project, s))
  end

  defp stamp_path(project, s), do: Path.join([project.build, ".ehls", "#{s.name}.sha256"])

  defp abs(project, p), do: Path.expand(p, project.root)

  defp info(msg), do: Mix.shell().info(msg)

  @doc """
  Runs a command for a step, its output shown as it comes; raises when it fails. Options: `cd:`, `env:`
  (a list of `{name, value}`).
  """
  def cmd!(command, args, opts \\ []) do
    {_, status} =
      System.cmd(command, args,
        cd: opts[:cd] || File.cwd!(),
        env: opts[:env] || [],
        into: %EHLS.Build.Out{},
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("#{Path.basename(command)} #{Enum.join(args, " ")} failed (status #{status})")
    :ok
  end
end
