# elixir-hls

English | [日本語](README.ja.md)

Elixir HLS makes FPGA circuits from functions written in Elixir: high-level synthesis (HLS).

## High-level synthesis

FPGA circuits are usually written in a hardware description language such as Verilog or
VHDL, register by register: which value goes into which register at which clock. This is
called RTL (register transfer level). High-level synthesis generates that RTL from code in a
software language: the author says what to compute, and the tool decides the clocks and the
registers.

In Elixir HLS that language is Elixir. A function defined with `defhls` stays an ordinary
Elixir function that runs on the CPU, and also becomes an FPGA circuit. Each circuit is
simulated against its Elixir function and used only if the results match, so the Elixir
function is the circuit's specification. Why it is built this way: [vision](docs/vision.md).

## Status

Elixir HLS 0.1.0 is its first release, an early one: it synthesizes integer functions, with state, tables, memories and fixed loops,
and instances joining them with streams, levels and events, in the FPGA or on the CPU; its first target is the
Sipeed Tang Primer 25K with AtomVM, and its working example the FM radio
([atomvm-fm-radio](https://github.com/elixir-hls/atomvm-fm-radio)), whose whole demodulator runs in the FPGA. Not there
yet, among others: division, floats, recursion, and of Elixir's streams what needs the whole collection.

## Example

```elixir
defmodule KernelDemo do
  use EHLS

  defhls stream_kernel(x :: u32) :: u32 do
    a = signed(x &&& 0xFFFF, 16)
    b = signed(x >>> 16, 16)
    if a > b, do: a * 3 + b, else: a + b * 2
  end
end

KernelDemo.stream_kernel(123)        # => 369 (computed on the CPU)
```

`stream_kernel` takes a 32-bit value, compares its low and high 16 bits as signed numbers and
computes its result depending on which is larger. Given an integer, it computes on the CPU,
as an Elixir function. How the same function runs as a circuit in the FPGA:
[On a board](#on-a-board).

A type such as `u32` (unsigned, 32 bits) is the circuit's bit width. A circuit spends wiring
and logic on every bit, so narrower widths make it smaller and faster. On the CPU the values
are cut to the same widths, so the CPU and the circuit compute the same results.

```sh
mix ehls.compile --out build lib/kernel_demo.ex
```

`mix ehls.compile` turns each `defhls` function of the files into a SystemVerilog circuit and
then simulates every circuit against its function; it stops at a circuit that does not
match.

## Elixir and Elixir HLS

### What can be written

What can be written with `defhls` (a function, which runs both on the CPU and as a circuit) and `definstance` (an
instance: functions placed as circuits), beside Elixir. ✗: not in Elixir HLS. Details:
[How Elixir HLS works](docs/concepts.md), `EHLS.defhls/2`, `EHLS.Pipeline`, `EHLS.Stream`.

**Values and types** (`defhls`)

| | Elixir | Elixir HLS |
|---|---|---|
| Integers | `integer()` (of any size) | `u8`, `s16` and so on (`u` unsigned, `s` signed, the number the bits, 1 to 64); beyond the width they wrap |
| Types | `@spec f(integer()) :: integer()` (may be left out) | `defhls f(x :: u8) :: u16` (always written) |
| Tuples | `{integer(), integer()}` | `{u8, s16}`; of one type also `tuple(s16, 32)` |
| Floats | `float()` | ✗ |
| Atoms, strings, maps | `atom()`, `String.t()`, `map()` | ✗ |
| Lists | `[integer()]` | ✗ (from the CPU an instance is called with a list) |
| Tables of constants | `Enum.at(@t, i)` | The same (a table in the circuit) |

**Defining a function** (`defhls`)

| | Elixir | Elixir HLS |
|---|---|---|
| Definition | `def f(x) do ... end` | `defhls f(x :: u8) :: u8 do ... end` (an Elixir function too) |
| Operators | `+ - *`, `Bitwise`, `== <`, `and or not` | The same |
| Division | `div`, `rem`, `/` | ✗ |
| Choices | `if`, `case`, `cond`, clauses and guards | The same (the last clause matches everything) |
| Calls | `g(x)` | Of `defhls` of the same module only (a circuit for each place of a call) |
| for loops | `for k <- 0..15, reduce: acc do ... end` | The same (a constant range; one circuit used again) |
| reduce | `Enum.reduce(0..15, acc, fn k, acc -> ... end)` | The same (a constant range; as many circuits side by side) |
| Tuples in the state | `elem(t, i)`, `put_elem(t, i, v)` | The same (registers in the circuit; the FPGA's memory with `transform`'s `memory:`) |
| Recursion | `def f(n), do: f(n - 1)` | ✗ |
| Anonymous functions | `fn x -> x + 1 end` | ✗ |
| Exceptions, messages, I/O | `raise`, `receive`, `IO.puts` | ✗ |

**Functions on streams**

| | Elixir | Elixir HLS |
|---|---|---|
| map | `Stream.map(&f/1)` | `EHLS.Stream.map(&f/1)` (the module may be left out: `map(&f/1)`) |
| filter | `Stream.filter(&f/1)` | `EHLS.Stream.filter(&f/1)` |
| transform | `Stream.transform(0, &f/2)` | `EHLS.Stream.transform(0, &f/2)` (`f` a `defhls` function) |
| zip_with | `Stream.zip_with(a, b, &f/2)` | `EHLS.Stream.zip_with(a, b, &f/2)` |
| chunk_every | `Stream.chunk_every(32, 4, :discard)` | `EHLS.Stream.chunk_every(32, 4, :discard)` (gives tuples of 32; Elixir gives lists, so the types differ) |
| run | `Stream.run()` | `EHLS.Stream.run()` |
| At an interval | `Stream.interval(1)` | `ticks(1000)` (times per second) |
| More elements | `Stream.flat_map(fn x -> [x, x] end)` | ✗ |
| The whole collection | `Enum.sort()`, `Enum.take(n)` | ✗ |
| One stream after another | `Stream.concat(a, b)` | ✗ |

**Shared state and events** (`definstance`)

| | Elixir | Elixir HLS |
|---|---|---|
| A shared state | `Agent` | `EHLS.Agent` (how it differs: `EHLS.Agent`) |
| Events | `Phoenix.PubSub` | `EHLS.PubSub` (how it differs: `EHLS.PubSub`) |
| Making processes | `spawn`, `Task` | ✗ |

### What it adds to Elixir

`definstance` places functions as circuits (or, without an FPGA, as processes on the CPU), and gives an application new
things to call:

- **Calling an instance** is calling a function: `my_inst(x)` gives the result of the function placed, `my_inst(list)`
  (or a binary) a list of results; the calling process waits in a `receive`, the others go on. With messages instead:
  `my_inst(:send, :x, data)`, `my_inst(:request, :out, n)`; one element, without DMA, `my_inst(:send, :x, 5)`. Its
  state read: `my_inst(:state, n)`.
- **Using a value the CPU sets:** the CPU sets an instance of values (`definstance gain_hw(g :: u9)`, `gain_hw(12)`),
  and the circuit's functions take it as an argument (`map(&volume(&1, gain_hw(:value)))`). Its changes can be a stream
  too, an element each time it changes (`changes(gain_hw(:value))`).
- **Where it runs:** in the FPGA where there is one, else on the CPU, with the same calls; `on: :cpu | :fpga` says
  otherwise, also for one function of an instance.
- **Pins and devices in the circuit:** buttons' and sensors' pins, sound, USB, joined with the circuit's functions
  without the CPU. `changes(:button0, :rising) |> transform(0, &count/2) |> pin_out(:led0)` is a circuit counting the
  presses and putting the count's lowest bit on the LED (on and off at each press). Sound and USB are blocks of
  packages placed in a pipe (`x |> i2s_out()`, `usb_bulk_in()`). From the CPU, `EHLS.GPIO.read(:pin)` and
  `EHLS.GPIO.write(:pin, v)` read and write pins.
- **Testing:** the `defhls` functions are Elixir functions, and in `mix test` the instances run on the CPU; `mix
  ehls.compile` and `mix ehls.sim` check each circuit against its function.
- **An instance as a GenServer:** wrapped in `EHLS.Server`, an instance is handled as a GenServer (in a supervision
  tree, started with the application, its callers waiting their turn). How it differs from `GenServer`: `EHLS.Server`.

## Requirements

- Elixir 1.18 or later
- The CIRCT 1.160.0 release binaries (`hlstool` and `mlir-opt`). CIRCT, a project of LLVM, is
  a compiler infrastructure for circuits. Their directory goes into `CIRCT_BIN` (e.g.
  `export CIRCT_BIN=$HOME/tools/circt-1.160.0/bin` in the shell profile).
- python3
- Icarus Verilog (iverilog, tested 12.0), for the circuit simulations: `sudo apt install iverilog`
  on Ubuntu / Debian, `brew install icarus-verilog` on macOS

## An example program

A `defhls` function runs in the FPGA where a `definstance` places it. The simplest instance takes a value and gives a
value, called like a function from the CPU; an instance can also take a stream, values one after another, and run on
its own, with the data flowing from devices through the kernels without the CPU.

```elixir
defmodule InstanceDemo do
  use EHLS

  defhls stream_kernel(x :: u32) :: u32 do
    a = signed(x &&& 0xFFFF, 16)
    b = signed(x >>> 16, 16)
    if a > b, do: a * 3 + b, else: a + b * 2
  end

  # a value in, a value out: the CPU writes it, the circuit computes, the result is held
  definstance kernel_hw(x :: u32) do
    stream_kernel(x)
  end

  # a stream: the CPU's values through the kernel one after another, and back
  definstance accel(words) do
    words |> map(&stream_kernel/1)
  end

  # ticks gives a count 1,000 times a second, through the kernel, to the CPU
  definstance demo do
    ticks(1000) |> map(&stream_kernel/1)
  end
end

InstanceDemo.stream_kernel(0x0002_0001)       # 5, on the CPU
InstanceDemo.kernel_hw(0x0002_0001)           # 5, computed in the FPGA
InstanceDemo.accel([0x0002_0001])            # [5]: a stream, a list in, a list out
InstanceDemo.accel(<<1, 0, 2, 0>>)            # or a binary in, a binary out
InstanceDemo.demo(:out, 4)                    # takes 4 values
```

What comes next (what needs no board, the steps on a board): [Getting started](docs/getting_started.md).

## Documents

- [Getting started](docs/getting_started.md): from a function to the circuit on the board
- The reference, in the modules' documentation on HexDocs: `EHLS.defhls/2` (the types and expressions, state, memories,
  levels, loops, stream functions), `EHLS.Pipeline` (instances, levels, events and streams, calling from the CPU),
  `EHLS.Stream` (the functions an instance joins, as `Stream`'s), `EHLS.Agent` (one state for several lines), `EHLS.PubSub` (topics: events), `EHLS.GPIO` (pins), `EHLS.Server` (an instance as a GenServer), `EHLS.Backend` (choosing the backends, the files a target gets)
- [How Elixir HLS works](docs/concepts.md): `defhls` and `definstance`, values, what can become hardware, streams (joins, forks,
  instances in instances), talking to the CPU, events, the FPGA or the CPU, what happens until a read
- [Glossary](docs/glossary.md)
- This repository's tests: `mix test` (the MLIR and descriptions written, CPU semantics), `EHLS_TEST_CIRCT=1 mix test` (also every case through CIRCT and iverilog; minutes)
- [Vision](docs/vision.md): why, the layers, what is planned
- [Design](docs/design.md): how a function becomes a circuit, inside

`mix docs` builds these documents and the modules' documentation (the modules above, the backends and the mix tasks) as
HTML in `doc/`, as on HexDocs.

## License

Apache-2.0 (see [LICENSE](LICENSE)).
