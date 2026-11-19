defmodule EHLS.Pipeline do
  @moduledoc ~S"""
  `definstance`: `defhls` functions and blocks placed in the FPGA, running from reset, the data moving
  between them without the CPU.

  An instance places `defhls` functions and blocks in the FPGA: one function alone, or, as anywhere in Elixir, several
  joined with the pipe (`|>`). The data flows through them in the pipe's order inside the FPGA without passing through the CPU. It runs from reset, so the program on the CPU only changes
  its levels and reads its state.

  ```elixir
  use EHLS, blocks: [EHLS.I2S]

  definstance tone do
    ticks(48_000) |> tone_wave() |> i2s_out()
  end
  ```

  Here `ticks` gives an item 48,000 times a second, `tone_wave` (a `defhls` function) turns it
  into a sample of a waveform and `i2s_out` plays it over I2S.

  - **What can be placed:**
    - `f()`: a `defhls` function as it is; a stream function works the same. As in Elixir, a call taking
      the stream as its first argument is the same as the pipe: `f(words)` is `words |> f()`.
    - the functions of `EHLS.Stream`, as Elixir's `Stream` has them: `map(&f/1)`, `filter(&f/1)`,
      `transform(init, &f/2)`, `zip_with(a, b, &f/2)`, `chunk_every(n, k, :discard) |> map(&f/1)` and `run()`, written
      with or without the module. Each says there what it places.
    - `map(&f(&1, k_hw(:value)))`, or `f(k_hw(:value))` in the pipe: a function of several arguments, the stream as
      one of them, each other argument an integer or a level (see "Instances of levels").
    - `transform(init, &f/2)` places a function of the element and a state; with `name: n`, `f(:state, n)` reads the
      state while it runs, and a state without a name has no circuit for reading it.
    - blocks (below).
  - **Items:** stream items can be tuples.
  - **Two streams into one function:** `zip_with(a, b, &f/2)` takes one element of each, together, as
    Elixir's `Enum.zip_with` does, and gives `f(x, y)`; the call form `f(a, b)` with both arguments streams
    is the same, and so is `a |> zip_with(b, &f/2)` or `a |> f(b)` in a pipe. A join can be anywhere in the
    body, and each of `a`, `b` an argument of the instance, a pipe from one or from a source, or a join:

    ```elixir
    defhls mix(a :: s16, b :: s16) :: s17 do
      a + b
    end

    definstance mixer(left, right) do
      zip_with(left, right, &mix/2) |> map(&half/1)     # or mix(left, right) |> map(&half/1)
    end

    mixer([1, 2, 3], [10, 20, 30])                     # two lists in, one out

    definstance three(a, b, c) do
      a |> mix(b) |> half() |> mix(c |> neg()) |> half()   # (a, b) joined, then with -c
    end
    ```

    The circuit is a join (it moves on when both inputs have an element) and a kernel of the pair,
    `<f>__zip`. Each input is a CPU end of its own (a DMA engine): `mixer(l, r)` gives them all at once,
    as many elements each (else `:badarg`), and `mixer(:send, :right, data)` one of them.
  - **Naming a stream, and a fork:** a body can have several expressions. `y = ...` names the stream an
    expression gives; a name used twice is a fork: every element goes to each branch, and the fork moves on
    once every branch took it (no buffer: a slow branch holds the others back). Only the last expression
    goes to the CPU; one before it ends in something taking the stream away (a sink):

    ```elixir
    definstance tapped(x) do
      y = x |> map(&smooth/1)
      y |> map(&low16/1) |> hold(:last)      # one branch into a sink
      y |> map(&scale(&1, 3))               # the other, the instance's output
    end
    ```

    A fork joined again (`y |> mix(y |> map(&g/1))`) works as long as the branches' delays are close: a
    branch that gives nothing for many elements (`chunk_every`, a function with a list as output) would need a buffer where they meet, not
    there yet. An argument goes in once; to use it twice, name what it gives (`y = x |> f()`).
  - **An instance called inside an instance:** an instance exists once, so calling it in another wires to
    it: the stream before goes into its input, its output comes out here, and neither is a CPU end.
    An instance of another module is written `Other.fir_hw()`; it is found when the circuits are put
    together (`mix ehls.compile`), which checks that it is in the build, called once, and that the types
    keep their values.

    ```elixir
    definstance fir_hw(x) do
      x |> map(&fir/1)
    end

    definstance player(samples) do
      samples |> map(&gain/1) |> fir_hw() |> map(&clip/1)
    end
    ```

    Called as a statement (`y |> pilot_hw()`), its output stays its own, read with its own calls. It can be
    stopped and started by itself; while it is stopped, the stream through it stands still. For now a
    function comes between an argument and the call, and after the call when it is the last expression
    (their types come from the instance called); and what comes back after a call is of a size the compile
    cannot tell, so a call from the CPU says it: `player(samples, out: n)`.
  - **What can be wired:** an instance starts with a source or with an argument (a stream from the CPU).
    It ends with something that takes the stream away (`i2s_out()`, `hold(name)`, ...), or with a stream, which
    then goes back to the CPU. A first function with nothing to read stops the compile, because it would stand
    still without an input. So does a level wired to a stream input: a level fires nothing, and
    turning one into a stream is a decision about when to read it (`sample(pin)`).
  - **Types at the links:** the output of a function in the pipe and the input of the next one must agree. A widening that keeps the value (`u8` to `u16`, `u8` to `s16`, `s16` to `s18`)
    goes as it is; narrowing or changing the sign would change the value and stops the compile. If you mean it, put a function in between (`map(&low/1)`). Blocks' types
    are declared by their packages (`usb_bulk_in()` gives `u8`, `sample(pin)` `u1`, `ticks(rate)` `u32`; `hold` and `run` take any type).
  - **Generated functions:** `tone(:value, name)` (the level of a `hold(name)`), `tone(:stop)`, `tone(:start)` (stop, and go on from the initial state), `tone(:state, n)` (read the state of `transform(.., name: n)`; its words are taken at one clock, so they cannot tear). A value the CPU changes while it runs is an instance of levels wired into it (below).

  ## Placement: the CPU or the FPGA

  An instance goes to the FPGA where there is one, and runs on the CPU where there is none, so the same application
  works on a board and on a computer without an FPGA. Where a stage runs is the first of: the stage's `on: :cpu | :fpga`,
  the instance's (`definstance radio(iq), on: :fpga do ... end`), the application's `config :elixir_hls, placement: ...`
  (or `EHLS_PLACEMENT`), then `:fpga` when a backend that makes circuits is configured (a SoC or a device backend,
  `EHLS.Backend`) or circuits are being made (`mix ehls.compile`, `mix ehls.sim`), else `:cpu` (`mix test`, `iex -S mix`
  on a computer).

  An instance on the CPU is a process, started at its first call, that keeps each stage's state between calls; its stages
  run as the `defhls` functions do on the CPU, or, with `config :elixir_hls, cpu: :nif` (`EHLS_CPU=nif`) and a
  runtime backend's NIF, as their C (`mix ehls.compile --target cpu`): the elements packed once per pipe and run through
  the kernels in chunks, the same results. It takes the same calls as one in the FPGA: `radio(list)` (a list out),
  `radio(binary)` (the packed format out), `radio(data, as: :list | :binary, timeout: ms)`, `radio(:start)` (from the
  initial states) and `radio(:stop)` (calls answer `{:error, :stopped}` until the next start). So `mix test` runs an
  application's instances on the computer, without a board.

  Its stream comes from its argument or from `ticks(rate)` (a timer in the process, from its start; then
  `radio(:out, n)` waits for the next n elements, `radio(:request, :out, n)` sends `{radio, :out, binary}`; with
  `buffer:` elements waiting the timer waits too, as `overflow: :wait`, or with `overflow: :drop` goes on and what does
  not fit is dropped). An instance with a source starts with `radio(:start)` (reading it does not start it); a stage
  that fails under it stops it, and what waits for it is answered `{:error, :stopped}`. It may end in `hold(h)` (`radio(:value, h)`) or
  `run()`; `radio(:state, n)` reads `transform(.., name: n)`. An instance of levels on the CPU
  (`definstance gain(k :: u8), initial: 3 do k end`) computes its body at each call and holds the result: `gain(5)`,
  `gain(5, wait: false)`, `gain(:value)`; a level wired into a stage (`map(&scale(&1, gain(:value)))`) is read once per
  call.

  The body is what it is in the FPGA: joins (`zip_with(a, b, &f/2)`, `f(a, b)`, anywhere), a stream named and used
  twice (a fork), several expressions, the ones before the last ending in a sink. With several arguments the call takes
  one list or binary for each, `mixer(left, right)`; what one side of a join has more waits for the next call, as in a
  circuit. Not yet on the CPU: blocks other than `ticks`, `hold` and `run`, instances called inside, a pin's level,
  and an `on: :fpga` stage inside; they stop the compile, saying to place the instance in the FPGA.

  ## Stages on the CPU

  A stage that does not fit in the FPGA runs on the CPU, as C (`mix ehls.compile --target cpu`, `EHLS.NIF`), and the instance
  is cut there:

  ```elixir
  definstance radio(iq) do
    iq |> map(&channel/1) |> map(&big_filter/1, on: :cpu) |> map(&post/1)
  end
  ```

  This is two instances of the FPGA, `radio__pre` (up to the stage; its stream goes to the CPU) and `radio__post` (from the stage on;
  its stream comes from the CPU), with CPU ends like any instance, and a process on the CPU between them.
  `radio(:cpu_start, opts)` starts it (the pid is returned) and `radio(:cpu_stop, pid)` stops it. The process asks `radio__pre`
  for a batch, runs it through the NIF in chunks (so that the VM's other processes keep running) and gives the result
  to `radio__post`; it asks for the next batch while it works on this one. `opts`: `batch:` (elements per request, 256),
  `chunk:` (elements per call of the NIF), `levels:` (a function of the kernel giving its level arguments), `to:` (a pid: where
  the results go when the stage is the last one, as `{radio, :out, binary}`), `timeout:` (ms, 5000).

  A stage with state is `transform(init, &f/2, on: :cpu)`: the NIF starts from `init` (a literal, as anywhere) and the
  driver keeps the state between batches; it takes no `name:`, since no circuit holds the state to read.

  Several stages can be `on: :cpu`. Those that follow each other run in one process, one after the other on each batch; an FPGA
  stage between two of them is an instance of its own (`radio__1`, `radio__2`, ..., the last one `radio__post`) with a process on each side.
  `radio(:cpu_start, opts)` then returns a list of pids, one for each run of CPU stages, and `radio(:cpu_stop, pids)` takes it.
  There has to be an FPGA stage before the first (the argument alone is not enough: call `EHLS.NIFRun` from the CPU
  then). A function's other arguments are given where it is placed, as in the FPGA: `map(&volume(&1, gain(:value)), on: :cpu)`,
  `transform(init, &f(&1, &2, 3), on: :cpu)`, each an integer or an instance of levels (`Other.gain(:value)` for another
  module's); an integer goes into the kernel made for it, and the driver reads a level before each batch, as the CPU reads it. Not
  yet: an instance of levels that is itself on the CPU, and a pin's level. `levels:` (a function of the kernel,
  `:"Module.function"`, giving its level arguments) says otherwise. Across the cut the stream is packed bytes, so the types must be the same, not just widening as inside the FPGA
  (`u8` into `u16` changes the size of an element): the compile stops where a `defhls` function on each side says otherwise,
  and a `map` between them changes a type. A source that cannot wait for the CPU (a pin's `changes`, `usb_bulk_in`) needs `overflow: :drop`
  on the `definstance`, as for any stream to the CPU: a CPU stage slower than the source loses elements instead of stopping it.
  `radio(:cpu_stats, pids)` tells how busy each driver was, to see whether the CPU keeps up. The two instances take their `definstance` options (`overflow:`, `buffer:`) on
  `radio__pre`, the part that sends to the CPU.

  ## Blocks

  A block is what can be placed in a `definstance` without being written with `defhls`. A `defhls` must also run on the CPU, so what cannot run there can only be written
  in a `definstance`. There are two kinds.

  | Kind | What it is | Examples |
  |---|---|---|
  | device | a block with physical pins: the real thing is behind them, and the CPU cannot run it | `i2s_out()`, `usb_bulk_in()`, `changes(pin, edge)`, `sample(pin)`, `pin_out(pin)` |
  | built-in block | no pins, but tied to the circuit's time or to the exchange with the CPU | `ticks(rate)`, `hold(name)`, `run()` |

  Built-in blocks belong to the SoC backend and come without being named. Devices come in packages: modules implementing `EHLS.Blocks`
  (`soc/0`, `blocks/0`, `peripherals/0`, `gateware/0`; if needed `waits/0`, `types/0`, `registers/0`, `options/1`, `table/1`), each for one SoC backend.

  ```elixir
  use EHLS, blocks: [Pkg, {Pkg2, pins: [...]}], peripherals: [:lcd]
  ```

  `pins:` moves a package's default pins. `peripherals:` adds circuits the CPU uses directly (a display, say) rather than placed in an instance.

  ## Levels, events and streams

  What passes between the CPU and the FPGA is one of three kinds, and the kind decides how a program
  uses it. The test is whether overwriting hurts: an LED needs only its latest state, but an audio
  stream with a value missing clicks.

  | kind | what matters | examples | on the CPU |
  |---|---|---|---|
  | level | only the latest | an LED, a switch's position, a gain, a kernel's state | a plain function call, no process |
  | event | each one, and they are rare | a button pressed | a message to each process that subscribed (below) |
  | stream | every value, in order | audio samples, IQ | inside the FPGA without the CPU, or an instance called as a function |

  Levels come from two owners. An instance owns its kernels' levels, a block package the levels of its
  device, with no instance involved:

  ```elixir
  gain_hw(32)                  # CPU -> kernel: an instance of levels wired into it, taken from the next input on
  radio(:state, :level)        # kernel -> CPU: the state of the transform named :level
  EHLS.GPIO.write(:led0, 1)    # CPU -> device
  EHLS.GPIO.read(:button0)     # device -> CPU
  ```

  A state of several words is taken at one clock, so its words always belong together, even while the
  instance runs.

  ## Events

  An event is something rare of which each one matters. An instance publishes events under a topic (an
  atom), as `Phoenix.PubSub` does: each element that goes into `EHLS.PubSub.broadcast(topic)` is one event. A
  process receives them with `EHLS.PubSub.subscribe(topic)`, as messages `{topic, value}`:

  ```elixir
  definstance presses do
    changes(:button0, :rising) |> transform(0, &count/2) |> EHLS.PubSub.broadcast(:presses)
  end

  EHLS.PubSub.subscribe(:presses)                   # in a GenServer's init/1, say

  def handle_info({:presses, n}, st), do: ...
  ```

  - **Unlike a stream,** the publisher does not know who receives, and never waits: it has a small
    FIFO of its own, and an event that does not fit is counted, not held back. Any number of processes
    can subscribe to a topic (up to 4 at once today), and each gets every event.
  - **From the subscription on:** events nobody subscribes to are dropped as they come, so a
    subscriber does not get what happened before.
  - **Order:** every publisher's events go into one queue in the FPGA in the order they come, with the
    time each came. One interrupt drains it into the driver, which sends the messages.
  - **As a socket:** `EHLS.PubSub.subscribe(topic, active: :once)` gives the next event and keeps the ones after
    (16 at most, the rest counted, `{:ehls_lost, topic, n}`) until the process subscribes again; `active: n`
    the next n. `timestamps: true` gives `{topic, value, t}`, t when the event came in the FPGA, on the clock
    of `:erlang.monotonic_time(:microsecond)`. See `EHLS.PubSub.subscribe/2`.
  - **A topic's events** are one value up to 32 bits, of one type for all its publishers; topics are
    numbered when the circuits are put together (`mix ehls.compile`).
  - `broadcast` is a sink: before the last expression, it lets an instance publish what it also uses
    (`y |> EHLS.PubSub.broadcast(:level)` beside `y |> map(...)`).
  - **In another instance,** the same `EHLS.PubSub.subscribe(topic)` is a source of the topic's events: every event of
    each publisher, in its order. Each subscribing instance has a small FIFO per publisher; what does not
    fit while it stands still is counted, and the publisher is not held back. So it is a source that
    cannot wait: a stream from it to the CPU says `overflow: :drop`. Its type is the topic's, checked
    when the circuits are put together against what takes it.

    ```elixir
    definstance doubler do
      EHLS.PubSub.subscribe(:presses) |> map(&dbl/1) |> EHLS.PubSub.broadcast(:doubled)
    end
    ```

  - **A value made events:** `changes(k_hw(:value))` is a source giving the new value each time an instance
    of values changes (`Other.k_hw(:value)` for another module's); with `filter(&f/1)` only some of them:

    ```elixir
    definstance watcher do
      y = changes(k_hw(:value))
      y |> EHLS.PubSub.broadcast(:k)
      y |> filter(&big?/1) |> EHLS.PubSub.broadcast(:big)
    end
    ```

    It cannot wait: a change not taken yet is replaced by the next one.

  A pin's changes are events too, written in an instance: `changes(:button0, :both) |> EHLS.PubSub.broadcast(:button0)`, each edge
  with its kind and time. One state updated by several kinds of events is an agent (below).

  Planned: a level read at a rate as a stream, so that it can be processed in the FPGA (e.g. the
  average of the FM radio's audio level).

  ## One state for several lines: an agent

  A function with state placed with `transform` has a state of its own. When several kinds of elements must update one
  state (a value set from one place and counted on from another, events of two topics into one count), the state is an
  agent, `EHLS.Agent`, written as Elixir's `Agent` is:

  ```elixir
  defhls set_n(k :: u16, _n :: u16) :: {u16, u16} do
    {k, k}
  end

  defhls inc_n(_tick :: u32, n :: u16) :: {u16, u16} do
    {n + 1, n + 1}
  end

  definstance panel do
    {:ok, n} = EHLS.Agent.start_link(0, name: MyApp.Count)
    changes(k_hw(:value)) |> EHLS.Agent.update(n, &set_n/2)                    # the state only
    ticks(200) |> EHLS.Agent.get_and_update(n, &inc_n/2) |> EHLS.PubSub.broadcast(:count)  # an output too
  end

  EHLS.Agent.get(MyApp.Count, & &1)                        # the state, from the CPU (an agent with a name)
  ```

  - `{:ok, n} = EHLS.Agent.start_link(initial)` is one state; `x |> EHLS.Agent.get_and_update(n, &f/2)` takes each
    element through `f(x, state)`, which gives `{output, next_state}` (as for `transform`), its output going on;
    `x |> EHLS.Agent.update(n, &f/2)` the same, ending the pipe. Called as functions they are `Agent`'s (`EHLS.Agent`).
  - **A name:** `EHLS.Agent.start_link(initial, name: MyApp.Count)` (a module name, as an `Agent`'s), and the CPU reads
    it with `EHLS.Agent.get(MyApp.Count, & &1)`, as `Agent.get/2`.
  - **One update at a time:** the functions of an agent take its state in turn, one element at a time, in the order the
    elements come (in turn among those that come at once); each sees the state the one before left. Their states must be
    of one type, and the agent's initial value is theirs.
  - Placed, the state is the agent's register in the circuit, not a process, and only `defhls` functions update it. On
    the CPU (an instance placed there) the lines of an agent run one after the other within a call. Not yet:
    `EHLS.Agent.get(n)` in an instance (the state wired into other functions as a level), and an agent's functions as C
    (`cpu: :nif`).

  ## Calling an instance from the CPU

  An instance can be written as a function: its argument is a stream from the CPU, and the stream of
  the end of the pipe goes back to the CPU. The body runs in the FPGA.

  ```elixir
  defhls gray(x :: u32) :: u32 do
    (((x >>> 16) &&& 0xFF) * 77 + ((x >>> 8) &&& 0xFF) * 150 + (x &&& 0xFF) * 29) >>> 8
  end

  definstance gray_accel(pixels) do
    pixels |> map(&gray/1)
  end

  gray(0x123456)              # one value, computed on the CPU
  gray_accel([0x123456, 0xABCDEF])   # a list in, a list out, through the circuit in the FPGA
  gray_accel(pixels)          # a binary in, a binary out
  ```

  The name tells where it runs: `gray` is a function, `gray_accel` a circuit. `mix ehls.compile` checks each
  kernel against its function, so the results are the same. To keep this visible, an instance cannot have the
  name of a `defhls` of the same module.

  A circuit is always running. A call hands data to it and takes what comes out. An instance with an argument
  just waits for its input until it is called.

  **An instance that ends in a stream gets the circuit for the CPU to read it,** as a function's last expression
  is its result. One that ends in something taking the stream does not. The CPU can be at one end only.

  ```elixir
  definstance player(samples) do          # the CPU only gives
    samples |> map(&volume/2) |> i2s_out()
  end

  definstance iq, overflow: :drop do      # the CPU only takes
    usb_bulk_in()
  end

  player(samples)      # :ok
  iq(:out, 16384)      # 16384 elements: bytes, usb_bulk_in gives u8
  ```

  | Instance | Call | Returns when | Returns |
  |---|---|---|---|
  | an argument, ends in a stream | `f(data)` | the output of `data` has arrived | what `data` is: list or binary |
  | | `f(data, out: n)` | `n` elements have arrived | what `data` is |
  | an argument, ends in something taking the stream | `f(data)` | the DMA has read `data` | `:ok` |
  | an argument | `f(:in, data)` | the DMA has read `data` | `:ok` |
  | ends in a stream | `f(:out, n)` | `n` elements have arrived | binary |
  | | `f(:out, n, as: :list)` | `n` elements have arrived | list |

  - **A list or a binary:** `data` is a list of elements or a binary of them packed. A list gives a list back,
    a binary a binary; `as: :list` or `as: :binary` says otherwise. The circuit is the same: a list is packed
    on the CPU before the DMA reads it, and the output unpacked after it has arrived, in C (`hwstream:pack/2`,
    `unpack/2`). In a list a tuple is a tuple and a signed value is negative, as with a stream function on the CPU,
    so a test can compare the two directly; values going in are wrapped to the input's type. A binary costs no
    conversion, and holds more in less memory: 16384 `u8` are 16 KB as a binary and 128 KB as a list on AtomVM.

  - **Sizes count elements:** `f(:out, n)`, `out:`, `buffer:` and `:request` are numbers of elements of the stream, whatever its type.
  - **In a binary** elements are packed by one rule: **each scalar in 1, 2, 4 or 8 bytes, the smallest that holds it, little-endian; a tuple left to right, no padding.**
    A binary that is not a whole number of elements raises.

    | Element | Bytes | In Elixir |
    |---|---|---|
    | `u8` | 1 | `<<b>>` |
    | `s16` | 2 | `<<x::little-signed-16>>` |
    | `s18` | 4 | `<<x::little-signed-32>>` |
    | `{s16, s16}` | 4 | `<<l::little-signed-16, r::little-signed-16>>` |
    | `{u8, s16}` | 3 | `<<b, x::little-signed-16>>` |
    | `{s18, s20}` | 8 | `<<a::little-signed-32, b::little-signed-32>>` |

    Going in, a kernel takes the low bits its type has. Coming out, a value is widened to its bytes as its type says (`s18` by sign, `u12` by zeros).
    A block that declares no type works on `u32`.
  - **The size of the output:** `f(bin)` takes the size the functions in the pipe tell: `map` and `transform` as many elements as the input has,
    `chunk_every(n, k, :discard)` with k >= n `1/k`; overlapping chunks (`chunk_every(n, k, :discard)`, k < n) begin after the
    first n, which they cannot tell across calls. Through a function whose output is a list (`{[y], s}`) or a block they cannot tell,
    so `out:` is needed; without it the call raises `:out_size_needed` at once.
  - **Waiting:** only the calling process waits. It is a `receive`, so the other Erlang processes keep running.
    `:ok` says the input has been read from memory, not that they have gone through the instance: sound still has
    to come out of the speaker.
  - **Call from a process that holds little:** on AtomVM a call costs the calling process a few collections, each
    copying its whole heap. 64 KB took about 400 ms from a process holding a list of 16,384 integers, against 7 ms
    from one holding only the binary. Keep large data in binaries, which live outside the heap, or make the call
    from another process.
  - **Calling in sequence:** `f(:in, bin)` and then `f(:out, n)` in one process stand still with an input larger than
    what the circuit can hold, as nobody reads the output, and time out. Use `f(bin)`, which moves both at
    once, or the messages below.
  - **State:** the state goes on across calls, so one signal can go through a filter as several binaries. `f(:stop)`
    and then `f(:start)` start again from the initial state, dropping what the links and the buffer hold. An application
    replaced without resetting the FPGA finds the previous state, and calls them first if that matters.
  - **Errors:** three exceptions. `:busy` when a transfer is in progress on that end, `:stopped` when the instance
    is stopped, `:timeout` after 5 seconds, which `timeout: ms` changes; a transfer that timed out is cancelled. Slow
    sources take their time: 1024 elements from `ticks(10)` take about 100 s.
  - **Size of the circuit:** each end towards the CPU adds a DMA engine. `mix ehls.compile` lists them. The engines share
    one port to the memory for reading and one for writing, taking turns: an end standing still holds up no other, and
    ends moving at once share the memory's bandwidth.

  ## Instances of levels

  An instance whose arguments have types takes levels and gives a level: values of which only the latest
  matters, not streams. A call writes the arguments; the circuit computes once and holds the result until
  the next call.

  ```elixir
  defhls gain_of(volume :: u4) :: u9 do
    volume * 32
  end

  definstance gain_hw(volume :: u4), initial: 96 do
    gain_of(volume)
  end

  definstance k_hw(v :: u9), initial: 3 do     # a value the CPU writes, given back as it is
    v
  end

  gain_hw(:value)              # 96: the result held now, initial: until the first call
  gain_hw(5)                   # 160: writes 5, waits for that write's result
  gain_hw(5, wait: false)      # :ok: writes only
  ```

  - **The body** is one of the arguments, a tuple of them, or a call of a `defhls` function of the module
    without state (`gain_of(volume)`, `mix(a, b)`): a function of several arguments can be placed this
    way. It becomes one kernel, `<name>__level`, checked by `mix ehls.compile` as any other.
  - **`initial:`** is the result before the first call and after a `:start`: a literal of the result's
    type, cut to it; 0 (a tuple of zeros) when not given.
  - **What the circuit does:** the arguments' words are written one by one, then a start write takes them
    all in the same clock, so a call never computes with half of them. A call made while the circuit
    computes waits for it to end; only the latest one is computed, as only the latest value of a level
    counts. The result and the number of the call it is for are read together, so `gain_hw(5)` gives the
    result of its own write, whatever another process writes meanwhile. A call takes a few milliseconds
    on AtomVM, almost all of it in the CPU.
  - **Errors:** `:stopped` when the instance is stopped (`gain_hw(:stop)`; the result stays the last one
    meanwhile), `:timeout` after 5 seconds without the result (`timeout: ms`).
  - **Widths:** each argument and the result up to 64 bits, tuples too.
  - `mix ehls.sim` checks an instance of levels as the CPU calls it.

  **A level wired into a function placed in a stream.** Inside a `definstance`, the same expression the CPU
  reads a level with is the wire to it:

  ```elixir
  defhls scale(x :: s16, k :: u9) :: s16 do
    x * k
  end

  definstance scaler(words) do
    words |> map(&scale(&1, k_hw(:value)))     # or scale(words, k_hw(:value)), the stream first
  end

  k_hw(5)            # scaler multiplies by 5 from the next value on
  ```

  The kernel reads the level when it takes a value, and a level changing fires nothing.
  On the CPU `scale(x, 5)` is a plain function, so the CPU and the circuit agree while the level does not
  change. An argument can also be an integer, `map(&scale(&1, 3))`, or a pin's level,
  `map(&scale(&1, EHLS.GPIO.read(:switch0)))` (`u1`; an out pin gives what is written to it). An instance of another module,
  `Other.k_hw(:value)`, is found when the circuits are put together (`mix ehls.compile`): it must be in the
  same build. The level's type must keep its values in the argument's (`u8` into `u9`, not `u16`), and it
  is one value, up to 32 bits. What is placed is a kernel of one argument, `<f>__<argument>_<l or c..>`,
  one per way of placing it, checked by `mix ehls.compile` at the level's `initial:` value.

  A stream function can take levels too, given where it is placed: `louder(samples, k_hw(:value))` (`EHLS.defhls/2`,
  "Stream functions").

  Not there yet: levels and a stream in one instance;
  a level wired into a function with a state.

  ## Until it is read

  A circuit runs from reset, so data flows before the CPU reads. **A read gives what has gathered, oldest first, not what
  comes after the call.** For fresh data, call `f(:stop)` and `f(:start)` first.

  `buffer:` says how much gathers: a FIFO in block RAM before the output, in elements. Without it, only the few elements in the
  links. SDRAM is not used for this, since it only works once the CPU has initialized it.

  ```elixir
  definstance logger, buffer: 4096 do
    ticks(1000) |> sample(:button0) |> transform({0, 0}, &debounce/2)
  end

  logger(:out, 4096)
  ```

  `overflow:` says what happens when nobody takes a value and no room is left.

  | `overflow:` | Does | For |
  |---|---|---|
  | `:wait` (default) | the stream stands still, no value is lost; the functions before it in the pipe wait too | sources that can wait, like `ticks` |
  | `:drop` | the stream goes on, new values are lost | sources that cannot, like `usb_bulk_in()`, `changes(...)` |

  A stream from a source that cannot wait needs `overflow: :drop` written out when it goes to the CPU, or the compile
  stops. With `overflow: :drop`, values between two reads that do not fit in the buffer are lost; the values of one read
  are consecutive.

  ## Saying there is no output

  Since an instance ending in a stream gets a circuit to read it, a forgotten sink is no error: the list from
  `mix ehls.compile` shows it. To read only state with `f(:state, ...)`, end with `run()`, a block that takes the stream
  and does nothing with it.

  ```elixir
  definstance counter do
    changes(:button0, :rising) |> transform(0, &count/2) |> run()
  end
  ```

  ## Calling with messages

  To keep the stream going while doing something else, or to have the next input ready while the output is on its way,
  ask for the same transfers with messages. An end is named by the argument's name, or `:out`.

  ```elixir
  gray_accel(:request, :out, 4096)    # {:gray_accel, :out, binary} once 4096 elements have arrived
  gray_accel(:send, :pixels, input)   # {:gray_accel, :pixels, :sent} once input has been read

  def handle_info({:gray_accel, :out, chunk}, st) do
    gray_accel(:request, :out, 4096)
    {:noreply, handle(chunk, st)}
  end
  ```

  As with an `active: :once` socket, messages go to the process that asked. An end takes one more transfer while one is
  in flight (a `:request` while one is being written, a `:send` while one is being read), started the moment the first is
  done, so that the stream goes on without waiting for the program; beyond that `{:error, :busy}`. Each answers with its
  own message, in order. A stopped instance answers `{:error, :stopped}`. `f(:stop)` cancels what is in flight, and no
  message follows. The output's name is `:out`, so an argument cannot be called `out`.

  One element at a time, as a value comes (a key pressed, a reading taken), goes in without DMA: `f(:send, :x, 5)`,
  with an integer, or a tuple for a tuple type, puts it into the input's small FIFO (8 elements) and returns `:ok`, or
  `{:error, :full}` when the FIFO has no room (`{:error, :stopped}` for a stopped instance); no message follows. These
  elements go into the stream in turn with what the DMA brings, each one whole. They are not counted by a call that
  waits for its own results, `f(data)`: a value sent while one runs goes among its elements, and the call gets back
  results of the wrong elements. Read what one by one gives with `f(:out, n)` or `f(:request, :out, n)`.

  An application with a supervision tree can give an instance a process that owns it, `EHLS.Server`: started from the
  initial state with the application, callers waiting their turn instead of `{:error, :busy}`, its topics' events handed
  on to any number of processes, the drivers of a function on the CPU started with it.

  Not yet (planned): a read returning at once with what has gathered.

  ## The functions generated for an instance

  Generates, with a runtime backend (`EHLS.runtime/0`), for a module's instance of levels `f(a, b)`
  (above): `f(a, b)`, `f(a, b, opts)` (`wait: false`, `timeout: ms`), `f(:value)`, `f(:start)`,
  `f(:stop)`. For a module's instance `f` of streams:

    * `f(:stop)`, `f(:start)`: stops it; starts it, from the initial state and clean links;
    * `f(:value, h)`: the latest value that reached a `hold(h)`;
    * `f(:state, k)`: the state of `transform(init, &g/2, name: k)`, its words taken at one clock;
    * with two arguments `a`, `b` (a join): `f(data_a, data_b)`, `f(data_a, data_b, opts)`, and
      `f(:send, :a, data)` per input, answered by `{:f, :a, :sent}`, and `f(:send, :a, value)` (one element);
    * with an argument `x`: `f(data)`, `f(data, opts)`, `f(:in, data)`, `f(:in, data, opts)`, and
      `f(:send, :x, data)`, answered by `{:f, :x, :sent}`, and `f(:send, :x, value)` (one element, `:ok` or
      `{:error, :full}`);
    * with an output: `f(:out, n)`, `f(:out, n, opts)`, and `f(:request, :out, n)`, answered by
      `{:f, :out, binary}`.

  `data` is a list of elements or a binary of them packed (`EHLS.packed_size/1`). `f(data)` gives
  back what it was given, a list for a list and a binary for a binary; `f(:out, n)` gives a binary.
  A list is packed and the output unpacked by the runtime (`EHLS.pack/2`, `EHLS.unpack/2`): tuples
  stay tuples, signed values negative, values going in are wrapped to the input's type.
  Sizes count elements of the stream.
  `opts`: `out: n` (when `f(data)` is to take another size than the stages' rates give, or
  they are not known), `as: :list | :binary` (the form of the output) and `timeout: ms` (5000).

  With `EHLS_OUT_DIR` set at compile time, `<pipeline>.pipeline` (JSON) goes there for the SoC.

  Without a runtime backend (on a computer) the calls of an instance exist too and raise an
  `ArgumentError`: an instance runs on a board; on a computer, check it with `mix ehls.sim`.
  """

  @doc false
  # {name, args} of `f`, `f()`, `f(x)`
  def head!({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: {name, []}
  def head!({name, _, args}) when is_atom(name) and is_list(args), do: {name, args}
  def head!(other), do: raise(ArgumentError, "definstance: bad head #{Macro.to_string(other)}")

  # forms that are not a stage taking a stream: tuples, maps, captures, attributes, blocks, ...
  @not_stages [:{}, :%{}, :&, :@, :__block__, :fn, :., :__aliases__, :=, :|>, :^, :"::", :<<>>]

  @doc false
  # A call taking a stream as its first argument is the same as the pipe, as in Elixir:
  # `f(x)` is `x |> f()` and `g(f(x), a)` is `x |> f() |> g(a)`. Only a variable, a pipe or
  # another call counts as a stream there; `ticks(1000)` and `transform(0, &f/2)` stay as they are.
  def normalize({:|>, m, [lhs, rhs]}), do: {:|>, m, [normalize(lhs), rhs]}

  def normalize({f, m, [first | rest]} = call) when is_atom(f) and f not in @not_stages do
    if stream_arg?(first), do: {:|>, m, [normalize(first), {f, m, rest}]}, else: call
  end

  def normalize(other), do: other

  # a value read, k_hw(:value), is a level, not a stream
  defp stream_arg?({_, _, [:value]}), do: false
  defp stream_arg?({v, _, ctx}) when is_atom(v) and is_atom(ctx), do: true
  defp stream_arg?({:|>, _, [_, _]}), do: true
  defp stream_arg?({g, _, args}) when is_atom(g) and is_list(args) and g not in @not_stages, do: true
  defp stream_arg?(_), do: false

  @doc false
  # the input's name (nil: none) and the body without it
  def input!(_name, [], chain), do: {nil, chain}

  def input!(name, [{x, _, ctx}], chain) when is_atom(x) and is_atom(ctx) do
    if x == :out, do: raise(ArgumentError, "definstance #{name}: an argument cannot be called out, the name of the result")

    case unpipe_ast(chain, []) do
      [{^x, _, c}] when is_atom(c) ->
        raise ArgumentError, "definstance #{name}: nothing happens to #{x}"

      [{^x, _, c} | rest] when is_atom(c) ->
        {x, repipe(rest)}

      _ ->
        raise ArgumentError, "definstance #{name}: the body starts with its argument #{x}"
    end
  end

  def input!(name, [_], _chain), do: raise(ArgumentError, "definstance #{name}: an argument is a name")

  @doc false
  # a stream function's stages, its argument taken off
  def stream_body!(chain, name, x) do
    case unpipe_ast(chain, []) do
      [{^x, _, c}] when is_atom(c) -> raise ArgumentError, "defhls #{name}: nothing happens to #{x}"
      [{^x, _, c} | rest] when is_atom(c) -> repipe(rest)
      _ -> raise ArgumentError, "defhls #{name}: the body starts with its argument #{x}"
    end
  end

  @doc false
  # stream functions called in a chain replaced by their stages, errors at the call. What the
  # function declares stays on its first and last stage, for the links to the outside.
  def expand(chain, fns) do
    chain
    |> unpipe_ast([])
    |> Enum.flat_map(fn
      {f, m, args} when is_map_key(fns, f) and ((is_atom(args) and :erlang.map_get(f, fns).levels == []) or
                                                 (is_list(args) and length(args) == length(:erlang.map_get(f, fns).levels))) ->
        %{chain: inner, in: in_spec, out: out_spec, levels: levels} = Map.fetch!(fns, f)
        args = if is_list(args), do: args, else: []
        # its level arguments are what is given here: a level, an integer, or a level argument of the caller
        given = Map.new(Enum.zip(levels, args))
        inner = Macro.prewalk(inner, fn {k, _, c} = n when is_atom(k) and is_atom(c) -> Map.get(given, k, n); n -> n end)
        stages = for {a, im, b} <- unpipe_ast(inner, []), do: {a, Keyword.put(im, :line, m[:line]), b}
        stages = List.update_at(stages, 0, &declare(&1, :ehls_in, in_spec))
        List.update_at(stages, -1, &declare(&1, :ehls_out, out_spec))

      {f, m, _} when is_map_key(fns, f) ->
        n = length(Map.fetch!(fns, f).levels)
        EHLS.Error.at(m[:line], fn ->
          raise ArgumentError,
                "definstance: the stream function #{f} takes its stream from the stage before it, and #{if n == 0, do: "nothing else", else: "#{n} level(s)"}"
        end)

      stage ->
        [stage]
    end)
    |> repipe()
  end

  defp declare({a, m, b}, key, spec), do: {a, Keyword.put(m, key, spec), b}

  @doc false
  # `filter(&f/1)`, as Enum.filter: the elements for which f gives non-zero. Each becomes
  # `transform(0, &<f>__filter/2)`, a generated function with a state of one bit that emits the element
  # or skips it. Returns {chain, [{name, head, body}]}; fns: the functions that can be called (EHLS.Inline).
  def filters(chain, fns, spec_ast) do
    {stages, defs} =
      chain
      |> unpipe_ast([])
      |> Enum.map_reduce([], fn
        {:filter, m, [{:&, _, [{:/, _, [{f, _, _}, 1]}]}]}, defs when is_atom(f) ->
          EHLS.Error.at(m[:line], fn ->
            %{params: params} =
              case Map.fetch(fns, f) do
                {:ok, info} -> info
                :error -> raise ArgumentError, "definstance: filter(&#{f}/1): #{f} is no defhls of one argument without state of the module"
              end

            [{_, t}] =
              case params do
                [_] -> params
                _ -> raise ArgumentError, "definstance: filter(&#{f}/1): #{f} takes #{length(params)} arguments"
              end

            gname = :"#{f}__filter"
            x = {:hw__x, [], nil}
            on = {:hw__on, [], nil}

            head =
              {:"::", [], [{gname, [], [{:"::", [], [x, spec_ast.(t)]}, {:"::", [], [on, {:state, [], [{:u1, [], nil}]}]}]},
                           {:emit, [], [spec_ast.(t)]}]}

            body = quote(do: if(unquote(f)(unquote(x)) != 0, do: {emit(unquote(x)), 0}, else: {skip(), 0}))
            stage = {:transform, m, [0, {:&, [], [{:/, [], [{gname, [], nil}, 2]}]}]}
            {stage, [{gname, head, body} | defs]}
          end)

        {:filter, m, args}, _defs ->
          EHLS.Error.at(m[:line], fn -> raise ArgumentError, "definstance: filter(&f/1), a function of one argument, got filter(#{Enum.map_join(args, ", ", &Macro.to_string/1)})" end)

        stage, defs ->
          {stage, defs}
      end)

    {repipe(stages), defs |> Enum.reverse() |> Enum.uniq_by(&elem(&1, 0))}
  end

  @doc false
  # a stream function runs on the CPU, so no block in it
  def no_blocks!(chain, name, blocks, fns, windows) do
    for {b, m, _} <- unpipe_ast(chain, []), Map.has_key?(blocks, b), b not in fns, not Map.has_key?(windows, b) do
      EHLS.Error.at(m[:line], fn ->
        raise ArgumentError, "defhls #{name}: #{b} is a block, which cannot run on the CPU: blocks belong in a definstance"
      end)
    end

    :ok
  end

  @doc false
  # what a stream function declares against its first and last stages
  def check_ends!(name, in_spec, out_spec, types) do
    {first_in, _} = hd(types)
    {_, last_out} = List.last(types)

    unless first_in == :any or widens?(in_spec, first_in),
      do: raise(ArgumentError, "defhls #{name}: takes #{type_text(in_spec)} and its first stage takes #{type_text(first_in)}, which would change the value")

    unless widens?(last_out, out_spec),
      do: raise(ArgumentError, "defhls #{name}: gives #{type_text(out_spec)} and its last stage gives #{type_text(last_out)}, which would change the value")
  end

  @doc false
  # each stage's initial state as it is written, nil where the stage says none
  def initial_states(chain) do
    for stage <- unpipe_ast(chain, []) do
      case stage do
        {:transform, _, [init | _]} -> init
        _ -> nil
      end
    end
  end

  @doc false
  # the first stage's name
  def first_stage(chain) do
    case unpipe_ast(chain, []) do
      [{name, _, _} | _] -> name
      _ -> nil
    end
  end

  @doc false
  # is the last stage's stream left for the CPU? (:source and :block give one)
  def output?(stages, blocks) do
    case List.last(stages) do
      %{block: b} -> elem(Map.fetch!(blocks, String.to_atom(b)), 0) in [:source, :block]
      %{kernel: _} -> true
    end
  end

  @doc false
  # the output's description (nil: none) from the options
  def options!(name, opts, output?, cannot_wait?) do
    # the part before a stage on the CPU (EHLS.CpuStage) knows the instance it was cut from
    {cut_of, opts} = Keyword.pop(opts, :cut_of)

    for {k, _} <- opts, k not in [:buffer, :overflow],
        do: raise(ArgumentError, "definstance #{name}: unknown option #{k}")

    buffer = Keyword.get(opts, :buffer, 0)
    overflow = Keyword.get(opts, :overflow)

    if opts != [] and not output?,
      do: raise(ArgumentError, "definstance #{name}: #{hd(Keyword.keys(opts))} is about a result, and it ends in a sink")

    unless is_integer(buffer) and buffer >= 0,
      do: raise(ArgumentError, "definstance #{name}: buffer is a number of elements, got #{inspect(buffer)}")

    unless overflow in [nil, :wait, :drop],
      do: raise(ArgumentError, "definstance #{name}: overflow is :wait or :drop, got #{inspect(overflow)}")

    if output? and cannot_wait? and overflow != :drop do
      if cut_of,
        do: raise(ArgumentError, "definstance #{cut_of}: its source cannot wait until the CPU stage reads (the part before on: :cpu is #{name}): write overflow: :drop")

      raise(ArgumentError, "definstance #{name}: its source cannot wait until the CPU reads: write overflow: :drop")
    end

    if output?, do: %{buffer: buffer, overflow: overflow || :wait}
  end

  @doc false
  # output elements per input element as {num, den}, nil when the compile cannot know them
  def rate(chain, rates, windows, blocks), do: rate_of(unpipe_ast(chain, []), rates, windows, blocks, {1, 1})

  defp rate_of([], _r, _w, _b, acc), do: acc
  defp rate_of(_, _r, _w, _b, nil), do: nil

  # chunks that do not overlap (a step of the count or more): one output per step; overlapping ones begin after the
  # first count, which the compile cannot count across calls
  defp rate_of([{:chunk_every, _, [n, k, :discard]}, {:map, _, [f]} | rest], r, w, b, acc) when is_integer(n) and is_integer(k) and k >= n,
    do: rate_of(rest, r, w, b, if(plain_window?(f, w), do: times(acc, {1, k})))

  defp rate_of([{:map, _, [f]} | rest], r, w, b, acc),
    do: rate_of(rest, r, w, b, stage_rate(fun_name(f), r, acc))

  defp rate_of([{:transform, _, [_init, f | _]} | rest], r, w, b, acc),
    do: rate_of(rest, r, w, b, stage_rate(fun_name(f), r, acc))

  defp rate_of([{name, _, _} | rest], r, w, b, acc) do
    cond do
      Map.has_key?(r, name) -> rate_of(rest, r, w, b, stage_rate(name, r, acc))
      match?({:source, _, _}, b[name]) -> rate_of(rest, r, w, b, acc)
      match?({k, _, _} when k in [:sink, :level], b[name]) -> acc
      true -> nil
    end
  end

  defp plain_window?(f, windows) do
    case Map.fetch(windows, fun_name(f)) do
      {:ok, %{etype: t, ret: r}} -> not tuple_type?(t) and not tuple_type?(r)
      :error -> false
    end
  end

  defp tuple_type?({:{}, _, _}), do: true
  defp tuple_type?({_, _}), do: true
  defp tuple_type?(_), do: false

  defp stage_rate(name, rates, acc) do
    case Map.get(rates, name) do
      nil -> nil
      r -> times(acc, r)
    end
  end

  defp times({a, b}, {c, d}) do
    g = Integer.gcd(a * c, b * d)
    {div(a * c, g), div(b * d, g)}
  end

  defp times(nil, _), do: nil

  @doc """
  Fuses `chunk_every(n, k, :discard) |> map(&f/1)` with `f` a function of a chunk (`defhls f(w :: tuple(t, n)) :: r`, in
  `windows`) into one generated defhls: a ring buffer of the last n words in a memory, a counter of the elements, and
  f's body with `elem(w, i)` read from the buffer (`i` 0 the oldest, n - 1 the word just in). Returns
  `{chain, [defhls AST], [generated names]}`.
  """
  def fuse(chain, windows) do
    {stages, gen} = fuse_stages(unpipe_ast(chain, []), windows, [], [])
    {repipe(stages), Enum.map(gen, &elem(&1, 1)), Enum.map(gen, &elem(&1, 0))}
  end

  defp fuse_stages([{:chunk_every, m, [n, k, :discard]}, {:map, mm, [f]} | rest], windows, out, gen),
    do: EHLS.Error.at(m[:line], fn -> fuse_one(n, k, f, kept(m, mm), rest, windows, out, gen) end)

  defp fuse_stages([{:chunk_every, m, args} = s | rest], _windows, _out, _gen) do
    EHLS.Error.at(m[:line], fn ->
      case {args, rest} do
        {[_, _, :discard], _} ->
          raise ArgumentError, "definstance: #{Macro.to_string(s)} is followed by map(&f/1), f a function of the chunk"

        _ ->
          raise ArgumentError,
                "definstance: chunk_every(count, step, :discard): a circuit keeps no chunk shorter than count, got #{Macro.to_string(s)}"
      end
    end)
  end

  defp fuse_stages([s | rest], windows, out, gen), do: fuse_stages(rest, windows, [s | out], gen)
  defp fuse_stages([], _windows, out, gen), do: {Enum.reverse(out), Enum.reverse(gen)}

  # the fused stage's line, and what a stream function declares of its first and last stages
  defp kept(window_meta, map_meta) do
    Keyword.take(window_meta, [:line, :ehls_in]) ++ Keyword.take(map_meta, [:ehls_out])
  end

  defp fuse_one(n, k, f, meta, rest, windows, out, gen) do
    fname = fun_name(f)

    w =
      case Map.fetch(windows, fname) do
        {:ok, w} -> w
        :error -> raise ArgumentError, "definstance: #{fname} takes no chunk (defhls #{fname}(w :: tuple(t, n)))"
      end

    unless is_integer(n) and is_integer(k) and k >= 1 and n == w.n,
      do: raise(ArgumentError, "definstance: chunk_every(#{n}, #{inspect(k)}, :discard) for #{fname}, a function of #{w.n} elements")


    gname = :"#{fname}_c#{n}_s#{k}"
    fuse_stages(rest, windows, [{gname, meta, []} | out], [{gname, window_kernel(gname, w, k)} | gen])
  end

  defp unwrap_capture({:&, _, [{:/, _, [{f, m, c}, _]}]}), do: {:&, [], [{:/, [], [{f, m, c}, 1]}]}
  defp unwrap_capture(f), do: f

  defp fun_name({:&, _, [{:/, _, [{f, _, _}, n]}]}) when is_atom(f) and is_integer(n), do: f
  defp fun_name({f, _, ctx}) when is_atom(f) and is_atom(ctx), do: f
  defp fun_name(other), do: raise(ArgumentError, "definstance: map(&f/1) expected, got #{Macro.to_string(other)}")

  # the defhls for chunk_every(n, k, :discard) |> map(&f/1). A chunk of tuples keeps one ring buffer per element; w[i]
  # is then a tuple of reads. w[i]: i 0 the oldest of the chunk, n - 1 the word just in.
  defp window_kernel(gname, w, k) do
    size = pow2(w.n)
    aw = bits(size - 1)
    var = fn v -> {v, [], nil} end
    [x, st, pos, cnt, out, y, cnt2] = Enum.map(~w(x st pos cnt out y cnt2)a, &var.(:"hw__#{&1}"))

    etypes =
      case w.etype do
        {:{}, _, ts} -> ts
        {a, b} -> [a, b]
        t -> [t]
      end

    tuple? = length(etypes) > 1
    hists = for i <- 1..length(etypes), do: var.(:"hw__hist#{i}")
    xs = if tuple?, do: for(i <- 1..length(etypes), do: var.(:"hw__x#{i}")), else: [x]
    mem_params = for {h, t} <- Enum.zip(hists, etypes), do: quote(do: unquote(h) :: memory(unquote(t), unquote(size)))
    writes = for {h, xi} <- Enum.zip(hists, xs), do: quote(do: unquote(h) = write(unquote(h), unquote(pos), unquote(xi)))
    split_x = if tuple?, do: [quote(do: {unquote_splicing(xs)} = unquote(x))], else: []

    # w[n - 1] is the word just in (x), older words come from the ring buffers
    last = w.n - 1

    read_old = fn i ->
      reads = for h <- hists, do: quote(do: read(unquote(h), unquote(pos) + unquote(i) - unquote(last)))
      if tuple?, do: {:{}, [], reads}, else: hd(reads)
    end

    # A loop over the window from 0 gets its first step peeled off (into the accumulator's
    # initial value), so that the loop only reads the buffers: every value live across a
    # loop goes round it on every iteration in hardware (a mux, a fork and a buffer each).
    # (the loop variable by name and context: its metadata differs between occurrences)
    wk? = fn e, {kn, _, kc} -> match?({_, true}, Macro.prewalk(e, false, fn
      {{:., _, [Access, :get]}, _, [{v, _, _}, {^kn, _, ^kc}]} = n, _ when v == w.var -> {n, true}
      n, f -> {n, f}
    end)) end

    subst = fn e, {kn, _, kc}, by -> Macro.prewalk(e, fn {^kn, _, ^kc} -> by; n -> n end) end

    looped = fn e, {kn, _, kc} = kv -> Macro.prewalk(e, fn
      {{:., _, [Access, :get]}, _, [{v, _, _}, {^kn, _, ^kc}]} when v == w.var -> read_old.(kv)
      n -> n
    end) end

    all_reads = fn
      {{:., _, [Access, :get]}, _, [{v, _, _}, i]} when v == w.var -> read_old.(i)
      n -> n
    end

    body =
      w.body
      |> Macro.prewalk(fn
        # Enum.sum(for k <- 0..b, do: e)
        {{:., _, [{:__aliases__, _, [:Enum]}, :sum]}, _, [{:for, fm, [{:<-, gm, [{kn, _, kc} = kv, {:.., rm, [0, b]}]}, [do: e]]}]}
        when is_atom(kn) and is_atom(kc) and is_integer(b) and b >= 1 ->
          acc = var.(:hw__acc)
          {:for, fm, [{:<-, gm, [kv, {:.., rm, [1, b]}]}, [reduce: subst.(e, kv, 0)],
                      [do: [{:->, [], [[acc], {:+, [], [acc, looped.(e, kv)]}]}]]]}

        # for k <- 0..b, reduce: init do pat -> body end, the body reading w[k]
        {:for, fm, [{:<-, gm, [{kn, _, kc} = kv, {:.., rm, [0, b]}]}, [reduce: init], [do: [{:->, am, [[pat], e]}]]]} = n
        when is_atom(kn) and is_atom(kc) and is_integer(b) and b >= 1 ->
          if wk?.(e, kv) do
            first = {:__block__, [], [{:=, [], [pat, init]}, subst.(e, kv, 0)]}
            {:for, fm, [{:<-, gm, [kv, {:.., rm, [1, b]}]}, [reduce: first], [do: [{:->, am, [[pat], looped.(e, kv)]}]]]}
          else
            n
          end

        n ->
          n
      end)
      # inside a loop's body w[i] is always a buffer read: the loop starts in a later block
      # than the writes, and CIRCT lets a block go on only once its stores are done, so
      # w[0] reads the word just written (no select between x and the buffer: x would go
      # round the loop)
      |> Macro.prewalk(fn
        {:for, fm, [gen | opts]} ->
          opts =
            Enum.map(opts, fn kw ->
              Enum.map(kw, fn
                {:do, body} -> {:do, Macro.prewalk(body, all_reads)}
                other -> other
              end)
            end)

          {:for, fm, [gen | opts]}

        other ->
          other
      end)
      |> Macro.prewalk(fn
        {{:., _, [Access, :get]}, _, [{v, _, _}, ^last]} when v == w.var -> x
        {{:., _, [Access, :get]}, _, [{v, _, _}, i]} when v == w.var and is_integer(i) -> read_old.(i)
        {{:., _, [Access, :get]}, _, [{v, _, _}, i]} when v == w.var ->
          quote do: if(unquote(i) == unquote(last), do: unquote(x), else: unquote(read_old.(i)))

        other ->
          other
      end)

    et = w.etype
    pt = {:"u#{aw}", [], nil}

    # the writes first (the body reads only older words): x is not needed after a loop. cnt: the elements of the chunk
    # so far; at n of them the chunk is out, and the next one has its first n - k. A step over the count: cnt counts
    # the step round (0 .. k - 1), the chunk out at n - 1, the elements after it until the step's end left out
    ct = {:"u#{bits(max(w.n, k) - 1)}", [], nil}

    {after_out, next} =
      if k <= w.n,
        do: {w.n - k, quote(do: unquote(cnt) + 1)},
        else: {w.n, quote(do: if(unquote(cnt) == unquote(k - 1), do: 0, else: unquote(cnt) + 1))}

    quote do
      defhls unquote(gname)(unquote(x) :: unquote(et), unquote(st) :: state({unquote(pt), unquote(ct)}),
              unquote_splicing(mem_params)) :: emit(unquote(w.ret)) do
        {unquote(pos), unquote(cnt)} = unquote(st)
        unquote_splicing(split_x)
        unquote_splicing(writes)

        unquote(out) =
          if unquote(cnt) == unquote(last) do
            {emit(unquote(body)), unquote(after_out)}
          else
            {skip(), unquote(next)}
          end

        {unquote(y), unquote(cnt2)} = unquote(out)
        {unquote(y), {unquote(pos) + 1, unquote(cnt2)}}
      end
    end
  end

  defp pow2(n), do: Bitwise.bsl(1, bits(n - 1))
  defp bits(0), do: 1
  defp bits(n), do: length(Integer.digits(n, 2))

  defp unpipe_ast({:|>, _, [lhs, rhs]}, acc), do: unpipe_ast(lhs, [rhs | acc])
  defp unpipe_ast(first, acc), do: [first | acc]

  defp repipe([first | rest]), do: Enum.reduce(rest, first, fn s, acc -> {:|>, [], [acc, s]} end)

  @doc false
  def stages(chain, module, hls_fns, states, blocks, input? \\ false) do
    stages = unpipe(chain, [])

    {stages, ports} =
      for {name, args, m} <- stages do
        line = m[:line]
        {st, {n, in_, out}} = EHLS.Error.at(line, fn -> stage(name, args, module, hls_fns, states, blocks) end)
        declared = for {k, field} <- [ehls_in: :declared_in, ehls_out: :declared_out, ehls_wires: :wires, ehls_from: :from], m[k] != nil, into: %{}, do: {field, m[k]}
        # a kernel made where a function is placed (EHLS.Level) is named, in what is said of it, as that function
        {st |> Map.put(:line, line) |> Map.put(:name, n) |> Map.merge(declared), {m[:ehls_of] || n, in_, out, line}}
      end
      |> Enum.unzip()

    check_ports!(ports, input?)

    Enum.reduce(stages, [], fn st, seen ->
      case st[:state_name] do
        nil -> seen
        n ->
          if n in seen, do: EHLS.Error.at(st.line, fn -> raise(ArgumentError, "definstance: two states named #{n}") end)
          [n | seen]
      end
    end)

    stages
  end

  @doc false
  # the connections between the stages, today a straight line of streams (check_ports!), each with its
  # element's type. The CPU's ends are the instance's input and output, not links.
  def links(stages, types) do
    for i <- 0..(length(stages) - 2)//1 do
      %{from: i, to: i + 1, kind: :stream, type: EHLS.type_name(elem(Enum.at(types, i), 1))}
    end
  end

  @doc false
  # Each stage's {input type, output type}, every link checked. A link may widen a value keeping it (the
  # consumer's argument does the same on the CPU); what would change a value stops the compile.
  def types!(stages, fn_types, block_types) do
    types =
      for st <- stages do
        if Map.has_key?(st, :kernel),
          do: Map.fetch!(fn_types, st.name),
          # a block that declares nothing works on 32-bit words
          else: Map.get(block_types, st.name, {{32, false}, {32, false}})
      end

    pairs = Enum.zip(stages, types)

    for {{a, {_, out}}, {b, {in_, _}}} <- Enum.zip(pairs, tl(pairs)) do
      EHLS.Error.at(b[:line], fn ->
        check_link_type!(a.name, Map.get(a, :declared_out, out), b.name, Map.get(b, :declared_in, in_))
      end)
    end

    types
  end

  defp check_link_type!(_a, _out, _b, :any), do: :ok
  defp check_link_type!(_a, nil, _b, _in), do: :ok
  defp check_link_type!(_a, _out, _b, nil), do: :ok

  defp check_link_type!(a, out, b, in_) do
    unless widens?(out, in_) do
      raise ArgumentError,
            "definstance: #{a} gives #{type_text(out)} and #{b} takes #{type_text(in_)}, which would change the value: write what you mean as a function, map(&f/1)"
    end
  end

  defp type_text(t), do: t |> EHLS.type_name() |> name_text()
  defp name_text(l) when is_list(l), do: "{" <> Enum.map_join(l, ", ", &name_text/1) <> "}"
  defp name_text(t), do: t

  @doc false
  # does every value of the first type have the same value in the second?
  def widens?({:tuple, a}, {:tuple, b}) when length(a) == length(b),
    do: Enum.zip(a, b) |> Enum.all?(fn {x, y} -> widens?(x, y) end)

  def widens?({w, s}, {w2, s2}) when is_integer(w) and is_integer(w2) do
    cond do
      s == s2 -> w2 >= w
      s2 -> w2 > w
      true -> false
    end
  end

  def widens?(_, _), do: false

  # what each stage takes and gives: {name, in, out}, each :stream, :level or nil (nothing)
  defp check_ports!([{name, in_, _, line} | _] = ports, input?) do
    EHLS.Error.at(line, fn ->
      if in_ == :stream and not input?,
        do: raise(ArgumentError, "definstance: #{name} takes a stream, and nothing comes before it: start with a source or an argument")

      if in_ == nil and input?,
        do: raise(ArgumentError, "definstance: #{name} takes nothing, so nothing can come from the argument before it")
    end)

    for {{a, _, out, line_a}, {b, in_, _, line_b}} <- Enum.zip(ports, tl(ports)) do
      EHLS.Error.at(if(out == nil, do: line_a, else: line_b), fn -> check_link!(a, out, b, in_) end)
    end

    :ok
  end

  defp check_link!(a, out, b, in_) do
    cond do
      out == nil ->
        raise ArgumentError, "definstance: #{a} must come last"

      in_ == nil ->
        raise ArgumentError, "definstance: #{b} must come first"

      out == :level ->
        raise ArgumentError,
              "definstance: #{a} gives a level, which cannot fire #{b}: only a stream or an event fires a stage"

      true ->
        :ok
    end
  end

  defp several(module, name) do
    fns = if is_atom(module) and Module.open?(module), do: Module.get_attribute(module, :hw_fns) || %{}, else: %{}

    case fns do
      %{^name => %{params: [_, _ | _] = ps}} -> length(ps)
      _ -> nil
    end
  end

  defp stage(name, args, module, hls_fns, states, blocks) do

      # map(&f/1) / transform(init, &f/2): a defhls function as a stage (stateless / stateful)
      {name, transform, args} =
        case {name, args} do
          {:map, [f]} -> {fun_name(unwrap_capture(f)), nil, []}
          {:transform, [init, f | opts]} -> {fun_name(unwrap_capture(f)), {init, state_name!(opts), agent!(opts)}, []}
          {:transform, _} -> raise(ArgumentError, "definstance: transform(init, &f/2) or transform(init, &f/2, name: n)")
          {n, a} -> {n, nil, a}
        end

      cond do
        # a defhls function of the module wins over a block of the same name
        name in hls_fns ->
          if args != [], do: raise(ArgumentError, "definstance: call the defhls function #{name} without arguments")
          {kernel_stage(EHLS.kernel_name(inspect(module), name), name, transform, states[name]), {name, :stream, :stream}}

        Map.has_key?(blocks, name) ->
          {kind, arity, gateware} = Map.fetch!(blocks, name)
          if length(args) != arity, do: raise(ArgumentError, "definstance: #{name} takes #{arity} argument(s)")
          unless Enum.all?(args, &(is_integer(&1) or is_atom(&1))),
            do: raise(ArgumentError, "definstance: #{name}: integers and atoms only as arguments")

          {in_, out} =
            case kind do
              :source -> {nil, :stream}
              :block -> {:stream, :stream}
              :sink -> {:stream, nil}
              :level -> {:stream, :level}
            end

          {%{block: Atom.to_string(name), args: args, gateware: gateware}, {name, in_, out}}

        # a plain function of several arguments is a stage where it is placed with what its other arguments are
        (n = several(module, name)) != nil ->
          raise ArgumentError,
                "definstance: #{name} takes #{n} arguments: transform(init, &#{name}/2) with its second as a state, " <>
                  "or map(&#{name}(&1, g(:value))) with the others levels or integers"

        true ->
          raise ArgumentError,
                "definstance: #{name} is neither a defhls function of #{inspect(module)} with one argument, nor a block (#{Enum.join(Map.keys(blocks), " ")})"
      end
  end

  # A state is written where it is placed: a stage with a state says so by transform, with
  # its initial value, and a name if it can be read while it runs (name(:state, n))
  defp kernel_stage(kernel, _name, nil, nil), do: %{kernel: kernel}

  defp kernel_stage(_kernel, name, nil, _spec),
    do: raise(ArgumentError, "definstance: #{name} has a state: transform(init, &#{name}/2)")

  defp kernel_stage(_kernel, name, _transform, nil),
    do: raise(ArgumentError, "definstance: #{name} has no state: map(&#{name}/1)")

  defp kernel_stage(kernel, _name, {init, state_name, agent}, spec) do
    st = %{kernel: kernel, init: EHLS.__init_words__(init, spec)}
    st = if state_name, do: Map.put(st, :state_name, state_name), else: st
    # a function of an agent: its state is the agent's, one for all its functions (EHLS.Compiler.agents/2)
    if agent, do: Map.put(st, :agent, agent), else: st
  end

  # transform's options: name: (the state read by name(:state, n)) and, made from get_and_update, agent:
  defp state_name!([]), do: nil

  defp state_name!([opts]) when is_list(opts) do
    case {Keyword.keys(opts) -- [:name, :agent], opts[:name]} do
      {[], n} when is_atom(n) and n not in [true, false] -> n
      _ -> raise ArgumentError, "definstance: transform: name: an atom is the one option, got #{Macro.to_string(opts)}"
    end
  end

  defp state_name!(opts),
    do: raise(ArgumentError, "definstance: transform: name: an atom is the one option, got #{Macro.to_string(opts)}")

  defp agent!([opts]) when is_list(opts), do: opts[:agent]
  defp agent!(_), do: nil

  # a |> b |> c -> [a, b, c] as {name, args}
  defp unpipe({:|>, _, [lhs, rhs]}, acc), do: unpipe(lhs, [stage(rhs) | acc])
  defp unpipe(first, acc), do: [stage(first) | acc]

  defp stage({name, m, args}) when is_atom(name) and is_list(args), do: {name, args, m}
  defp stage({name, m, ctx}) when is_atom(name) and is_atom(ctx), do: {name, [], m}
  defp stage(other), do: raise(ArgumentError, "definstance: bad stage #{Macro.to_string(other)}")
end
