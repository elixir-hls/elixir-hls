defmodule EHLS.GPIO do
  @moduledoc ~S"""
  Pins read and written from Elixir: generic, knowing no board; a block package of the LiteX SoC
  backend (FPGA side: `priv/backend/litex/ehls_gpio.py`).

  Not everything between the CPU and the FPGA is a stream. An LED or a switch has only a current
  value, which a later value simply overwrites, so it needs no instance and no process:
  `EHLS.GPIO` is a package whose pins are read and written with plain function calls. What must not
  be lost, such as a button press, is an event: a pin's changes published by an instance (below).

  ```elixir
  use EHLS, blocks: [{EHLS.GPIO,
    out:   [relay: "j5:3"],
    in:    [door: {"j5:4", pull: :up}],
    inout: [sda: {"j5:5", pull: :up}],
    board: [:led0, :button0]}]

  EHLS.GPIO.write(:relay, 1)
  EHLS.GPIO.read(:door)
  EHLS.GPIO.direction(:sda, :out)    # inout only, while running
  ```

  - **Direction:** decides the circuit at synthesis. Only an `inout` has a tristate buffer and can
    change direction while running. It starts as an input, driving nothing; a `write` meanwhile
    is kept for when it turns to an output.
  - **Options per pin** (`{pin, options}`): `pull: :up | :down | :none` (a pin constraint, fixed at
    build time) and `active_low: true` (values inverted at the pin, so that 1 means on).
  - **`board:`** names the target's parts. Their pins, pulls and polarity come from the target
    (`EHLS_BOARD_GPIO`, a JSON file), so application code does not depend on the board.
  - **Errors:** options that cannot be built stop the compile; so does a call with a literal name
    that cannot work (`mix ehls.compile`). At run time a call returns `{:error, reason}`.
  - **Events:** a pin's changes are published by an instance, each edge with its exact kind and the time
    it came (`EHLS.Pipeline`, "Events"):

    ```elixir
    definstance door do
      changes(:door, :both) |> EHLS.PubSub.broadcast(:door)
    end

    EHLS.PubSub.subscribe(:door, timestamps: true)   # {:door, 1 | 0, t} for each edge
    ```

    A mechanical switch bounces, so one press can bring several events: debounce in the instance
    (`sample` below), or take them with `active: :once`.
  - **In an instance:** `changes(pin, edge)` (`:rising`, `:falling`, `:both`) is a source: one value per
    edge, the pin's new level, without the CPU. An edge arriving before the next function in the pipe took the last
    value is not counted, and a mechanical switch's bounces are edges. `hold(name)`, a built-in block,
    keeps the latest value as a level, read with `f(:value, name)`; it is 0 from reset or `:start` until
    the first value. Together, a counter of button presses in the FPGA:

    ```elixir
    defhls count(_press :: u1, n :: u16) :: {u16, u16} do
      {n + 1, n + 1}
    end

    definstance presses do
      changes(:button0, :rising) |> transform(0, &count/2) |> hold(:count)
    end

    presses(:value, :count)
    ```

  - **Reading a switch:** `sample(pin)` reads the pin's level at each value of the stream, so with a slow
    source the bounces are not seen, and an ordinary function decides what a press is. `pin_out(pin)`
    puts the low bit of the latest value on an `:out`, 0 from each start until the first value; the pin
    is then no more the CPU's to write, and a literal `write` to it stops `mix ehls.compile`.

    ```elixir
    definstance presses do
      ticks(1000) |> sample(:button0) |> transform({0, 0}, &debounce/2) |> transform(0, &count/2) |> pin_out(:led1)
    end
    ```

  - **A pin's level as an argument:** in a `definstance`, `EHLS.GPIO.read(pin)` as an argument of a function
    placed in the stream is the pin's level, read when the function takes a value (`EHLS.Pipeline`,
    "Instances of levels"); an out pin gives what is written to it.

    ```elixir
    defhls gate(x :: s16, on :: u1) :: s16 do
      if on == 1, do: x, else: 0
    end

    definstance gated(words) do
      words |> map(&gate(&1, EHLS.GPIO.read(:button0)))
    end
    ```

  - **Limits:** one module declares the pins, 32 pins at most. Calls from Elixir are slow compared
    with the circuit: a bus at speed belongs in a block with its own circuit.

  A sample application: [`gpio_demo.ex`](https://github.com/elixir-hls/atomvm-tang25k-hls/blob/main/examples/lib/gpio_demo.ex)
  in atomvm-tang25k-hls, the board's LEDs and buttons, and
  [`button_counter.ex`](https://github.com/elixir-hls/atomvm-tang25k-hls/blob/main/examples/lib/button_counter.ex), a counter of button presses with `debounce`.
  """
  @behaviour EHLS.Blocks
  import Bitwise

  # generated for the application (the runtime backend)
  @compile {:no_warn_undefined, :hw_kernels}

  # at most this many pins: a 32-bit register holds one bit per pin
  @max_pins 32
  @dirs [:out, :in, :inout]

  @impl true
  def soc, do: :litex

  @impl true
  # in the FPGA: changes(pin, edge), a source of one word per edge of the pin; sample(pin), the
  # pin's level read at each word of the stream; pin_out(pin), the low bit of the latest word
  # on an output
  def blocks, do: %{changes: {:source, 2}, sample: {:block, 1}, pin_out: {:sink, 1}}

  @impl true
  def types, do: %{changes: {nil, :u1}, sample: {:any, :u1}, pin_out: {:any, nil}}

  @impl true
  def check_stage(:changes, [name, edge], table) do
    case table[name] do
      nil -> bad("changes: no pin #{inspect(name)} (#{table |> Map.keys() |> Enum.join(", ")})")
      [_bit, "out"] -> bad("changes: #{inspect(name)} is an output")
      _ -> :ok
    end

    unless edge in [:rising, :falling, :both], do: bad("changes: edge #{inspect(edge)} (:rising, :falling or :both)")
    :ok
  end

  def check_stage(:sample, [name], table) do
    if table[name] == nil, do: bad("sample: no pin #{inspect(name)} (#{table |> Map.keys() |> Enum.join(", ")})")
    :ok
  end

  def check_stage(:pin_out, [name], table) do
    case table[name] do
      nil -> bad("pin_out: no pin #{inspect(name)} (#{table |> Map.keys() |> Enum.join(", ")})")
      [_bit, "out"] -> :ok
      _ -> bad("pin_out: #{inspect(name)} is not an output")
    end
  end

  @impl true
  # a pin a pipeline drives is no more the CPU's to write
  def stage_table(:pin_out, [name], table) do
    [bit, "out"] = table[name]
    %{name => [bit, "stage"]}
  end

  def stage_table(_block, _args, _table), do: %{}

  @impl true
  def peripherals, do: []

  @impl true
  def gateware, do: "ehls_gpio"

  @impl true
  def registers do
    %{out_set: :w, out_clr: :w, oe_set: :w, oe_clr: :w, in: :r}
  end

  @impl true
  # the options as `pins`: [%{name, bit, dir, pin, pull, active_low, board}], in bit order;
  # raises on what cannot be built
  def options(opts) do
    case Keyword.keys(opts) -- [:board | @dirs] do
      [] -> :ok
      other -> bad("unknown option(s) #{inspect(other)} (out:, in:, inout:, board:)")
    end

    own =
      for dir <- @dirs, {name, spec} <- Keyword.get(opts, dir, []) do
        {pin, popts} =
          case spec do
            {pin, popts} when is_list(popts) -> {pin, popts}
            pin -> {pin, []}
          end

        pin_map(name, dir, pin, popts, false)
      end

    pins = own ++ board_pins(Keyword.get(opts, :board, []))
    for {key, what} <- [name: "name", pin: "pin"], do: unique!(pins, key, what)
    if length(pins) > @max_pins, do: bad("at most #{@max_pins} pins")

    pins =
      pins
      |> Enum.with_index()
      |> Enum.map(fn {p, bit} -> Map.put(p, :bit, bit) end)

    %{pins: pins}
  end

  @impl true
  # name => {bit, direction}, for the generated `:hw_kernels.data/2`
  def table(%{pins: pins}), do: Map.new(pins, &{&1.name, {&1.bit, &1.dir}})

  defp pin_map(name, dir, pin, popts, board) do
    unless is_atom(name) and is_binary(pin), do: bad("#{inspect(name)}: a name and a pin (string) expected")

    case Keyword.keys(popts) -- [:pull, :active_low] do
      [] -> :ok
      other -> bad("#{name}: unknown option(s) #{inspect(other)} (pull:, active_low:)")
    end

    pull = Keyword.get(popts, :pull, :none)
    unless pull in [:up, :down, :none], do: bad("#{name}: pull: #{inspect(pull)} (:up, :down or :none)")
    if dir == :out and pull != :none, do: bad("#{name}: an output takes no pull")

    %{name: name, dir: dir, pin: pin, pull: pull, active_low: Keyword.get(popts, :active_low, false) == true, board: board}
  end

  # the target's parts by name (EHLS_BOARD_GPIO, from the target's scripts; else, as in the compile on the host, the
  # application's target among its dependencies, EHLS.Target)
  defp board_pins([]), do: []

  defp board_pins(names) do
    file =
      case System.get_env("EHLS_BOARD_GPIO") do
        v when v in [nil, ""] ->
          t = EHLS.Target.find()

          (t && function_exported?(t, :board_gpio, 0) && t.board_gpio()) ||
            bad("board: #{inspect(names)}: this target describes no parts (EHLS_BOARD_GPIO)")

        v ->
          v
      end

    parts = file |> File.read!() |> JSON.decode!()

    for name <- names do
      case parts[Atom.to_string(name)] do
        nil ->
          bad("board: no part #{inspect(name)} on this target (#{Enum.join(Map.keys(parts), ", ")})")

        part ->
          dir = String.to_existing_atom(part["dir"])
          popts = [pull: String.to_existing_atom(part["pull"] || "none"), active_low: part["active_low"] == true]
          pin_map(name, dir, part["pin"], popts, true)
      end
    end
  end

  defp unique!(pins, key, what) do
    case Enum.map(pins, & &1[key]) |> then(&(&1 -- Enum.uniq(&1))) do
      [] -> :ok
      dup -> bad("the same #{what} twice: #{inspect(dup)}")
    end
  end

  defp bad(msg), do: raise(ArgumentError, "EHLS.GPIO: " <> msg)

  # -- on the CPU; within what AtomVM runs --

  @doc "Sets an `:out` or `:inout` pin to 0 or 1: `:ok`, or `{:error, reason}`."
  def write(name, value) when value in [0, 1] do
    case lookup(name) do
      {:error, _} = error -> error
      {_bit, :in} -> {:error, {:input_pin, name}}
      {_bit, :stage} -> {:error, {:driven_by_pipeline, name}}
      {bit, _dir} -> reg_write(if(value == 1, do: :out_set, else: :out_clr), 1 <<< bit)
    end
  end

  @doc "The pin's level, 0 or 1 (of an `:out`: the value written), or `{:error, reason}`."
  def read(name) do
    case lookup(name) do
      {:error, _} = error -> error
      {bit, _dir} -> reg_read(:in) >>> bit &&& 1
    end
  end

  @doc "Turns an `:inout` pin into an `:out` or `:in`: `:ok`, or `{:error, reason}`."
  def direction(name, dir) when dir in [:in, :out] do
    case lookup(name) do
      {:error, _} = error -> error
      {bit, :inout} -> reg_write(if(dir == :out, do: :oe_set, else: :oe_clr), 1 <<< bit)
      {_bit, _dir} -> {:error, {:not_inout, name}}
    end
  end

  defp lookup(name) do
    case :hw_kernels.data(:ehls_gpio, name) do
      :undefined -> {:error, {:no_pin, name}}
      entry -> entry
    end
  end

  defp reg_write(reg, value), do: runtime().reg_write(:hw_kernels.reg(:ehls_gpio, reg), value)
  defp reg_read(reg), do: runtime().reg_read(:hw_kernels.reg(:ehls_gpio, reg))
  defp runtime, do: :hw_kernels.runtime()



  # -- at build time --

  @calls [write: 2, read: 1, direction: 2]

  @impl true
  # calls with a literal name that cannot work
  def check_sources(files, table) do
    table = Map.new(table, fn {k, [bit, dir]} -> {String.to_atom(k), {bit, String.to_atom(dir)}} end)
    for file <- files, msg <- check_source(file, File.read!(file), table), do: msg
  end

  @doc false
  def check_source(file, source, table) do
    {_, found} =
      source
      |> Code.string_to_quoted!(file: file, columns: false)
      |> Macro.prewalk([], fn
        {{:., _, [{:__aliases__, _, mod}, f]}, meta, [name | rest]} = node, acc
        when mod in [[:EHLS, :GPIO], [:GPIO]] and is_atom(name) ->
          msg = {f, length(rest) + 1} in @calls && check_call(f, name, rest, table)
          {node, if(msg, do: [{file, meta[:line], msg} | acc], else: acc)}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(found)
  end

  defp check_call(f, name, rest, table) do
    case {f, table[name]} do
      {_, nil} -> "EHLS.GPIO.#{f}: no pin #{inspect(name)} (#{table |> Map.keys() |> Enum.join(", ")})"
      {:write, {_, :in}} -> "EHLS.GPIO.write: #{inspect(name)} is an input"
      {:write, {_, :stage}} -> "EHLS.GPIO.write: #{inspect(name)} is driven by a pipeline (pin_out)"
      {:direction, {_, dir}} when dir != :inout -> "EHLS.GPIO.direction: #{inspect(name)} is not an inout"
      _ -> rest_error(f, rest)
    end
  end

  defp rest_error(:write, [v]) when is_integer(v) and v not in [0, 1], do: "EHLS.GPIO.write: value #{v} (0 or 1)"
  defp rest_error(_, _), do: nil
end
