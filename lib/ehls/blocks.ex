defmodule EHLS.Blocks do
  @moduledoc """
  A package of blocks for `definstance` (sources, sinks, fixed stream functions in
  the FPGA) and of SoC peripherals, e.g. a board's I/O, for one SoC backend (`soc/0`). A
  module of the package implements this behaviour; an application names it in
  `use EHLS, blocks: [...]` (the SoC backend's built-in ones, `c:EHLS.SoC.blocks/0`, come
  along):

      defmodule MyApp do
        use EHLS, blocks: [EHLS.USBHost, {EHLS.I2S, pins: [dout: "j5:7"]}, EHLS.RPiDisplay35],
          peripherals: [:lcd]

        definstance radio do
          usb_bulk_in() |> ... |> i2s_out()
        end
      end

  The FPGA side of a package (`gateware/0`) is what its SoC backend builds, in the form that
  backend documents (e.g. `EHLS.SoC.LiteX`); the application's options to the package
  (`use EHLS, blocks: [{Pkg, pins: [...]}]`) go to it. A package used with another SoC
  backend than its own stops the compile.
  """

  @typedoc """
  kind: :source (first stage, gives a stream), :block (stream in and out), :sink (last stage, takes
  a stream) or :level (last stage, takes a stream and keeps a level, e.g. `hold`)
  """
  @type block :: {:source | :block | :sink | :level, arity :: non_neg_integer()}

  @doc "The SoC backend the package is for (`c:EHLS.SoC.name/0`, e.g. `:litex`)."
  @callback soc() :: atom()

  @doc "The blocks: name => {kind, number of integer arguments}."
  @callback blocks() :: %{atom() => block()}

  @doc """
  The package's sources that can wait: a word stays until it is taken. A stream to the CPU from any
  other source needs `overflow: :drop`.
  """
  @callback waits() :: [atom()]

  @doc """
  What the package's blocks take and give: name => `{in, out}`, each a type (`:u8`, `{:s16, :s16}`), `:any` (takes every type) or
  `nil` (nothing). A block not named here works on `:u32`.
  """
  @callback types() :: %{atom() => {term(), term()}}

  @doc "The SoC peripherals an application can ask for with `use EHLS, peripherals: [...]`."
  @callback peripherals() :: [atom()]

  @doc "The package's gateware, as its SoC backend names it."
  @callback gateware() :: String.t()

  @doc """
  The package's registers the CPU reads and writes: name => `:r` or `:w`. The runtime reaches
  them by number (`:hw_kernels.reg(gateware, name)`, the runtime's `reg_read/1`, `reg_write/2`),
  so that a simple block needs no code of its own in the VM. The SoC backend says what a name
  is in its circuit (LiteX: the CSR `<gateware>_<name>`).
  """
  @callback registers() :: %{atom() => :r | :w}

  @doc """
  The application's options to the package checked and put in the form its gateware gets;
  raises on what cannot be built. Without it they go as they are.
  """
  @callback options(keyword()) :: term()

  @doc """
  From those options, what the package looks up on the CPU: key => value, a tuple of integers
  and atoms or one of them (`:hw_kernels.data(gateware, key)`; `:undefined` for another key).
  """
  @callback table(term()) :: map()

  @doc """
  Problems in the application's sources that the compile cannot see, e.g. calls that cannot
  work: `[{file, line, message}]`. `table` is the package's table as in packages.json. They stop
  `mix ehls.compile`.
  """
  @callback check_sources(files :: [Path.t()], table :: map()) :: [{Path.t(), integer(), String.t()}]

  @doc """
  Checks a stage using one of the package's blocks, `name` and its literal arguments, given the
  package's table; raises `ArgumentError` on what cannot be built.
  """
  @callback check_stage(name :: atom(), args :: list(), table :: map()) :: any()

  @doc """
  What a stage using one of the package's blocks changes in the package's table: key => value.
  They go into packages.json, so `:hw_kernels.data/2` and `check_sources/2` see them.
  """
  @callback stage_table(name :: atom(), args :: list(), table :: map()) :: map()

  @optional_callbacks waits: 0, types: 0, registers: 0, options: 1, table: 1, check_sources: 2, check_stage: 3, stage_table: 3

  @doc false
  # every stage using a block of the packages checked by its package, if it does that
  def check_stages!(stages, packages, tables) do
    for %{block: block, args: args, gateware: gateware} = stage <- stages,
        p = Enum.find(defaults() ++ packages, &(&1.gateware() == gateware)),
        Code.ensure_loaded?(p) and function_exported?(p, :check_stage, 3) do
      EHLS.Error.at(stage[:line], fn ->
        p.check_stage(String.to_atom(block), args, Map.get(tables, gateware, %{}))
      end)
    end

    :ok
  end

  @doc false
  # the stages, those whose package says so with `table_update` for the description
  def stage_tables(stages, packages, tables) do
    for st <- stages do
      with %{block: block, args: args, gateware: gateware} <- st,
           p when p != nil <- Enum.find(defaults() ++ packages, &(&1.gateware() == gateware)),
           true <- Code.ensure_loaded?(p) and function_exported?(p, :stage_table, 3),
           update when update != %{} <- p.stage_table(String.to_atom(block), args, Map.get(tables, gateware, %{})) do
        Map.put(st, :table_update, update)
      else
        _ -> st
      end
    end
  end

  @doc false
  # the package's entry in the description (<module>.packages): its options for the gateware,
  # its registers and table
  def describe(package, options) do
    Code.ensure_loaded!(package)

    options =
      if function_exported?(package, :options, 1), do: package.options(options), else: options

    table = if function_exported?(package, :table, 1), do: package.table(options), else: %{}
    registers = if function_exported?(package, :registers, 0), do: package.registers(), else: %{}

    %{
      module: inspect(package),
      gateware: package.gateware(),
      options: json_options(options),
      registers: for({name, mode} <- Enum.sort(registers), do: %{name: name, mode: mode}),
      table: Map.new(table, fn {k, v} -> {k, json_entry(v)} end)
    }
  end

  defp json_entry(t) when is_tuple(t), do: Tuple.to_list(t) |> Enum.map(&json_entry/1)
  defp json_entry(a) when is_atom(a), do: Atom.to_string(a)
  defp json_entry(i) when is_integer(i), do: i

  @doc false
  # options (keyword lists, nested) as JSON-able maps; atoms as strings
  def json_options(o) when is_map(o), do: Map.new(o, fn {k, v} -> {k, json_options(v)} end)

  def json_options(o) when is_list(o) do
    if Keyword.keyword?(o) and o != [] do
      Map.new(o, fn {k, v} -> {Atom.to_string(k), json_options(v)} end)
    else
      Enum.map(o, &json_options/1)
    end
  end

  def json_options(a) when is_atom(a) and a not in [nil, true, false], do: Atom.to_string(a)
  def json_options(v), do: v

  @doc """
  The packages every module gets besides its own: the SoC backend's built-in blocks (none
  without a SoC backend).
  """
  def defaults do
    case EHLS.Backend.soc() do
      nil -> []
      soc -> soc.blocks()
    end
  end

  @doc false
  # raises unless every package is for the SoC backend in use (none: not checked)
  def check_soc!(packages) do
    with soc when soc != nil <- EHLS.Backend.soc() do
      for p <- packages, p.soc() != soc.name() do
        raise ArgumentError,
              "use EHLS: #{inspect(p)} is for the SoC backend #{inspect(p.soc())}, this build uses #{inspect(soc.name())}"
      end
    end

    :ok
  end

  @doc false
  # name => {kind, arity, gateware} over the given packages (the defaults first; a later
  # package wins over an earlier one with the same block name)
  def table(packages) do
    for p <- defaults() ++ packages, {name, {kind, arity}} <- p.blocks(), into: %{} do
      {name, {kind, arity, p.gateware()}}
    end
  end

  @doc false
  # name => {in, out} of the blocks that say, as types
  def types(packages) do
    for p <- defaults() ++ packages, Code.ensure_loaded?(p), function_exported?(p, :types, 0),
        {name, {in_, out}} <- p.types(), into: %{} do
      {name, {EHLS.block_type(in_), EHLS.block_type(out)}}
    end
  end

  @doc false
  # can this source of the packages wait until it is read?
  def waits?(packages, name) do
    Enum.any?(defaults() ++ packages, fn p ->
      Code.ensure_loaded?(p) and function_exported?(p, :waits, 0) and name in p.waits()
    end)
  end

  @doc false
  # [{name, gateware}] for the peripherals asked for; raises on one no package provides
  def peripherals(packages, names) do
    for name <- names do
      case Enum.find(packages, &(name in &1.peripherals())) do
        nil ->
          raise ArgumentError,
                "use EHLS: no package in #{inspect(packages)} provides the peripheral #{inspect(name)}"

        p ->
          {name, p.gateware()}
      end
    end
  end
end
