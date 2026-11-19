# Elixir HLS — design

English | [日本語](design.ja.md)

How an Elixir function becomes a circuit, inside. It assumes Elixir and the basics of
digital circuits (clocks, registers, combinational logic); what can be written is in the
reference (`EHLS.defhls/2`, `EHLS.Pipeline`).

## The whole flow

![From Elixir to a circuit: elixirc writes each defhls function's MLIR and .sig besides its CPU function; mix ehls.compile runs mlir-opt, sink_constants.py, hlstool --dynamic-hw, pipeline_buffers.py (with the device backend's delay model), hlstool --verilog and prefix_modules.py to the kernel's SystemVerilog, gen_space.py writes its address space; every kernel is simulated against its CPU function; definstance and use EHLS give the description gen_manifest.py collects for the SoC and runtime backends](images/compile_flow.svg)

Four steps; calling from the CPU comes last:

1. While Elixir compiles, each `defhls` function is written as MLIR.
2. `mix ehls.compile` turns the MLIR into circuits (SystemVerilog) with CIRCT.
3. Every circuit is simulated against its Elixir function.
4. The instances become a description for the SoC and runtime backends.

## 1. From an Elixir function to MLIR

`defhls` (lib/ehls.ex; its work in lib/ehls/compiler.ex) is a macro. From a function definition it makes two things:

- **The CPU function:** the body, kept as an Elixir function, with the arguments and the
  result cut to their declared widths. A circuit holds values only in the widths declared,
  so the CPU computes in the same widths and both give the same results.
- **Processed at the end of the module:** `defhls` and `definstance` only note the definition, and `@before_compile` does the work, to bring a
  function's clauses together and make callees before their callers.
- **`case`, `cond`, several clauses:** for the circuit they become nested `if`s on the AST (`lib/ehls/syntax.ex`). The CPU function stays as written.
- **Expanding calls:** a call of another `defhls` is replaced by its body on the AST, before the translation to MLIR (`lib/ehls/inline.ex`).
  Arguments and result go through `signed` / `unsigned`, variables get names per call. Constants stay constants, so shifts and table reads by
  them are still wiring after the expansion.
- **The circuit's source:** with `EHLS_OUT_DIR` set at compile time, the body translated to
  MLIR in `<kernel>.mlir` (`EHLS.MLIR`), and its types, state, levels and memories as JSON in
  `<kernel>.sig`, which the later steps and the target read to know the kernel's inputs and
  outputs.

MLIR, a project of LLVM, is a framework for building compilers' intermediate
representations, with "dialects" (sets of operations) for different purposes. Elixir HLS uses
only standard ones: `func`, `arith`, `cf` and `memref`. Arithmetic and bit operations are
`arith`; an `if` without a loop inside computes both sides and selects (`arith.select`),
loops and the `if`s around them are branches of `cf`; memories and tables are `memref`.

Widths follow from the operations: `+` widens by one bit, `*` to the sum of both widths, so
that nothing overflows on the way; the function's result is then cut to its declared type,
as the CPU function does.

## 2. From MLIR to a circuit (CIRCT)

CIRCT, built on MLIR, is a compiler infrastructure for circuits. Elixir HLS makes the circuits
with its `hlstool --dynamic-hw`. In this style (dynamic scheduling) every value carries valid
and ready signals and moves when its receiver is ready: a function with loops and branches
becomes a working circuit without deciding beforehand what is computed in which clock, at
the cost of the handshake logic.

`mix ehls.compile` (priv/hls_compile.sh) takes each kernel through:

1. **`mlir-opt --canonicalize --cse`:** MLIR's standard clean-up: constant folding, repeated
   computations removed.
2. **`sink_constants.py`:** the clean-up moves all constants to the function's start; in a
   dynamically scheduled circuit a constant used after a loop is then carried through the
   loop like a variable, on every iteration. The constants go back next to their uses.
3. **`hlstool --dynamic-hw`:** to a handshake circuit (still as MLIR).
4. **`pipeline_buffers.py`:** where a handshake circuit has no register (buffer), a value
   passes the combinational logic within one clock; a long path misses the clock. CIRCT
   buffers either almost nothing or every channel: with the first a de-emphasis filter
   became 28 levels of logic and missed 50 MHz, the second costs a great many registers. So
   the delay of each operation is estimated, and buffers go only where a path exceeds the
   budget; the estimates and the budget come from the device backend (`EHLS.Device`,
   `DELAY_MODEL` / `PIPE_BUDGET`). The loop buffers are made one slot deep as well, for fewer
   clocks per iteration.
5. **`hlstool --verilog`:** written out as SystemVerilog.
6. **`prefix_modules.py`:** CIRCT names its helper modules after their operations, the same in
   every kernel, so they collide when one SoC holds several kernels; they get the kernel's
   name as a prefix.

A kernel's tables and memories become one address space module (`<kernel>_space.v`,
gen_space.py), because `hlstool` of CIRCT 1.160 handles one memory (memref) per kernel. Its
reads come out one clock later, so that the FPGA tools can use block RAM.

## 3. The simulation check

Every kernel is simulated with iverilog and compared with its CPU function (gen_tb.py,
gen_stream_tb.py), on edge values (0, the largest values, around the sign) and random
inputs; a kernel with state gets one stream from its initial state, restarted once halfway.
A single difference stops the build. The inputs and the testbenches in detail: the documentation of
`mix ehls.compile` (`mix help ehls.compile`).

The CPU function is the specification, so a circuit that passes has been shown to do what
the specification says.

## 4. Instances and the description for the target

`definstance` (lib/ehls/compiler.ex, lib/ehls/pipeline.ex) maps each stage to a `defhls` function of the module or to
a block (`EHLS.Blocks`). `chunk_every(n, k, :discard) |> map(&f/1)` becomes one kernel, with
a ring buffer of the last n items and a counter: the first chunk once n have come, then one every k.

- **An instance of values** (arguments with types, lib/ehls/level.ex) is one kernel of its body, behind
  hls_level_adapter.v: the CPU writes the arguments' words, a start write takes them all in one clock, and the
  result is held with the count of the start it is for.
- **An instance of streams** is built as a graph from its body: every join made explicit
  (`zip_with(a, b, &f/2)`, lib/ehls/join.ex), each pipe between joins made stages, the joins and the forks (a stream
  named and used twice) linked between them. A function placed with levels (`map(&f(&1, k_hw(:value)))`)
  becomes a generated kernel of one argument, its levels wired. A join is the compiler's block `hw__zip` (then a
  generated kernel of the pair), a fork `hw__fork`; another instance called in it is a `call` stage.
- **A function with its state** is placed where it is written with `transform(init, &f/2)`: a kernel made there,
  `f__s…`, its second argument the state, in registers behind hls_state_adapter.v, loaded with `init` at the start.
  A tuple in the state is registers too, `elem` / `put_elem` with a variable index selects. Placed with
  `memory: [:hist]`, the tuple `hist` (lib/ehls/tuple_state.ex) becomes a memory argument of a kernel `f__m_hist`:
  `elem` its reads, `put_elem`'s writes done at the end of the step, after every read of it, and the rest of the state
  the kernel's state. The memory is a region of the kernel's memory space (priv/gen_space.py), zero-filled at the start.
  Named, `transform(..., memory: [:hist], name: :f)`, the CPU reads the state whole with `inst(:state, :f)`: the values
  as any named state's (peek), each memory word by word through the memory space's CPU port (the SoC's `mem_addr` /
  `mem_data`, first in its next clock, the kernel waiting that one clock), each word as it is when read.
- **An agent** (`EHLS.Agent`) is one register (hls_litex.py `Agent`) its functions' adapters share (`SHARED`): each
  takes the state in and gives its next value, one function at a time, in turn among those that have an element.

The instance's structure goes into `.pipeline` (JSON): its stages; the links between them, each with its kind, type,
and the input of the stage it goes into (`port`) and the output it comes from (`from_port`, a fork's); its inputs
from the CPU, each with the stage it goes into; its output (`output_from`); for an instance of values, `level`. The
peripherals of `use EHLS, peripherals: [...]` go into `.peripherals`.

priv/gen_manifest.py then collects them, with every kernel's `.sig`, into kernels.json,
pipelines.json, packages.json and peripherals.json. There the description is put together across modules: the
kernels' levels wired to instances of levels or pins, an instance called in another wired to it (`wired`: its
input and output no CPU ends), each checked (in the build, the types, called once, no loops). It numbers the
instances of levels, the state words (a `hold` stage's word among them), the CPU ends and the packages' registers. The SoC backend builds the SoC from this description; the runtime backend
generates what the CPU side needs to call the circuits by the same numbers (AtomVM: the Erlang
module `hw_kernels` with the indices).

## 5. The CPU ends

An instance's argument, and a stream left at its end, are its CPU ends. What the design turns on is that **a transfer goes on
after its NIF has returned**: meanwhile a garbage collection can move the calling process's heap, and other processes must keep
running.

- **Circuit (`CPUIn`, `CPUOut` in hls_litex_blocks.py):** one LiteDRAM DMA engine per end. The engines share one crossbar port to
  read and one to write (`SharedPort`), taking turns per command, so the crossbar does not grow with the ends. An engine only
  asks for what it can finish (a reader has reserved room for the data, a writer already holds it), so an end standing still,
  a slow source or an output nobody reads, holds up no other; a FIFO of whose each command was routes the data. A signal
  `finished` says it is over: for an input when the last word has left the DMA, for an output when the last word has gone
  towards the SDRAM. `done` (all read requests issued) is too early for an input, as disabling the DMA flushes its FIFO. `buffer:` is
  a block RAM FIFO before the output's DMA.
- **Interrupt and message (src/hwstream_nif.c):** `finished` rising is an event per end, on one interrupt. The interrupt only hands
  over to the system work queue, which sends the message (as the event queue does). The work reads `finished` again, so that a late
  interrupt of a cancelled transfer is not taken for the next one.
- **Memory:** an output goes into a refc binary the driver holds, handed over in the message. An input stays in place if it is a refc
  binary, aligned and in SDRAM, with one more reference; anything else (small, a literal in flash, misaligned) is copied first. The
  CPU's D-cache is write-through, so only an invalidate is needed after an output's transfer.
- **The next transfer:** while one is in flight an end takes one more (`end_send`, `end_request`), which the interrupt's work
  starts as soon as the first is done, so a stream goes on without waiting for the program; beyond that the answer is busy.
- **One element without DMA (`f(:send, :x, v)`):** its packed words go into the input end's small FIFO (`end_push`), in front of
  the DMA, from the NIF itself; no message follows.
- **Events:** the publishers' events go into one queue in the FPGA, in order, with their times. Its interrupt drains it into a
  ring in the NIF, and the work queue sends each event to its topic's subscribers (up to 4 per topic): every one, or with
  `active:` the next n, the ones after kept (16 at most) until asked again.
- **Calls that wait (lib/ehls.ex):** `f(bin)` and the like are Elixir code asking for the same transfers and waiting in a `receive`, so only
  the calling process waits. On a timeout they cancel and drop what may be on its way.

When stopping, a kernel finishes the element it has begun, its outputs dropped: otherwise that element would come out after the start, from
the old state. Once the kernels have let go, the links and the buffer are emptied.

## 6. On the CPU

An instance placed on the CPU (`on: :cpu`, or no FPGA) is not a circuit:

- **An instance on the CPU (lib/ehls/cpu_instance.ex):** a process, registered under the instance's key, that holds each
  function's state between calls and runs the functions over the list it is given. A `ticks` source runs on a timer.
- **As machine code (`cpu: :nif`):** the functions run as C instead of Elixir. lib/ehls/nif.ex writes each kernel's C
  from its MLIR (`mix ehls.compile --target cpu`, checked against the function on the host); the runtime backend
  builds them into the NIFs `hwnif` (src/ehls_nif.c), and `EHLS.NIFRun` cuts a long input into chunks so that the
  VM's other processes keep running between calls.
- **One function of an instance on the CPU (`map(&f/1, on: :cpu)`, lib/ehls/cpu_stage.ex):** the instance is cut there:
  the part before becomes `<name>__pre`, a circuit ending in a CPU end, the part after `<name>__post`, a circuit
  starting at one, and `EHLS.CpuDriver` (a process) takes the stream from the one, through the function's NIF, to the
  other. Its levels are read by the driver before each batch.
- **EHLS.Server (lib/ehls/server.ex):** a GenServer owning an instance: it starts and stops it with the application,
  calls it for its callers in turn, and hands the events of its topics on to any number of processes.

## Backends

What depends on the hardware is in three kinds of backends: device, SoC and runtime.

| kind | backend | module | files (priv/backend/) | what it does |
|---|---|---|---|---|
| device | `generic` | `EHLS.Device.Generic` | — | delay estimates and budget for pipeline_buffers.py |
| device | `gowin_gw5a` | `EHLS.Device.GowinGW5A` | gowin/ | delay estimates and budget; check_timing.py (Gowin's timing report), gowin_litex.py (LiteX toolchain settings for Gowin, the constraint for a pin's pull) |
| SoC | `litex` | `EHLS.SoC.LiteX` | litex/ | hls_litex.py: instances with registered links (a FIFO before a time-multiplexed kernel), instances of levels, levels wired into kernels and state through CSRs (`hwstream_*`), the block packages' Python modules; built-in blocks in hls_litex_blocks.py (`EHLS.SoC.LiteX.Blocks`); `EHLS.GPIO`'s circuit in ehls_gpio.py |
| runtime | `atomvm` | `EHLS.Runtime.AtomVM` | atomvm/ | the `:hwstream` NIFs (src/hwstream_nif.c) and their stubs, the CSR headers (gen_csr_header.py), `hw_kernels.erl` (gen_hw_kernels.py); needs `litex` |

`EHLS.Backend` picks one of each kind per build (`EHLS_DEVICE` / `EHLS_SOC` / `EHLS_RUNTIME` or
the config) and checks that they combine; `use EHLS` also checks that every block
package is for the SoC backend in use. Without a runtime backend (the default) `defhls` /
`definstance` generate only the CPU functions.
