# How Elixir HLS works

English | [日本語](concepts.ja.md)

How what you write with Elixir HLS runs on the FPGA, for those who know Elixir, with or without FPGA experience. The
steps are in [Getting started](getting_started.md); the lists of what can be written are in the modules' documentation
on HexDocs (`EHLS.defhls/2`, `EHLS.Pipeline`, `EHLS.Stream`, `EHLS.Agent`, `EHLS.PubSub`, `EHLS.Server`).

## 1. `defhls` and `definstance`

Elixir HLS has two definitions. What to compute is written with `defhls` as functions, and `definstance` places a
function in the FPGA as an actual circuit.

```elixir
defhls larger(x :: u32) :: u32 do              # a function's definition; it runs on the CPU too
  a = x &&& 0xFFFF
  b = x >>> 16
  if a > b, do: a * 3, else: b * 3
end

defhls plus_one(x :: u32) :: u32 do
  x + 1
end

defhls larger_plus_one(x :: u32) :: u32 do
  plus_one(larger(x))                          # a defhls calls others
end

definstance larger_plus_one_hw(x :: u32) do    # placed in the FPGA as a circuit; the CPU calls it
  larger_plus_one(x)
end
```

| | `defhls` | `definstance` |
|---|---|---|
| Is | the definition of a function that can become a circuit and runs on the CPU too | a function placed in the FPGA as a circuit |
| Circuit | not made | made |
| Holds | what to compute | the part made an actual circuit (which function is placed in the FPGA) |
| Parts with I/O | cannot be used (they cannot run on the CPU) | can be used |
| Called from the CPU | runs on the CPU as an Elixir function | gives the circuit its input and takes its result |

Parts with I/O are `i2s_out()`, `usb_bulk_in()` and the like.

Where there is no FPGA (on a computer, in `mix test`), an instance runs on the CPU instead, with the same calls and the
same results (section 10).

If you know an HDL, think of a module's definition and its instance.

An instance looks like a function but is not created per call. It is one circuit that keeps running, so what it holds
goes on across calls. It behaves much like one GenServer called by its registered name, except that the number of them
is fixed at synthesis.

## 2. Values

An instance whose arguments have types takes values and gives a value. It is the simplest thing to place, and the
basis of the rest.

```elixir
larger_plus_one_hw(0x0002_0005)     # 16: writes the argument, the circuit computes, the call returns its result
larger_plus_one_hw(:value)          # 16: the result held now, read again
```

- **What happens:** the CPU writes the argument into the circuit's registers, the circuit computes once, and the result
  is held in a register until the next call. The caller waits for the result of its own write (tens of microseconds at
  most in the circuit; a few milliseconds for the whole call on AtomVM).
- **Only the latest counts:** a value is something of which only its latest matters (a volume, a setting). A call made
  while the circuit computes waits for it; if several come, only the latest is computed. `f(v, wait: false)` writes
  and returns at once.
- **Before the first call:** the result is `initial:` (0 when not given): `definstance gain_hw(v :: u9), initial: 96`.
- **Wired:** inside a `definstance`, the expression that reads a value on the CPU is the wire to it. A function placed
  in another instance can take it as an argument, read when it takes each value (section 5):

  ```elixir
  definstance k_hw(k :: u8), initial: 1 do       # a value the CPU sets, given back as it is
    k
  end

  definstance many_hw(words) do
    words |> map(&scale(&1, k_hw(:value)))       # scale's k is k_hw's value
  end
  ```

  An instance of another module is written `Other.k_hw(:value)`; a pin's level, `EHLS.GPIO.read(:switch0)`.

## 3. What can become hardware

A circuit has a fixed size and its values are bits of fixed widths, so only part of Elixir can become a circuit. What
cannot stops the compile, with the file and the line.

**In a `defhls`:**

| Kind | What can be written |
|---|---|
| Types | `u1`..`u64` (unsigned), `s1`..`s64` (signed) and tuples of them; the argument and the result up to 64 bits |
| Expressions | `+ - *`, `&&& \|\|\| ^^^`, shifts, comparisons, `and or not`, tuples, `signed(x, n)` / `unsigned(x, n)` |
| Choices | `if`, `case`, `cond`, several clauses with patterns and guards (the last one matching everything) |
| Calls | other `defhls` of the module (expanded where called) |
| Loops | `for k <- a..b, reduce:` with a fixed range (one circuit used again) and `Enum.reduce(a..b, ...)` (unrolled) |
| Tables | `Enum.at(@t, i)` (a list of integers in a module attribute) |
| State | the second argument, `f(x :: t, s :: u16) :: {t, u16}`, returning `{output, next_state}`: the function `Stream.transform/3` takes |
| A missing output | the output a list of at most one, `{[y], s}` / `{[], s}`, typed `{[t], u16}` |
| Tuples in the state | `{pos, hist} :: {u8, tuple(s16, 256)}`: `elem(hist, i)`, the next state with `put_elem(hist, i, v)`; registers, or with `memory: [:hist]` where it is placed the FPGA's memory |
| Levels | plain arguments besides the stream, given where the function is placed: an instance of levels, `k_hw(:value)`, a pin, an integer |

**What cannot:** division (`div`, `rem`, `/`), floats, lists (except a missing output), maps, strings, atoms, functions of other modules (except
`Enum.reduce` over a range), a function calling itself, processes and messages. A state, a level or a memory is up to
32 bits.

**In a `definstance`:**

| Written | Means |
|---|---|
| `f(x :: t, ...)` as the head | an instance of values: the body one of the arguments, a tuple of them, or a call of a `defhls` |
| `f(x)` or `x \|> f()` | places a `defhls` function as it is; a stream function brings its whole pipe |
| `map(&f/1)`, `map(&f(&1, k_hw(:value)))` | in a pipe, places a function; its other arguments levels or integers |
| `transform(initial, &f/2)` | in a pipe, places a function with its second argument as the state; with `name: n` the CPU reads it |
| `{:ok, n} = EHLS.Agent.start_link(initial)`, `x \|> EHLS.Agent.get_and_update(n, &f/2)`, `x \|> EHLS.Agent.update(n, &f/2)` | one state for several lines, as `Agent` (section 8) |
| `chunk_every(n, k, :discard) \|> map(&f/1)` | a function of n elements, a chunk every k, as `Stream.chunk_every` (an FIR filter, say); `f(w :: tuple(t, n))` reads `elem(w, i)` |
| `run()` | ends a pipe kept for its state or its events, as `Stream.run` |
| `zip_with(a, b, &f/2)`, or `f(a, b)` with both streams | two streams into one function, one element of each (section 5) |
| `y = ...`, then `y` used twice | a stream named, and a fork (section 5) |
| `x \|> other_hw()` | another instance called: wired to it (section 5) |
| built-in blocks | `ticks(rate)` (a value at a steady rate), `hold(name)` (the latest value as a level), `run()` (takes and drops); the SoC backend's, so on a computer try them with `EHLS_SOC=litex` |
| devices | the board's parts: `i2s_out()`, `usb_bulk_in()`, `changes(pin, edge)`, `sample(pin)`, `pin_out(pin)`, ... |

The output of a function in the pipe and the input of the next one must agree in type; a narrowing that would change a
value stops the compile. The options are `initial:` (an instance of values), `buffer:` (how much gathers before the CPU
reads) and `overflow:` (what happens when it is full).

The rules in detail: `EHLS.defhls/2` (what a `defhls` can hold) and `EHLS.Pipeline` (what a `definstance` can place,
calling it from the CPU).

## 4. Streams

When values come one after another (sound samples, a sensor read at a steady rate, data from USB), the circuit takes
them as a stream: each value goes through the function in turn, and the next one comes in while the one before is
still computing. An instance's argument without a type is a stream, and `map(&f/1)` takes each value through `f`:

```elixir
definstance many_hw(words) do
  words |> map(&larger_plus_one/1)
end

many_hw([0x0002_0005, 1, 0x0001_0000])     # [16, 4, 4]: a list in, a list out
```

A placed function takes a stream and gives a stream, so between functions joined with the pipe there is a stream as
well.

An element of a stream is one value, or a tuple of values. To carry several values together as one element (the left
and right of stereo, say), make them a tuple: its values move in the same clock, and the function taking it gets them
all in one call.

To keep a value from one input to the next, place a function of the element and a state, which returns
`{output, next_state}`, with `transform(initial, &f/2)` instead of `map`, as with `Stream.transform/3`; the state sits in
the circuit's registers. The function itself holds nothing: on the CPU it is a plain function.

`ticks(1000)`, a built-in block, gives a count 0, 1, 2, ... (a `u32`) 1,000 times a second; a stream can start from it
or from the board's devices instead of from the CPU:

```elixir
definstance counter do
  ticks(1000) |> map(&larger_plus_one/1)
end
```

A pipe of functions can have a name of its own: a `defhls` taking a stream (a stream function). On the CPU it takes a
list and gives a list, so an ordinary test checks what it computes without making a circuit:

```elixir
defhls larger_plus_ones(x :: stream(u32)) :: stream(u32) do
  x |> map(&larger/1) |> map(&plus_one/1)
end

test "larger_plus_ones" do
  assert larger_plus_ones([0x0002_0005, 1]) == [16, 4]
end
```

## 5. Joining, forking, instances in instances

**Two streams into one function:** `zip_with(a, b, &f/2)` takes one element of each, together, as Elixir's
`Enum.zip_with` does. `f(a, b)` with both arguments streams is the same, and so is `a |> f(b)`:

```elixir
defhls mix(a :: s16, b :: s16) :: s17 do
  a + b
end

definstance mixer(left, right) do
  zip_with(left, right, &mix/2) |> map(&half/1)
end

mixer([1, 2, 3], [10, 20, 30])             # two lists in, one out
```

A join can be anywhere in the body, and its streams can come from arguments, from sources, or from other joins.

**One stream used twice:** `y = ...` names a stream, and a name used twice is a fork: every element goes to each
branch. Only the last expression goes to the CPU; one before it ends in something taking the stream away (a sink):

```elixir
definstance tapped(x) do
  y = x |> map(&smooth/1)
  y |> map(&low16/1) |> hold(:last)        # one branch into a sink
  y |> map(&scale(&1, 3))                  # the other, the instance's output
end
```

**An instance called inside an instance:** an instance exists once, so calling it in another wires to it: the stream
before goes into its input and its output comes out there, and neither is a CPU end. An instance of another
module is written `Other.fir_hw()`:

```elixir
definstance player(samples) do
  samples |> map(&gain/1) |> fir_hw() |> map(&clip/1)
end
```

## 6. How a stream flows

At most one element moves per clock, over a link as wide as the element's type. Two signals hand an element over: "I
have one" (valid) from the sender and "I can take it" (ready) from the receiver, and an element moves only in a clock
with both.

The main difference from Erlang processes is that **room is bounded**. A mailbox grows when its reader is slow; between
functions in the pipe there are registers for a few elements. When they fill up, the function before drops its ready,
and the one before that stops too, all the way to the source. This is back-pressure.

Some things follow:

- **The slowest one sets the pace.** With a function taking 100 clocks per element, everything before it moves one
  element per 100 clocks.
- **A join waits for both, a fork for all branches.** A join moves on when each of its streams has an element; a fork
  moves on when every branch has taken the element, so a slow branch holds the others back.
- **Some sources can wait and some cannot.** `ticks` holds its next value until it is taken. `usb_bulk_in()` and
  `changes(...)` take what comes from outside and cannot wait: what comes while they stand still is lost.

## 7. Talking to the CPU

Three kinds of things cross between the CPU and the FPGA. The test: **does overwriting hurt?**

| Kind | Examples | Written |
|---|---|---|
| value (level: only the latest matters) | volume, a kernel's state, a switch's position | `gain_hw(16)`, `gain_hw(:value)`, `radio(:state, :level)`, `EHLS.GPIO.read(:button0)` |
| event (rare, each one matters) | a button pressed | `EHLS.PubSub.broadcast(:presses)` in an instance, messages of `EHLS.PubSub.subscribe(:presses)` (section 8) |
| stream (every value, in order) | sound, IQ | an instance's arguments without a type, and its result |

In the FPGA this distinction is the circuit itself: a value is a register, and its changing fires nothing in what reads
it; a stream has valid and ready, and a value arriving fires the function taking it. An event is the same circuit as a
stream in the FPGA; it differs in how it reaches the CPU, one message each.

Streams go through an instance's arguments without a type and its result. Each gets a DMA engine.

```elixir
out = many_hw([0x0002_0005, 1])           # gives, and takes the result
```

To give a stream from the CPU, give a list of its elements: a list of values when an element is one value, a list of
tuples when it is a tuple. A binary with the values packed left to right can be given instead. The result comes back in
the form given, or as `as: :list` or `as: :binary` says. A list is packed into a binary by the CPU before the DMA, and
unpacked after; a binary needs neither, so it is faster. An instance of two streams takes two lists, `mixer(l, r)`.

During a call only the calling process waits. It is a `receive`, so the other processes keep running. To go on without
waiting, call with messages (as with an `active: :once` socket). There are calls that only give or only take as well;
all of them are in `EHLS.Pipeline`.

One element at a time, as it comes (a key pressed, a reading taken), goes in without the DMA:

```elixir
many_hw(:send, :words, 0x0002_0005)       # :ok, or {:error, :full}: the input holds 8 elements
```

It joins the stream with what the DMA brings, each element whole. Read the results with `many_hw(:out, n)`: a call that
gives and takes counts only its own elements.

## 8. Events

An event is something rare of which each one matters. An instance publishes events under a topic (an atom), as
`Phoenix.PubSub` does: each value that goes into `EHLS.PubSub.broadcast(topic)` is one event. A process receives them with
`EHLS.PubSub.subscribe(topic)`, as messages `{topic, value}`:

```elixir
definstance presses do
  changes(:button0, :rising) |> transform(0, &count/2) |> EHLS.PubSub.broadcast(:presses)
end

EHLS.PubSub.subscribe(:presses)                   # in a GenServer's init/1, say

def handle_info({:presses, n}, st), do: ...
```

- **Unlike a stream,** the publisher does not know who receives and never waits. It has a small room of its own, and an
  event that does not fit is counted and dropped. Any number of processes can subscribe (up to 4 at once today), and
  each gets every event, from its subscription on.
- **In another instance,** `EHLS.PubSub.subscribe(topic)` is a source of the topic's events, so a circuit can act on them without the
  CPU: `EHLS.PubSub.subscribe(:presses) |> map(&dbl/1) |> EHLS.PubSub.broadcast(:doubled)`.
- **A value's changes as events:** `changes(k_hw(:value))` gives the new value each time an instance of values changes,
  and `filter(&f/1)` keeps those for which `f` gives non-zero, as `Enum.filter`:

  ```elixir
  definstance watcher do
    y = changes(k_hw(:value))
    y |> EHLS.PubSub.broadcast(:k)                     # every change
    y |> filter(&big?/1) |> EHLS.PubSub.broadcast(:big)  # only the large ones
  end
  ```

A topic's events are one value of up to 32 bits each. They go through one queue in the FPGA, in the order they came; one
interrupt hands them to the CPU, which sends the messages. Events are made in the FPGA: an instance on the CPU (section
10) does not publish them yet. `EHLS.PubSub.unsubscribe(topic)` ends a process's messages; `EHLS.PubSub.subscribe/2`
also takes `active: :once` (or n) and `timestamps: true`, as a socket.

**One state for several lines: an agent.** A function placed with `transform` has a state of its own. When several
kinds of elements update one state (a value set from one place and counted on from another, events of two topics into
one count), the state is an agent, written as Elixir's `Agent`:

```elixir
definstance panel do
  {:ok, n} = EHLS.Agent.start_link(0, name: MyApp.Count)
  changes(k_hw(:value)) |> EHLS.Agent.update(n, &set_n/2)                   # the state only
  ticks(200) |> EHLS.Agent.get_and_update(n, &inc_n/2) |> EHLS.PubSub.broadcast(:count)
end

EHLS.Agent.get(MyApp.Count, & &1)                  # the state, from the CPU (an agent with a name)
```

Its functions take the state in turn, one element at a time, each seeing what the one before left. Called as functions,
on the CPU, they are `Agent`'s, on a real agent.

**An instance as a GenServer.** `EHLS.Server` owns an instance in a supervision tree: it starts it with the application,
calls it for its callers in turn, and hands a topic's events on to any number of processes
(`{EHLS.Server, instance: {MyApp, :panel}, name: Panel, topics: [:count]}`, then `EHLS.Server.call(Panel, [:get, :n])`).

## 9. The circuit runs from reset

A circuit is always running, so data flows before the CPU reads.

```elixir
definstance logger, buffer: 1024 do
  ticks(1000) |> map(&larger_plus_one/1)
end
```

So `logger(:out, n)` gives **what has gathered, oldest first, not what comes after the call**. `buffer:` (in elements)
says how much gathers. When it is full, by default (`overflow: :wait`) the stream stands still and nothing is lost;
with `overflow: :drop` the stream goes on and new values are lost. A stream to the CPU from a source that cannot wait
needs `:drop` written out.

For fresh data, or to begin from the initial state, stop and start:

```elixir
logger(:stop)      # cancels transfers, drops what the links and the buffer hold
logger(:start)     # runs from the initial state
```

An instance of values stopped keeps its last result; `:start` takes it back to `initial:`. An application replaced
without resetting the FPGA finds the circuits still running, with their previous state and values; if that matters, the
application calls these two when it starts.

## 10. The FPGA or the CPU

`definstance` places a function where it runs best: in the FPGA when there is one, and on the CPU when there is none. So
the same application runs on a board and, for its tests, on a computer.

- **With an FPGA** (the board's scripts, or `mix ehls.compile` and `mix ehls.sim`, which make the circuits), an
  instance is a circuit.
- **Without one** (`mix test`, `iex -S mix` on a computer), an instance is a process that keeps what the circuit would
  keep, started at its first call. It takes the same calls (`f(list)`, `f(binary)`, `:start`, `:stop`, `:value`,
  `:state`, `:out`, `:request`) and gives the same results, as the `defhls` functions are the same.
- **Said explicitly,** with `on:` on the instance (`definstance radio(iq), on: :fpga do`), or for the whole application
  with `config :elixir_hls, placement: :cpu | :fpga` (or `EHLS_PLACEMENT`). What is said comes first.

One function of an instance in the FPGA can run on the CPU instead, as its C (`mix ehls.compile --target cpu` makes it
from the `defhls`):

```elixir
definstance radio, overflow: :drop, buffer: 512 do
  usb_bulk_in() |> map(&demod/1) |> transform(0, &level/2, on: :cpu) |> i2s_out()
end

radio(:cpu_start, batch: 8192)             # the process that takes the stream through the CPU
```

The instance is cut there into two circuits, `radio__pre` and `radio__post`, with a stream to the CPU and one back, and
a process in between takes each batch through the function. It suits a function too large for the FPGA, not one that
must keep a tight pace: AtomVM runs one process at a time, so a batch can come tens of milliseconds late, and the
circuits on either side must hold that much (`buffer:`, a sink that waits). `radio(:cpu_stats, pid)` tells whether the
CPU keeps up. The details: `EHLS.Pipeline`, "Placement".

## 11. Easy mistakes

- **A forgotten sink:** a pipe that ends in a stream is taken as a stream back to the CPU, as a function's last
  expression is its result. Nobody reads it, so it soon stops. `mix ehls.compile` lists the CPU ends, which shows it. To
  read only state, end with `run()`.
- **What `:ok` means:** a call that only gives returns `:ok` once the memory has been read. Sound still has to come out.
- **Calling in sequence:** a large input given by a call that only gives, then a call that only takes, stands still:
  nobody reads the output, so the input stops, and the call times out. Use a call that gives and takes, or messages.
- **`wait: false`, then `:value`:** `:value` may still be the previous result, as the circuit has not finished; a call
  that waits gives the result of its own write.
- **A value changing in the middle of a stream:** a function wired to a value reads it at each element, so a change
  takes effect from the next element; on the CPU the same stream function uses one value for the whole list. They agree
  while the value does not change.
