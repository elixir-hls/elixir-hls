defmodule EHLS.Backend do
  @moduledoc ~S"""
  The hardware abstraction layer: the backends a build uses, one of each kind.

    * device (`EHLS.Device`): the FPGA family; acts inside the compile (buffers, delay model).
    * SoC (`EHLS.SoC`): how the circuits are built into a system on chip (control bus, DMA,
      the built-in blocks); `nil` for circuits only.
    * runtime (`EHLS.Runtime`): what the generated functions call on the CPU; `nil` for the
      CPU only (no hardware clauses are generated).

  Chosen at compile time from the environment (`EHLS_DEVICE`, `EHLS_SOC`, `EHLS_RUNTIME`: a
  backend's short name, `none`, or a module name) or else from the application's config:

      config :elixir_hls, device: EHLS.Device.GowinGW5A, soc: EHLS.SoC.LiteX,
        runtime: EHLS.Runtime.AtomVM

  Defaults: the generic device, no SoC, no runtime. Each backend says what it combines with
  (`c:EHLS.Runtime.socs/0`, a block package's `c:EHLS.Blocks.soc/0`); `check!/0` stops a
  combination that does not fit.

  ## The backends

  What depends on the hardware is in three kinds of backends; a build uses one of each.

  | kind | acts | backends |
  |---|---|---|
  | device (`EHLS.Device`) | inside the compile: where buffers go in a circuit, from the FPGA's estimated delays and a budget | `generic` (default), `gowin_gw5a` (plus the timing check `check_timing.py` and LiteX toolchain settings) |
  | SoC (`EHLS.SoC`) | builds the circuits into a SoC: control bus, DMA, blocks | none (default), `litex` (`hls_litex.add_hls(soc, hw_dir, package_dirs)`) |
  | runtime (`EHLS.Runtime`) | what the generated functions call on the CPU to use the hardware | none (default: CPU only, no clauses that call the hardware), `atomvm` (`:hwstream` NIFs, needs `litex`) |

  They are chosen at compile time by `EHLS_DEVICE`, `EHLS_SOC`, `EHLS_RUNTIME` (a short name,
  `none` or a module name) or `config :elixir_hls, device: ..., soc: ..., runtime: ...`; a
  combination that does not fit (AtomVM without LiteX, say) stops the compile. Each backend's
  Python, C and Erlang files are in `priv/backend/<name>`.

  ## Files a target gets

  For those writing a target. `mix ehls.compile --out DIR [--with FILE]... FILE...` writes to
  `DIR/hw`:

  | file | contents |
  |---|---|
  | `<kernel>.sv` | a CIRCT `--dynamic-hw` module: inputs `in0..` (the argument's values, the state's, the level arguments, the memory space, a start token), outputs `out0..` (the result's values, the next state's, a done token), each with valid / ready |
  | `<kernel>_space.v` | the kernel's tables and memories (one address space module) |
  | `<kernel>.sig` | JSON: types, state and its initial value, the arguments after the first (`args`, each with its `kind`), whether the output is a list (`emit`), memories; a state holding memories its parts in order (`shape`) |
  | `kernels.json`, `pipelines.json`, `peripherals.json`, `packages.json` | the kernels, the instances (each stage a kernel or a block with its package's gateware), the peripherals, the packages (their options, registers with their numbers, and tables) |

  and what the runtime backend generates, if there is one (AtomVM: `DIR/gen/hw_kernels.erl`,
  the instance / CPU end / state / level indices, a package's registers by `reg/2` and its table by
  `data/2`, the runtime's module by `runtime/0`).

  A kernel module is awkward to put on a stream as it is, so `priv/verilog/` has adapters
  around it: `hls_stream_adapter.v` (a kernel without state, one element in, one out) and
  `hls_state_adapter.v` (state in registers, tuples, a list as the output). Both connect through valid / ready /
  data streams (an element moves in a clock where valid and ready are both 1), with one clock and a
  synchronous reset.

  With a runtime backend the generated functions call its module (`EHLS.runtime/0`; AtomVM:
  `:hwstream`): `pipe_enable(instance, on)`,
  `level_start(level, pipeline, words)` (an instance of levels: its arguments' words, then the start; the count of that start or `:stopped`), `peek(stage, words)`, `mem_read(stage, addr, count)` (a named state's memory, word by word), `end_send/5`, `end_request/5`, `end_cancel/1` (a transfer on a CPU end,
  ending in a message), `end_push(end, pipeline, words)` (one element without DMA: `:ok`, `:full` or `:stopped`), and a block package's
  registers `reg_read(reg)`, `reg_write(reg, value)` (`registers/0` of `EHLS.Blocks`).
  """

  @known %{
    device: %{"generic" => EHLS.Device.Generic, "gowin_gw5a" => EHLS.Device.GowinGW5A},
    soc: %{"litex" => EHLS.SoC.LiteX},
    runtime: %{"atomvm" => EHLS.Runtime.AtomVM}
  }

  @env %{device: "EHLS_DEVICE", soc: "EHLS_SOC", runtime: "EHLS_RUNTIME"}

  @doc "The device backend (a module implementing `EHLS.Device`)."
  def device, do: get(:device) || EHLS.Device.Generic

  @doc "The SoC backend (`EHLS.SoC`), or nil."
  def soc, do: get(:soc)

  @doc "The runtime backend (`EHLS.Runtime`), or nil."
  def runtime, do: get(:runtime)

  @doc "The three backends; raises when they do not combine."
  def check! do
    {d, s, r} = {device(), soc(), runtime()}

    # the CPU target (EHLS_TARGET=cpu, mix ehls.compile --target cpu) makes no circuit, so no SoC
    if r && r.socs() != [] && System.get_env("EHLS_TARGET") != "cpu" && (s == nil or s.name() not in r.socs()),
      do:
        raise(
          ArgumentError,
          "HLS: the runtime #{inspect(r)} needs a SoC backend of #{inspect(r.socs())}, not #{inspect(s)}"
        )

    {d, s, r}
  end

  @doc false
  # a backend by short name, "none", or module name; from the environment, else the config
  def get(kind) do
    case System.get_env(@env[kind]) do
      v when v in [nil, ""] -> Application.get_env(:elixir_hls, kind)
      "none" -> nil
      v -> resolve(kind, v)
    end
  end

  defp resolve(kind, v) do
    m =
      Map.get_lazy(@known[kind], v, fn ->
        if v =~ ~r/^[A-Z]/ or String.starts_with?(v, "Elixir."),
          do: Module.concat([String.replace_prefix(v, "Elixir.", "")]),
          else:
            raise(
              ArgumentError,
              "#{@env[kind]}=#{v}: one of #{Enum.join(Map.keys(@known[kind]) ++ ["none"], ", ")} or a module"
            )
      end)

    Code.ensure_loaded(m)
    m
  end

  @doc "The directory of a backend's files (Python, C, Erlang) in elixir-hls' `priv/backend`."
  def priv(name), do: Path.join([to_string(:code.priv_dir(:elixir_hls)), "backend", name])
end

defmodule EHLS.Device do
  @moduledoc """
  A device backend: the FPGA family. It acts inside the compile: the buffers cut a kernel's
  combinational paths where its estimated delay exceeds the budget (priv/pipeline_buffers.py).
  """

  @doc "The short name (`EHLS_DEVICE`)."
  @callback name() :: String.t()

  @doc "Delay budget in ns per register stage (`PIPE_BUDGET` overrides it)."
  @callback budget() :: number()

  @doc """
  The delay model, ns: `"shift"` / `"add"` / `"mul"` (`[base, per bit]`; shifts by a constant
  are wires), `"logic"`, `"select"`, `"div_per_bit"`, `"other"` (one number each).
  """
  @callback delay_model() :: map()

  @doc false
  # the rough model used so far: carry chains grow with the width, multipliers are slow
  def default_model do
    %{
      "shift" => [1.5, 0.1],
      "logic" => 0.6,
      "select" => 0.8,
      "add" => [1.2, 0.05],
      "mul" => [7.0, 0.1],
      "div_per_bit" => 4.0,
      "other" => 1.0
    }
  end
end

defmodule EHLS.SoC do
  @moduledoc """
  A SoC backend: builds the circuits (`<out>/hw`: kernels.json, pipelines.json,
  packages.json, peripherals.json) into a system on chip with its control bus and DMA, and
  provides the blocks every SoC of its kind has. Its build code lives in
  `priv/backend/<name>` (`EHLS.Backend.priv/1`).
  """

  @doc "The short name (`EHLS_SOC`); block packages name it in `c:EHLS.Blocks.soc/0`."
  @callback name() :: atom()

  @doc "The block packages every module gets (`EHLS.Blocks`), e.g. a `ticks` source."
  @callback blocks() :: [module()]
end

defmodule EHLS.Runtime do
  @moduledoc """
  A runtime backend: what the generated functions call on the CPU to use the hardware.

  The generated code calls `module()`: `pipe_enable(pipeline, on)`, `level_start(level, pipeline, words)`,
  `peek(stage, words)`, `mem_read(stage, addr, count)`, an instance's CPU ends `end_send/5`, `end_request/5`, `end_cancel/1`, `end_push/3`,
  `pack(list, layout)` and `unpack(binary, layout)` (as `EHLS.pack/2` and `EHLS.unpack/2`), and block
  packages `reg_read(reg)`, `reg_write(reg, value)` (`c:EHLS.Blocks.registers/0`), with indices
  from the generated module `:hw_kernels` that `generate/1` writes (`runtime/0` there names
  `module()`, `reg/2` and `data/2` serve the packages). The behaviour assumes no
  particular VM: a call may block, be served by a process or go through Linux.
  """

  @doc "The short name (`EHLS_RUNTIME`)."
  @callback name() :: atom()

  @doc "The module the generated functions call."
  @callback module() :: module()

  @doc "The SoC backends it works with (their names); `[]`: any."
  @callback socs() :: [atom()]

  @doc "Writes what the application needs at run time (e.g. `<out>/gen/hw_kernels.erl`) from `<out>/hw`."
  @callback generate(out :: Path.t()) :: :ok

  @doc "For `--target cpu`: writes the NIF kernels' table and index (e.g. `<out>/gen/ehls_nif_kernels.c`) from `<out>/cpu`."
  @callback generate_nif(out :: Path.t()) :: :ok

  @optional_callbacks generate_nif: 1
end
