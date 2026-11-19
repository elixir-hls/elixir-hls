defmodule EHLS do
  @moduledoc """
  `defhls`: an Elixir function that can be synthesized, and runs on the CPU too. `definstance`
  (`EHLS.Pipeline`) places it in the FPGA. A `defhls` can call others of its module; in the circuit the call is the
  callee's body, and one with several arguments is only for this. `case`, `cond`, patterns and
  several clauses become `if`s for the circuit. Definitions are processed at the end of the module.

      defmodule Demo do
        use EHLS

        defhls stream_kernel(x :: u32) :: u32 do
          a = signed(x &&& 0xFFFF, 16)
          b = signed(x >>> 16, 16)
          if a > b, do: a * 3 + b, else: a + b * 2
        end
      end

  generates

    * `stream_kernel(integer)`: the function on the CPU, with the argument and result wrapped to
      their types (`u1`..`u64`, `s1`..`s64`, tuples), the same results as the hardware;
    * when `EHLS_OUT_DIR` is set at compile time, `<kernel>.mlir` there (func + arith, see
      `EHLS.MLIR`) and `<kernel>.sig`, which `mix ehls.compile` turns into
      SystemVerilog with CIRCT and into the SoC's kernel list. The kernel is named
      `<module>_<function>` (`kernel_demo_stream_kernel`).
  """
  import Bitwise

  # generated for the application (the runtime backend): EHLS.PubSub.subscribe/1 uses it on the board
  @compile {:no_warn_undefined, :hw_kernels}

  @doc """
  `use EHLS` imports `defhls` / `definstance`. Options:

    * `blocks: [module | {module, options}]`: packages of blocks and peripherals
      (`EHLS.Blocks`) for the SoC backend in use, besides its built-in ones
      (`EHLS.Blocks.defaults/0`); options go to the package's gateware (e.g.
      `pins: [dout: "j5:7"]` over its default pins);
    * `peripherals: [atom]`: SoC peripherals of those packages the application uses (e.g. a
      LCD).

  With `EHLS_OUT_DIR` set at compile time, `<module>.packages` (the packages and their options)
  and `<module>.peripherals` go there for the SoC (priv/gen_manifest.py).
  """
  defmacro __using__(opts) do
    EHLS.Error.compile(__CALLER__.file, __CALLER__.line, fn -> EHLS.Compiler.using(opts, __CALLER__) end)
  end

  @doc """
  `definstance`: see `EHLS.Pipeline`.
  """
  defmacro definstance(head, do: chain), do: EHLS.Compiler.remember(__CALLER__, :hw_instance_defs, {head, [], chain})
  defmacro definstance(head, opts, do: chain), do: EHLS.Compiler.remember(__CALLER__, :hw_instance_defs, {head, opts, chain})

  @doc false
  defmacro __before_compile__(env), do: EHLS.Compiler.before_compile(env)

  @doc ~S"""
  A function defined with `defhls` becomes a circuit where `definstance` places it in the FPGA; that circuit is a kernel.
  It takes one element of a stream (a value up to 64 bits, or a tuple of them) and gives one result. The CPU reaches it
  by calling the instance it is placed in (calling an instance from the CPU).

  - **Types:** `u1`..`u64` (unsigned), `s1`..`s64` (signed) and tuples of them. A kernel's input and output are up to 64 bits:
    its ports are 32 bits, or 64 when a value of its input or output is wider. State, memories and levels are up to 32 bits,
    since the CPU reads and sets them in 32-bit words. Tuples hold
    state and values born together; on a stream they are one element, moving in one clock. On the CPU the arguments and the result are
    cut to their widths too, so the CPU computes what the circuit does.
  - **Expressions:** `+ - *`, `&&& ||| ^^^`, shifts (`>>>` also by an unsigned value),
    comparisons, `and or not`, `if/else`, `case`, `cond`, tuples, `signed(x, n)` / `unsigned(x, n)` (the low n
    bits of a value as a signed / unsigned number), `Enum.at(@t, i)` (a list of integers in a
    module attribute, looked up as a table).
  - **State:** a function of the element and a state, `count(x :: u8, n :: u16) :: {u8, u16}`, returns
    `{output, next_state}`: the shape of the function `Stream.transform/3` takes. The function itself holds nothing: on
    the CPU it is a plain function, called with a state. Placed with `transform(init, &f/2)`, its second argument is the
    state: it sits in the circuit's registers, starts from `init` and changes with every item.
  - **A missing output:** as in `Stream.transform/3`, the output is a list, `{[y], s}` or `{[], s}` (at most one
    element), written `{[u8], u16}`: a kernel gives no output for some items, e.g. one output for every four inputs (rate
    changes).
  - **Tuples in the state:** a state may hold tuples, `{pos, hist} :: {u8, tuple(s16, 8)}` (`tuple(s16, 8)`: 8
    integers of type `s16`, the same as `{s16, s16, ...}`), read with `elem(hist, i)`; the next state holds the tuple
    rewritten with `put_elem`, as Elixir would. The next state replaces the state whole, so placed with `transform` the
    tuple is registers. With `memory: [:hist]` where it is placed, `hist` is the FPGA's memory (block RAM): smaller, but
    one element read or written per clock, and only for a next state made from it with `put_elem`, from zeros:

    ```elixir
    defhls fir(x :: s16, {pos, hist} :: {u8, tuple(s16, 8)}) :: {s32, {u8, tuple(s16, 8)}} do
      acc = for k <- 1..3, reduce: x do
        acc -> acc + elem(hist, (pos - k) &&& 7)
      end
      {acc, {pos + 1, put_elem(hist, pos &&& 7, x)}}
    end

    x |> transform({0, Tuple.duplicate(0, 8)}, &fir/2, memory: [:hist])
    ```

    In a memory, what `put_elem` writes goes in at the end of the step, as a register takes its next value: every `elem`
    of the step reads the tuple as it came in, and one of a tuple rewritten in the step reads the value written there.
    On the CPU it is Elixir's tuple; an index out of range is an error, so a ring buffer writes its wrap,
    `(pos - k) &&& 7`, which costs no circuit. The circuit does not check the index: out of range it reads or writes
    something else (a memory is rounded up to a power of two), so keep the index in range, as on the CPU.
  - **Levels:** after the element (and the state, for `transform`), plain arguments are levels: inputs read at each item,
    given where the function is placed, `map(&scale(&1, gain_hw(:value)))`,
    `transform(0, &volume(&1, &2, gain_hw(:value)))` (`EHLS.Pipeline`, "Instances of levels"), or integers. On the CPU
    they are plain arguments.
  - **`case` and `cond`:** a circuit gives a value for every input, so the last clause must match everything: `_ ->` or a variable, `true ->` in a
    `cond`. Patterns are integers, variables, `_`, `^variable` and tuples of them, with guards (`when`). In the circuit every clause is
    computed and one selected.
  - **Several clauses:** a function can have clauses with patterns and guards. Each repeats the types, which must be the same, and the last
    must match everything, as in `case`. A function with a memory has one clause.

    ```elixir
    defhls classify(0 :: u8) :: u8 do
      200
    end

    defhls classify(x :: u8) :: u8 when x < 16 do
      x * 2
    end

    defhls classify(x :: u8) :: u8 do
      x >>> 1
    end
    ```

  - **Calls:** a `defhls` can call others of the same module, in any order. This adds no circuit of its own: the
    body is expanded at each call, so two calls cost two copies. Arguments and result are wrapped to the callee's types, so the CPU gives
    the same results. A `defhls` with several arguments is placed with the stream as one of them and levels or integers as
    the others (`map(&scale(&1, 3))`, `EHLS.Pipeline`). Functions with a memory or a list as the output cannot be called, and neither can a function call itself.

    ```elixir
    defhls sat16(v :: s32) :: s16 do
      if v > 32767, do: 32767, else: if(v < -32768, do: -32768, else: v)
    end

    defhls mix(a :: s16, b :: s16, k :: u4) :: s16 do
      sat16(a * k + b)
    end
    ```

  - **Table values:** `defhls` and `definstance` are processed together at the end of the module, so `Enum.at(@t, i)` has the value last set in `@t`.
  - **Loops:** `for k <- a..b, reduce:` is a loop in the circuit: one copy of the body, used
    again and again. `Enum.reduce(a..b, ...)` is unrolled: n copies of the body side by side,
    `k` a constant. Unroll for speed, loop for size; both nest.

  What cannot become a circuit stops the compile, with a `CompileError` giving the file and the line of the expression, or
  of the call in a `definstance`. Whether an expression can become a circuit shows when `mix ehls.compile` builds it.

  ## Stream functions

  A `defhls` can take a stream as well as a single value. This gives a name to functions joined with the pipe, for using them several times.

  ```elixir
  defhls fir(w :: tuple(s16, 32)) :: s18 do
    ...
  end

  defhls lowpass(x :: stream(s16)) :: stream(s18) do
    x |> chunk_every(32, 4, :discard) |> map(&fir/1)
  end

  lowpass([100, -200, 300, 400])    # on the CPU: a list in, a list out

  definstance filtered(samples) do
    samples |> lowpass()            # placed as a circuit
  end
  ```

  - **What it holds:** the functions of `EHLS.Stream` (`map`, `transform`, `chunk_every`, ...) and other stream functions. The body starts with its argument and ends in a stream. Devices and built-in
    blocks cannot run on the CPU, so they cannot be here. One input and one output, no forks.
  - **On the CPU:** a list goes through element by element. Elements stay as they are, tuples and signs included; the argument's are wrapped to the type in
    `stream(type)`. A function whose output is a list (`{[y], s}` / `{[], s}`) or `chunk_every` makes the list shorter. So a whole chain can be tested with `mix test`, without a board; to compare it with the circuit, run an instance using it through `mix ehls.sim`.
  - **State:** on the CPU each call starts from the `transform`'s initial state. A circuit's state goes on, so results agree from the initial state. To go on computing on the CPU, call
    the function with state directly, giving it the state.
  - **Levels:** after the stream, arguments with a type (up to 32 bits) are levels the functions in its pipe
    take, and the `definstance` placing it says where each comes from (`EHLS.Pipeline`, "Instances of levels"):

    ```elixir
    defhls louder(x :: stream(s16), k :: u9) :: stream(s16) do
      x |> map(&smooth/1) |> map(&scale(&1, k))
    end

    louder([100, 200, 300], 5)       # on the CPU: k is 5 for the whole list

    definstance player(samples) do
      louder(samples, k_hw(:value))  # in the circuit: scale reads k_hw's result at each value
    end
    ```

    So the CPU and the circuit agree while the level does not change. A level can be given on to another stream
    function, `x |> louder(k)`, or be an integer where it is placed, `louder(samples, 3)`.
  - **Circuit:** a stream function is a definition too and makes no circuit. Used in an instance, it is expanded in place. Used twice, there are two circuits, with
    two states.
  - **Types:** the argument's type must widen to the input of the first function in the pipe, and the end of the pipe to the result's type. The rule is that of the links.
  - **Names:** what is named inside is named as if placed in the instance directly: `f(:state, :total)` (`transform(0, &sum/2, name: :total)`). A function used twice repeats the names.
    A function with a named state used twice stops the compile, as the state could not be told.
  """
  defmacro defhls(head, do: body), do: EHLS.Compiler.remember(__CALLER__, :hw_defs, {head, body})

  @doc false
  # a stage's state words, taken at one clock in the hardware, as a value of their types (one
  # word: the integer, several: a tuple)
  def __state__(rt, stage, types) do
    vals = __state_words__(rt.peek(stage, length(types)), types)
    if length(vals) == 1, do: hd(vals), else: List.to_tuple(vals)
  end

  @doc false
  # a state holding memories (EHLS.TupleState): parts [{:val, zeros} | {:mem, addr, n, {w, s}}] in order, the values
  # from the stage's words (zeros: their shape), each memory's n words from its address in the stage's memory space
  def __state__(rt, stage, types, parts) do
    vals = if types == [], do: [], else: __state_words__(rt.peek(stage, length(types)), types)

    {items, []} =
      :lists.mapfoldl(
        fn
          {:val, z}, vs -> __fill__(z, vs)
          {:mem, addr, n, {w, s}}, vs -> {:erlang.list_to_tuple(for(v <- rt.mem_read(stage, addr, n), do: wrap(v, w, s))), vs}
        end,
        vals,
        parts
      )

    case parts do
      [{:mem, _, _, _}] -> hd(items)
      _ -> :erlang.list_to_tuple(items)
    end
  end

  defp __fill__(z, vs) when is_tuple(z) do
    {items, rest} = :lists.mapfoldl(&__fill__/2, vs, :erlang.tuple_to_list(z))
    {:erlang.list_to_tuple(items), rest}
  end

  defp __fill__(_z, [v | rest]), do: {v, rest}

  defp __state_words__([], []), do: []
  defp __state_words__([v | vs], [{w, s} | ts]), do: [wrap(v, w, s) | __state_words__(vs, ts)]

  # The CPU ends of an instance (see EHLS.Pipeline). All of this runs on the board: nothing here that
  # AtomVM's library lacks (Keyword), and a caller waits in a receive, so other processes keep running.

  @default_timeout 5000

  defp opt(opts, key, default) do
    case :lists.keyfind(key, 1, opts) do
      {^key, v} -> v
      false -> default
    end
  end

  # how many elements a binary holds: a whole number, or it raises
  defp elements!(bytes, size) when rem(bytes, size) == 0, do: div(bytes, size)
  defp elements!(_, _), do: :erlang.error(:badarg)

  defp check!(:ok), do: :ok
  defp check!(reason), do: :erlang.error(reason)

  defp answer(:ok), do: :ok
  defp answer(reason), do: {:error, reason}

  @doc false
  # the elements of the output of bin: what `out:` says, else what the stages' rates give (0 / 0: not known)
  def __out_size__(bin, opts, num, den, in_size) do
    case opt(opts, :out, nil) do
      nil when den == 0 -> :erlang.error(:out_size_needed)
      nil ->
        n = elements!(byte_size(bin), in_size) * num
        if rem(n, den) != 0, do: :erlang.error(:badarg)
        div(n, den)
      n -> n
    end
  end

  @doc false
  # a list of elements to the packed binary the CPU end takes, by the runtime's NIF
  def __packed__(_rt, bin, _layout) when is_binary(bin), do: bin
  def __packed__(rt, list, layout), do: rt.pack(list, layout)

  @doc false
  # the output as `as:` says (:list or :binary), else in the form of the input
  def __as__(rt, bin, opts, list?, layout) do
    case opt(opts, :as, if(list?, do: :list, else: :binary)) do
      :binary -> bin
      :list -> rt.unpack(bin, layout)
      _ -> :erlang.error(:badarg)
    end
  end

  @doc false
  def __send__(_rt, _pipe, _e, name, tag, <<>>, _size) do
    send(self(), {name, tag, :sent})
    :ok
  end

  def __send__(rt, pipe, e, name, tag, bin, size) do
    elements!(byte_size(bin), size)
    answer(rt.end_send(e, pipe, name, tag, bin))
  end

  @doc false
  def __request__(_rt, _pipe, _e, name, 0, _size) do
    send(self(), {name, :out, <<>>})
    :ok
  end

  def __request__(rt, pipe, e, name, n, size) when n > 0, do: answer(rt.end_request(e, pipe, name, :out, n * size))
  def __request__(_rt, _pipe, _e, _name, _n, _size), do: :erlang.error(:badarg)

  # a timeout cancels; a message on its way before that must not reach the next call
  defp wait(name, tag, ends, rt, opts) do
    t = opt(opts, :timeout, @default_timeout)

    receive do
      {^name, ^tag, v} -> v
    after
      t ->
        for e <- ends, do: rt.end_cancel(e)
        flush(name, tag)
        :erlang.error(:timeout)
    end
  end

  defp flush(name, tag) do
    receive do
      {^name, ^tag, _} -> flush(name, tag)
    after
      0 -> :ok
    end
  end

  @doc false
  def __in__(rt, pipe, e, name, tag, bin, size, opts) do
    check!(__send_raw__(rt, pipe, e, name, tag, bin, size))
    :sent = wait(name, tag, [e], rt, opts)
    :ok
  end

  @doc false
  def __out__(rt, pipe, e, name, n, size, opts) do
    check!(__request_raw__(rt, pipe, e, name, n, size))
    wait(name, :out, [e], rt, opts)
  end

  @doc false
  def __both__(rt, pipe, ein, eout, name, tag, bin, in_size, n, out_size, opts) do
    check!(__request_raw__(rt, pipe, eout, name, n, out_size))

    case __send_raw__(rt, pipe, ein, name, tag, bin, in_size) do
      :ok ->
        :ok

      reason ->
        rt.end_cancel(eout)
        flush(name, :out)
        :erlang.error(reason)
    end

    # the output first: the input's message may come after it, and is then waiting already
    out = wait(name, :out, [ein, eout], rt, opts)
    :sent = wait(name, tag, [ein], rt, opts)
    out
  end

  @doc false
  # one element given to an input without DMA: packed as the DMA reads it, as 32-bit words
  def __push__(rt, pipe, e, value, layout) do
    answer(rt.end_push(e, pipe, push_words(rt.pack([value], layout), [])))
  end

  defp push_words(<<w::little-32, rest::binary>>, acc), do: push_words(rest, [w | acc])
  defp push_words(<<>>, acc), do: :lists.reverse(acc)
  defp push_words(tail, acc), do: push_words(tail <> <<0::size(32 - bit_size(tail))>>, acc)

  @doc false
  # an instance's inputs together, [{end, tag, binary, element size}], as many elements each, and its
  # output (eout nil: none): what f(a, b) gives
  def __all__(rt, pipe, ins, eout, name, n, out_size, opts) do
    counts = for {_, _, bin, size} <- ins, do: elements!(byte_size(bin), size)
    if length(:lists.usort(counts)) > 1, do: :erlang.error(:badarg)
    if eout, do: check!(__request_raw__(rt, pipe, eout, name, n, out_size))
    send_all(rt, pipe, ins, eout, name, [])
    out = if eout, do: wait(name, :out, ends_of(ins) ++ [eout], rt, opts), else: :ok
    for {e, tag, _, _} <- ins, do: :sent = wait(name, tag, [e], rt, opts)
    out
  end

  defp ends_of(ins), do: for({e, _, _, _} <- ins, do: e)

  defp send_all(_rt, _pipe, [], _eout, _name, _done), do: :ok

  defp send_all(rt, pipe, [{e, tag, bin, size} | rest], eout, name, done) do
    case __send_raw__(rt, pipe, e, name, tag, bin, size) do
      :ok ->
        send_all(rt, pipe, rest, eout, name, [{e, tag} | done])

      reason ->
        for {d, t} <- done do
          rt.end_cancel(d)
          flush(name, t)
        end

        if eout do
          rt.end_cancel(eout)
          flush(name, :out)
        end

        :erlang.error(reason)
    end
  end

  defp __send_raw__(rt, pipe, e, name, tag, bin, size) do
    case __send__(rt, pipe, e, name, tag, bin, size) do
      :ok -> :ok
      {:error, reason} -> reason
    end
  end

  defp __request_raw__(rt, pipe, e, name, n, size) do
    case __request__(rt, pipe, e, name, n, size) do
      :ok -> :ok
      {:error, reason} -> reason
    end
  end

  # An instance of levels (EHLS.Level) called from the CPU: runs on the board too.

  @doc false
  # {{level, peek}, lane, in_specs, out_specs, shape}: writes the arguments' words, then the start
  # write; waits, unless wait: false, until the result of that write is held and gives it back
  def __level_call__(rt, pipe, {{level, peek}, lane, in_specs, out_specs, shape}, values, opts) do
    words = level_in_words(level_flatten(values, []), in_specs, lane, [])

    case rt.level_start(level, pipe, words) do
      :stopped ->
        :erlang.error(:stopped)

      issued ->
        if opt(opts, :wait, true) == false do
          :ok
        else
          t = opt(opts, :timeout, @default_timeout)
          deadline = :erlang.monotonic_time(:millisecond) + t
          level_wait(rt, peek, issued, lane, out_specs, shape, deadline)
        end
    end
  end

  @doc false
  # the result held now
  def __level_value__(rt, {{_level, peek}, lane, _in_specs, out_specs, shape}) do
    [_done | words] = rt.peek(peek, 1 + length(out_specs) * div(lane, 32))
    level_build(shape, level_decode(words, out_specs, lane, []))
  end

  # the count held with the result reached this write's (the counts go round at 32 bits)
  defp level_wait(rt, peek, issued, lane, out_specs, shape, deadline) do
    [done | words] = rt.peek(peek, 1 + length(out_specs) * div(lane, 32))

    cond do
      band(done - issued, 0xFFFFFFFF) < 0x80000000 ->
        level_build(shape, level_decode(words, out_specs, lane, []))

      :erlang.monotonic_time(:millisecond) > deadline ->
        :erlang.error(:timeout)

      true ->
        receive do
        after
          1 -> level_wait(rt, peek, issued, lane, out_specs, shape, deadline)
        end
    end
  end

    # the values of the arguments in order, tuples taken apart
  defp level_flatten([], acc), do: :lists.reverse(acc)
  defp level_flatten([v | rest], acc) when is_tuple(v), do: level_flatten(:erlang.tuple_to_list(v) ++ rest, acc)
  defp level_flatten([v | rest], acc) when is_integer(v), do: level_flatten(rest, [v | acc])
  defp level_flatten(_, _), do: :erlang.error(:badarg)

  # each value wrapped to its type, in 32-bit words, `lane` bits each
  defp level_in_words([], [], _lane, acc), do: :lists.reverse(acc)

  defp level_in_words([v | vs], [{w, s} | specs], lane, acc) do
    u = wrap(v, w, s) &&& (1 <<< lane) - 1
    acc = if lane == 64, do: [u >>> 32, u &&& 0xFFFFFFFF | acc], else: [u | acc]
    level_in_words(vs, specs, lane, acc)
  end

  defp level_in_words(_, _, _, _), do: :erlang.error(:badarg)

  defp level_decode([], [], _lane, acc), do: :lists.reverse(acc)

  defp level_decode([lo, hi | ws], [{w, s} | specs], 64, acc),
    do: level_decode(ws, specs, 64, [wrap(lo ||| hi <<< 32, w, s) | acc])

  defp level_decode([v | ws], [{w, s} | specs], 32, acc), do: level_decode(ws, specs, 32, [wrap(v, w, s) | acc])

  defp level_build(shape, values) do
    {v, []} = level_build_one(shape, values)
    v
  end

  defp level_build_one({:tuple, specs}, values) do
    {items, rest} = level_build_items(specs, values, [])
    {:erlang.list_to_tuple(items), rest}
  end

  defp level_build_one(_spec, [v | rest]), do: {v, rest}

  defp level_build_items([], values, acc), do: {:lists.reverse(acc), values}

  defp level_build_items([s | specs], values, acc) do
    {v, rest} = level_build_one(s, values)
    level_build_items(specs, rest, [v | acc])
  end


  @doc """
  The module the generated code calls to use the hardware: the runtime backend's
  (`c:EHLS.Runtime.module/0`, `EHLS.Backend`), nil without one (CPU only: no hardware clauses).
  It provides `pipe_enable(pipeline_index, on)`, `level_start(level, pipeline, words)`,
  `peek(stage, words)`, `end_send/5`, `end_request/5`, `end_cancel/1`, `end_push/3`, and `pack(list, layout)`,
  `unpack(binary, layout)` as `pack/2` and `unpack/2` do; the indices come from the
  module `:hw_kernels` the runtime backend generates.
  """
  def runtime do
    case EHLS.Backend.runtime() do
      nil -> nil
      rt -> rt.module()
    end
  end

  @doc """
  How the stages of an instance on the CPU run: `:beam` (the `defhls` functions as Elixir, in the VM, anywhere) or
  `:nif` (their C, `mix ehls.compile --target cpu`, as machine code through the runtime's NIF). `EHLS_CPU`, else
  `config :elixir_hls, cpu: ...`, else `:beam`.
  """
  def cpu_code do
    case System.get_env("EHLS_CPU") do
      v when v in [nil, ""] -> Application.get_env(:elixir_hls, :cpu, :beam)
      "beam" -> :beam
      "nif" -> :nif
      v -> raise ArgumentError, "EHLS_CPU=#{v}: beam or nif"
    end
  end

  @doc """
  Where an instance's stages run unless the stage or the instance says (`on: :cpu | :fpga`): `EHLS_PLACEMENT`, else
  `config :elixir_hls, placement: ...`, else `:fpga` with a backend that makes circuits (a SoC or a device backend,
  `EHLS.Backend`), else `default`: `:cpu` (an application runs without an FPGA), `:fpga` when circuits are being made
  (`mix ehls.compile`). See `EHLS.Pipeline`, "Placement".
  """
  def placement(default \\ :cpu) do
    case System.get_env("EHLS_PLACEMENT") do
      v when v in [nil, ""] ->
        Application.get_env(:elixir_hls, :placement) ||
          if(EHLS.Backend.soc() || EHLS.Backend.get(:device), do: :fpga, else: default)

      "cpu" ->
        :cpu

      "fpga" ->
        :fpga

      v ->
        raise ArgumentError, "EHLS_PLACEMENT=#{v}: cpu or fpga"
    end
  end

  @doc "The low `n` bits of `x` as an unsigned integer."
  def unsigned(x, n), do: x &&& (1 <<< n) - 1

  @doc "The low `n` bits of `x` as a two's complement signed integer."
  def signed(x, n) do
    v = unsigned(x, n)
    if v >= 1 <<< (n - 1), do: v - (1 <<< n), else: v
  end

  @doc false
  def wrap(x, n, true), do: signed(x, n)
  def wrap(x, n, false), do: unsigned(x, n)

  # Code wrapping the value of `ast` to `spec`, element by element for tuples. Only immediate
  # terms in the generated code: AtomVM decodes a literal (a tuple, a big integer) from the
  # module's literal table on every use, which allocates and often collects garbage.

  @doc """
  Runs a stateful defhls function on the CPU over a list of inputs from `state`:
  returns {outputs, final state}, like the FPGA does with a stream.
  """
  def run_cpu(fun, inputs, state), do: run_cpu(fun, inputs, state, [])

  # (AtomVM's exavmlib has no Enum.map_reduce/3); an output that may be missing is a list of at most one, as
  # Stream.transform's: [] gives nothing
  defp run_cpu(_fun, [], state, acc), do: {:lists.reverse(acc), state}

  defp run_cpu(fun, [x | rest], state, acc) do
    case fun.(x, state) do
      {[], state} -> run_cpu(fun, rest, state, acc)
      {[y], state} -> run_cpu(fun, rest, state, [y | acc])
      {y, state} -> run_cpu(fun, rest, state, [y | acc])
    end
  end

  @doc """
  The bytes of one element of a stream in a binary at the CPU: each scalar in 1, 2, 4 or 8, the
  smallest that holds it; a tuple left to right, no padding. A block that takes any type: a word.

      iex> EHLS.packed_size({12, true})
      2
      iex> EHLS.packed_size({:tuple, [{8, false}, {32, true}]})
      5
  """
  def packed_size(nil), do: 4
  def packed_size(:any), do: 4
  def packed_size({:emit, spec}), do: packed_size(spec)
  def packed_size({:tuple, specs}), do: specs |> Enum.map(&packed_size/1) |> Enum.sum()
  def packed_size({n, _}) when n <= 8, do: 1
  def packed_size({n, _}) when n <= 16, do: 2
  def packed_size({n, _}) when n <= 32, do: 4
  def packed_size({_, _}), do: 8

  @doc """
  A stream element's type as the runtime's `pack/2` and `unpack/2` take it: a scalar is its
  bits, negative when signed; a tuple is a tuple of those. A block that takes any type: a word.

      iex> EHLS.layout({:tuple, [{8, false}, {16, true}]})
      {8, -16}
  """
  def layout(nil), do: 32
  def layout(:any), do: 32
  def layout({:emit, spec}), do: layout(spec)
  def layout({:tuple, specs}), do: specs |> Enum.map(&layout/1) |> List.to_tuple()
  def layout({n, true}), do: -n
  def layout({n, false}), do: n

  @doc """
  Elements to a binary in the packed format (`packed_size/1`), each value wrapped to its type:
  what the runtime's `pack/2` does in C, written in Elixir to check it against.

      iex> EHLS.pack([{1, -2}, {300, 70000}], {8, -16})
      <<1, 254, 255, 44, 112, 17>>
  """
  def pack(elements, layout) when is_list(elements), do: :erlang.list_to_binary(pack_list(elements, layout))

  defp pack_list([], _l), do: []
  defp pack_list([x | rest], l), do: [pack_value(x, l) | pack_list(rest, l)]
  defp pack_list(_, _l), do: :erlang.error(:badarg)

  # bytes, not binaries: AtomVM may collect garbage on every binary it builds (EHLS.Check)
  defp pack_value(x, l) when is_integer(l) and is_integer(x),
    do: le_bytes(wrap(x, abs(l), l < 0), packed_size({abs(l), l < 0}))

  defp pack_value(t, l) when is_tuple(l) and is_tuple(t) and tuple_size(t) == tuple_size(l),
    do: pack_values(:erlang.tuple_to_list(t), :erlang.tuple_to_list(l))

  defp pack_value(_, _l), do: :erlang.error(:badarg)

  defp pack_values([], []), do: []
  defp pack_values([x | xs], [l | ls]), do: [pack_value(x, l) | pack_values(xs, ls)]

  defp le_bytes(v, 1), do: [v &&& 255]
  defp le_bytes(v, 2), do: [v &&& 255, v >>> 8 &&& 255]
  defp le_bytes(v, 4), do: [v &&& 255, v >>> 8 &&& 255, v >>> 16 &&& 255, v >>> 24 &&& 255]
  defp le_bytes(v, 8), do: le_bytes(v, 4) ++ le_bytes(v >>> 32, 4)

  @doc """
  A binary in the packed format to its elements, signed values negative, tuples as tuples:
  what the runtime's `unpack/2` does in C. A binary that is not a whole number of elements raises.

      iex> EHLS.unpack(<<1, 254, 255, 44, 112, 17>>, {8, -16})
      [{1, -2}, {44, 4464}]
  """
  def unpack(bin, layout) when is_binary(bin) do
    elements!(byte_size(bin), layout_size(layout))
    unpack_list(:erlang.binary_to_list(bin), layout, [])
  end

  defp unpack_list([], _l, acc), do: :lists.reverse(acc)

  defp unpack_list(bytes, l, acc) do
    {x, rest} = unpack_value(bytes, l)
    unpack_list(rest, l, [x | acc])
  end

  defp unpack_value(bytes, l) when is_integer(l) do
    {v, rest} = from_le(bytes, packed_size({abs(l), l < 0}))
    {wrap(v, abs(l), l < 0), rest}
  end

  defp unpack_value(bytes, l) when is_tuple(l) do
    {vals, rest} = unpack_values(bytes, :erlang.tuple_to_list(l), [])
    {:erlang.list_to_tuple(vals), rest}
  end

  defp unpack_values(bytes, [], acc), do: {:lists.reverse(acc), bytes}

  defp unpack_values(bytes, [l | ls], acc) do
    {v, rest} = unpack_value(bytes, l)
    unpack_values(rest, ls, [v | acc])
  end

  defp from_le([a | rest], 1), do: {a, rest}
  defp from_le([a, b | rest], 2), do: {a ||| b <<< 8, rest}
  defp from_le([a, b, c, d | rest], 4), do: {a ||| b <<< 8 ||| c <<< 16 ||| d <<< 24, rest}

  defp from_le(bytes, 8) do
    {lo, rest} = from_le(bytes, 4)
    {hi, rest} = from_le(rest, 4)
    {lo ||| hi <<< 32, rest}
  end

  defp layout_size(l) when is_integer(l), do: packed_size({abs(l), l < 0})
  defp layout_size(l) when is_tuple(l), do: :lists.foldl(&(layout_size(&1) + &2), 0, :erlang.tuple_to_list(l))

  # compile-time functions other modules call by these names
  @doc false
  defdelegate __write_kernel__(file, line, dir, sig, params, result, body, tables), to: EHLS.Compiler
  @doc false
  defdelegate kernel_name(module, name), to: EHLS.Compiler
  @doc false
  defdelegate type_name(spec), to: EHLS.Compiler
  @doc false
  defdelegate block_type(t), to: EHLS.Compiler
  @doc false
  defdelegate __init_words__(ast, spec), to: EHLS.Compiler
  @doc false
  defdelegate __init_words__(ast, spec, bits), to: EHLS.Compiler
end
