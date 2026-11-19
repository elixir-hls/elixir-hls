defmodule EHLS.SoC.LiteX do
  @moduledoc """
  The LiteX SoC backend (`priv/backend/litex`). A target's SoC script puts the circuits of
  `<out>/hw` into its LiteX SoC with

      sys.path.insert(0, os.path.join(elixir_hls, "priv", "backend", "litex"))
      import hls_litex
      hls_litex.add_hls(soc, hw_dir, package_dirs)

  which adds `soc.hwstream`:

    * each instance its stages linked by registered streams, running from reset (a CSR bit
      stops it), its ends towards the CPU a LiteDRAM DMA engine each; a kernel's
      level arguments wired to instances of levels or pins; instances of levels; the state of named stages
      readable word by word;
    * the blocks and peripherals of the block packages (their `gateware/` Python modules,
      `EHLS.Blocks`), configured with the application's options.

  CSRs: `hwstream_*` (the AtomVM runtime's NIFs use them). Built-in blocks:
  `EHLS.SoC.LiteX.Blocks`.

  A block package for LiteX (`EHLS.Blocks`, `soc/0` = `:litex`) has its gateware as a Python
  module (`gateware/0`) in the package's `gateware/` directory with `BLOCKS` (name -> LiteX
  module class, built as `cls(soc, enable, *args)`, with a `sink` and / or `source` stream
  endpoint, 32-bit data; optionally `source_width` / `source_signed`), `PERIPHERALS`
  (name -> function `f(soc)` adding it to the SoC) and optionally `configure(options)`,
  called first with the options the application gives the package (as a dict), and optionally
  `add_to_soc(soc)`, adding a circuit that is no pipeline stage. Its registers
  (`c:EHLS.Blocks.registers/0`) are the CSRs `<gateware>_<name>`: the module added as
  `soc.<gateware>`. `EHLS.GPIO` is such a package, in this backend (`priv/backend/litex/ehls_gpio.py`).
  """
  @behaviour EHLS.SoC

  @impl true
  def name, do: :litex

  @impl true
  def blocks, do: [EHLS.SoC.LiteX.Blocks]
end

defmodule EHLS.SoC.LiteX.Blocks do
  @moduledoc """
  The blocks every LiteX SoC of elixir-hls has (`priv/backend/litex/hls_litex_blocks.py`),
  independent of the board:

    * `ticks(rate)`: a source of one word (its running count) `rate` times per second;
    * `run()`: a sink taking the words and doing nothing with them, for a stream whose stages'
      state is all that matters;
    * `hold(name)`: a sink keeping the latest word as a level, read with
      `pipeline(:value, name)`; 0 from each start until the first word;
    * `EHLS.PubSub.broadcast(topic)`: a sink making each element an event of the topic (an atom), received by
      `EHLS.PubSub.subscribe(topic)`; it never holds back what feeds it (an event that does not fit is
      counted); an element is one value up to 32 bits;
    * `EHLS.PubSub.subscribe(topic)`: a source giving the events of the topic, every one of each publisher in
      its order; a source that cannot wait (what does not fit while it stands still is counted), so a
      stream from it to the CPU says `overflow: :drop`.
  """
  @behaviour EHLS.Blocks

  @impl true
  def soc, do: :litex

  @impl true
  def blocks, do: %{ticks: {:source, 1}, run: {:sink, 0}, hold: {:level, 1}, broadcast: {:sink, 1}, subscribe: {:source, 1}}

  @impl true
  def waits, do: [:ticks]

  @impl true
  def types, do: %{ticks: {nil, :u32}, hold: {:any, nil}, run: {:any, nil}, broadcast: {:any, nil}, subscribe: {nil, nil}}

  @impl true
  def peripherals, do: []

  @impl true
  def gateware, do: "hls_litex_blocks"

  @impl true
  def check_stage(:hold, [name], _table) when is_atom(name) and name not in [nil, true, false], do: :ok
  def check_stage(:hold, args, _table), do: raise(ArgumentError, "definstance: hold(name), a name as an atom, got #{inspect(args)}")
  def check_stage(:broadcast, [topic], _table) when is_atom(topic) and topic not in [nil, true, false], do: :ok
  def check_stage(:broadcast, args, _table), do: raise(ArgumentError, "definstance: EHLS.PubSub.broadcast(topic), a topic as an atom, got #{inspect(args)}")
  def check_stage(:subscribe, [topic], _table) when is_atom(topic) and topic not in [nil, true, false], do: :ok
  def check_stage(:subscribe, args, _table), do: raise(ArgumentError, "definstance: EHLS.PubSub.subscribe(topic), a topic as an atom, got #{inspect(args)}")
  def check_stage(_block, _args, _table), do: :ok
end
