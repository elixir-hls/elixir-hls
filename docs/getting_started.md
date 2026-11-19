# Getting started

From a function written in Elixir to placing it in the FPGA and calling it from Elixir on the CPU: the call returns
what the FPGA's circuit computed. First one value at a time, then many values as a stream. Before the board, the same
circuits are checked in simulation on your computer.

It runs on an FPGA board that Elixir HLS supports; the board supported today is the Sipeed Tang Primer 25K. Elixir HLS
keeps what depends on the hardware apart, as backends (`EHLS.Backend`), so a backend made for the board you want
to use lets you use that one too. This guide uses the Tang Primer 25K.

## 1. What you need

**To make the circuits and check them on your computer:**

- Elixir 1.18 or later, and python3.
- Icarus Verilog, the simulator: `sudo apt install iverilog` on Ubuntu / Debian, `brew install icarus-verilog` on macOS.
- Two programs of CIRCT 1.160.0, the LLVM project's compiler for circuits: `hlstool` and `mlir-opt`. The release is over
  1 GB; this takes only the two (Linux, x86-64):

```sh
mkdir -p ~/tools/circt-1.160.0/bin
curl -fsSL https://github.com/llvm/circt/releases/download/firtool-1.160.0/circt-full-static-linux-x64.tar.gz |
  tar -xz -C ~/tools/circt-1.160.0/bin --strip-components=2 --wildcards '*/bin/hlstool' '*/bin/mlir-opt'
export CIRCT_BIN=~/tools/circt-1.160.0/bin      # also in your shell profile
```

**To run on the board:**

- A Sipeed Tang Primer 25K with its Dock and the SDRAM module.
- The Gowin IDE, openFPGALoader, and a Zephyr workspace with its SDK.
- For the board's base, [atomvm-tang25k](https://github.com/elixir-hls/atomvm-tang25k) (its LiteX SoC and AtomVM):
  Erlang/OTP with rebar3, cmake, ninja and gperf. The base itself comes with the project and is set up by
  `mix ehls.setup` (section 2).

## 2. A project

The generator of a new project, `mix ehls.new`, is installed once. It is an archive that needs nothing else:

```sh
mix archive.install hex ehls_new
```

Then:

```sh
mix ehls.new first_kernel         # for the Tang Primer 25K (--target tang25k, the default)
cd first_kernel
mix deps.get
mix ehls.setup                    # once for the machine: the board's base (LiteX, AtomVM; some tens of minutes)
```

`mix ehls.setup` keeps what it sets up in `~/.cache/ehls`, one per version of the base, so the projects of the
machine share it; a project of the same version later finds it set up.

The project's `mix.exs` has the Tang Primer 25K target as its dependency, and the target brings Elixir HLS along. The
project also has an example, `lib/first_kernel.ex` with its test (`mix test`), and a README with the steps to the
board. This guide writes its own module beside the example.

## 3. Functions

`lib/first.ex`:

```elixir
defmodule First do
  use EHLS

  # the larger of the two 16-bit halves, times three
  defhls larger(x :: u32) :: u32 do
    a = x &&& 0xFFFF
    b = x >>> 16
    if a > b, do: a * 3, else: b * 3
  end

  defhls plus_one(x :: u32) :: u32 do
    x + 1
  end

  defhls larger_plus_one(x :: u32) :: u32 do
    plus_one(larger(x))
  end
end
```

Each takes one value and gives one value; `larger_plus_one` calls the other two. A type such as `u32` (unsigned, 32
bits) is the width of the circuit's value.

A function written with `defhls` is an ordinary Elixir function too. In `iex -S mix`:

```elixir
iex> First.larger(0x0002_0005)
15
iex> First.larger_plus_one(0x0002_0005)
16
```

## 4. Placing it in the FPGA

`defhls` defines a function; a definition alone puts no circuit in the FPGA. `definstance` places a function in it,
as an actual circuit. Add to `First`:

```elixir
  definstance larger_plus_one_hw(x :: u32) do
    larger_plus_one(x)
  end
```

An instance whose argument has a type takes a value and gives a value. On the CPU, `larger_plus_one_hw(0x0002_0005)`
writes the argument to the circuit, the circuit computes, and the call returns what it computed. The result stays
held in the circuit until the next call, and `larger_plus_one_hw(:value)` reads it again.

What to compute is written with `defhls`, and a `definstance` places that function: that is the usual way.

## 5. Checking before the board

This runs on the host PC you develop on (no board).

First call the instance placed on the host PC and look at the result. With no board, the instance runs on the host PC, as
Elixir functions:

```elixir
iex> First.larger_plus_one_hw(0x0002_0005)
16
iex> First.larger_plus_one_hw(:value)
16
```

Then make the circuits and check in simulation that they give what the functions give:

```sh
mix ehls.compile lib/first.ex     # on the host PC
mix ehls.sim lib/first.ex         # on the host PC
```

`mix ehls.compile` makes each function's circuit in SystemVerilog with CIRCT and runs it in iverilog against the
function. The test is made for you: the inputs are edge values and random ones, and what is expected is what the same
function gives when Elixir runs it (the details: `mix help ehls.compile`). `mix ehls.sim` checks what is placed, as the
CPU uses it: it calls the instance with random values, some calls before the last one is done, and checks each result
held. Among the lines it ends with:

```
RESULT first_larger_plus_one_hw__level: vectors=2011 errors=0 latency=2..2   First.larger_plus_one_hw__level (u32 -> u32, 0 state words)
RESULT larger_plus_one_hw[0..0]: calls=2000 held=1603 errors=0
```

`errors=0`: the circuit gave what the function gives. A circuit that does not match stops the command there.

## 6. On the board

The board's CPU runs AtomVM, and an application starts at `start/0`, as AtomVM's applications do. Add to `First`:

```elixir
  def start do
    IO.inspect(larger_plus_one_hw(0x0002_0005))
    IO.inspect(larger_plus_one_hw(:value))
  end
```

In `config/config.exs`, make `First` the module that starts on the board:

```elixir
config :elixir_hls, target: :tang25k, start: First
```

`mix ehls.run` builds the circuits into the system on the FPGA (the SoC), writes it to the board and runs it:

```sh
mix ehls.doctor      # once: what this machine has, what is missing
mix ehls.run         # the circuits (checked, as mix ehls.compile), the SoC (Gowin, a few minutes), AtomVM for it,
                     # the application; then sent to the board and run, its console shown
```

The console shows what the board's circuit computed, the same as `larger_plus_one` gave on the CPU in section 3:

```
16
16
```

`mix ehls.run` builds only what changed since the last time: after a change of `start/0` alone it builds the
application again and not the SoC. Where the Gowin IDE is on this machine, if it is not found,
goes into `config/local.exs` (`mix ehls.doctor` says which). If the SoC misses the timing,
`deps/atomvm_tang25k_hls/scripts/sweep_soc.sh` looks for a placement that meets it. If a run fails right after a
power-on or a flash write, run it again.

## 7. Many values: a stream

When values come one after another (sound samples, a sensor read at a steady rate), the circuit takes them as a
stream: each value goes through the function in turn, and the next one comes in while it is still computing. An
argument without a type is a stream; `map(&f/1)` takes each value through `f`. Add to `First`:

```elixir
  defhls scale(x :: u32, k :: u8) :: u32 do
    x * k
  end

  # a value the CPU sets: k_hw(10) makes it 10
  definstance k_hw(k :: u8), initial: 1 do
    k
  end

  # each value through larger_plus_one, then times what k_hw holds
  definstance many_hw(words) do
    words |> map(&larger_plus_one/1) |> map(&scale(&1, k_hw(:value)))
  end
```

`many_hw` places the same `larger_plus_one`, and joins `scale` to it with the pipe (`|>`), as anywhere in Elixir.
`scale`'s `k` is wired to `k_hw`'s value: in a `definstance`, `k_hw(:value)` is the wire to it, as the same
expression reads it on the CPU. A list goes in and a list comes out:

```elixir
  def start do
    IO.inspect(larger_plus_one_hw(0x0002_0005))
    IO.inspect(larger_plus_one_hw(:value))
    IO.inspect(many_hw([0x0002_0005, 1, 0x0001_0000]))
    k_hw(10)
    IO.inspect(many_hw([0x0002_0005, 1, 0x0001_0000]))
  end
```

Run it again (`mix ehls.run`):

```
16
16
[16, 4, 4]
[160, 40, 40]
```

Each element of the list went through the circuits one by one; after `k_hw(10)` the same stream comes out ten times
larger. A binary can be given instead of a list, and a binary comes back.

## Next

- [How Elixir HLS works](concepts.md): `defhls` and `definstance`, values, what can become hardware, streams (joining
  two, using one twice, instances in instances), talking to the CPU, events, the FPGA or the CPU (where an instance
  runs; a function of an instance on the CPU).
- The reference, in the modules' documentation: `EHLS.defhls/2` (what a function can be written with: the types, the
  expressions, functions with state, memories, levels), `EHLS.Pipeline` (instances, calling them from the CPU),
  `EHLS.Stream` (the functions an instance joins), `EHLS.Agent`, `EHLS.PubSub` (events), `EHLS.Server`, `EHLS.GPIO`,
  `EHLS.Backend`.
- [atomvm-tang25k-hls](https://github.com/elixir-hls/atomvm-tang25k-hls): the board's scripts, timing, examples. A small example of pins:
  [`gpio_demo.ex`](https://github.com/elixir-hls/atomvm-tang25k-hls/blob/main/examples/lib/gpio_demo.ex), the board's LEDs and buttons.
- [atomvm-fm-radio](https://github.com/elixir-hls/atomvm-fm-radio): a working example, an FM stereo receiver whose whole
  demodulator is written in Elixir and runs in the FPGA.
