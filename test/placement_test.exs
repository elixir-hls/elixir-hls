defmodule EHLS.PlacementTest do
  use ExUnit.Case

  # Instances placed on the CPU: a process keeping the stages' states, the same calls as an instance in the FPGA.
  # Compiled with EHLS_PLACEMENT=cpu (test_helper.exs makes the others' default the FPGA).

  defp compile(src, placement \\ "cpu") do
    old = System.get_env("EHLS_PLACEMENT")
    System.put_env("EHLS_PLACEMENT", placement)

    try do
      Code.compile_string(src)
    after
      System.put_env("EHLS_PLACEMENT", old || "fpga")
    end
  end

  setup_all do
    compile("""
    defmodule CpuInst do
      use EHLS

      defhls inc(x :: u8) :: u8 do
        x + 1
      end

      defhls double(x :: u8) :: u16 do
        x * 2
      end

      # a running sum: state between elements, and between calls
      defhls running(x :: u16, acc :: u32) :: {u32, u32} do
        {acc + x, acc + x}
      end

      defhls every_other(x :: u32, 1 :: u1) :: {[u32], u1} do
        {[x], 0}
      end

      defhls every_other(_x :: u32, _n :: u1) :: {[u32], u1} do
        {[], 1}
      end

      defhls pair(x :: u8) :: {u8, u8} do
        {x, x + 1}
      end

      definstance plain(x) do
        x |> map(&inc/1) |> map(&double/1)
      end

      definstance summing(x) do
        x |> map(&inc/1) |> map(&double/1) |> transform(0, &running/2)
      end

      definstance from_ten(x) do
        x |> map(&double/1) |> transform(10, &running/2)
      end

      definstance halving(x) do
        x |> map(&double/1) |> transform(0, &running/2) |> transform(0, &every_other/2)
      end

      definstance tuples(x) do
        x |> map(&pair/1)
      end

      # sinks: the latest element held, or nothing kept
      definstance last_sum(x) do
        x |> map(&double/1) |> transform(0, &running/2, name: :sum) |> hold(:last)
      end

      definstance dropped(x) do
        x |> map(&double/1) |> run()
      end

      definstance named(x) do
        x |> map(&double/1) |> transform(5, &running/2, name: :acc)
      end

      # the same on: as an instance in the FPGA takes, here for the stage already on the CPU
      definstance marked(x) do
        x |> map(&inc/1) |> map(&double/1, on: :cpu)
      end
    end
    """)

    :ok
  end

  test "an instance on the CPU: a list in, a list out, as the functions give it" do
    assert CpuInst.plain([1, 2, 255]) == [4, 6, 0]
    assert CpuInst.marked([1, 2]) == [4, 6]
    assert CpuInst.tuples([1, 255]) == [{1, 2}, {255, 0}]
  end

  test "its state goes on across calls, :start starts it again, :stop stops it" do
    CpuInst.summing(:start)
    assert CpuInst.summing([0, 1]) == [2, 6]
    assert CpuInst.summing([2]) == [12]
    assert CpuInst.summing(:start) == :ok
    assert CpuInst.summing([2]) == [6]
    assert CpuInst.summing(:stop) == :ok
    assert CpuInst.summing([2]) == {:error, :stopped}
    assert CpuInst.summing(:start) == :ok
    assert CpuInst.summing([0]) == [2]
  end

  test "transform's initial value, emit and skip" do
    assert CpuInst.from_ten([1, 2]) == [12, 16]
    # running sums 2, 6, 12, 20: every other from state 0, so the 2nd and the 4th
    assert CpuInst.halving([1, 2, 3, 4]) == [6, 20]
  end

  test "a binary in, a binary out (the packed format), or as: says" do
    CpuInst.plain(:start)
    assert CpuInst.plain(<<1, 2>>) == <<4, 0, 6, 0>>
    assert CpuInst.plain(<<1>>, as: :list) == [4]
    assert CpuInst.plain([1], as: :binary) == <<4, 0>>
  end

  test "a wrong element raises in the caller and the instance goes on" do
    CpuInst.summing(:start)
    assert CpuInst.summing([1]) == [4]
    assert_raise FunctionClauseError, fn -> CpuInst.summing([:a]) end
    assert CpuInst.summing([1]) == [8]
  end

  test "the same module with the instances in the FPGA: circuits, not processes" do
    compile(
      """
      defmodule FpgaInst do
        use EHLS
        defhls inc(x :: u8) :: u8 do
          x + 1
        end
        definstance plain(x) do
          x |> map(&inc/1)
        end
      end
      """,
      "fpga"
    )

    # no runtime backend on this computer: the calls say where an instance in the FPGA runs
    assert_raise ArgumentError, ~r/runs on a board/, fn -> FpgaInst.plain([1]) end
  end

  test "the default: the FPGA with a backend that makes circuits, or when circuits are made; else the CPU" do
    saved = for k <- ~w(EHLS_PLACEMENT EHLS_SOC EHLS_DEVICE), do: {k, System.get_env(k)}

    try do
      for {k, _} <- saved, do: System.delete_env(k)
      assert EHLS.placement() == :cpu
      # mix ehls.compile makes circuits
      assert EHLS.placement(:fpga) == :fpga
      System.put_env("EHLS_SOC", "litex")
      assert EHLS.placement() == :fpga
      System.delete_env("EHLS_SOC")
      System.put_env("EHLS_DEVICE", "gowin_gw5a")
      assert EHLS.placement() == :fpga
      # said: what is said
      System.put_env("EHLS_PLACEMENT", "cpu")
      assert EHLS.placement() == :cpu
      assert EHLS.placement(:fpga) == :cpu
    after
      for {k, v} <- saved, do: if(v, do: System.put_env(k, v), else: System.delete_env(k))
    end
  end

  test "on: on the instance wins over the default" do
    compile("""
    defmodule MixedDefaults do
      use EHLS
      defhls inc(x :: u8) :: u8 do
        x + 1
      end
      definstance here(x) do
        x |> map(&inc/1)
      end
      definstance there(x), on: :fpga do
        x |> map(&inc/1)
      end
    end
    """)

    assert MixedDefaults.here([1]) == [2]
    assert_raise ArgumentError, ~r/runs on a board/, fn -> MixedDefaults.there([1]) end
  end

  test "what does not run on the CPU yet says so" do
    msg = fn body ->
      assert_raise(CompileError, fn ->
        compile("""
        defmodule NotYet#{System.unique_integer([:positive])} do
          use EHLS
          defhls inc(x :: u8) :: u8 do
            x + 1
          end
          defhls add(a :: u8, b :: u8) :: u8 do
            a + b
          end
          #{body}
        end
        """)
      end).description
    end

    assert msg.("definstance t do\nusb_bulk_in() |> map(&inc/1)\nend") =~ "the source usb_bulk_in does not run on the CPU yet"
    assert msg.("definstance t(x) do\nx |> map(&inc/1) |> hold(:v) |> map(&inc/1)\nend") =~ "the block hold in the middle of a pipe does not run on the CPU yet"
    assert msg.("definstance t(x) do\nx |> map(&inc/1, on: :fpga)\nend") =~ "on: :fpga in an instance on the CPU is not there yet"
    assert msg.("definstance t(x), on: :gpu do\nx |> map(&inc/1)\nend") =~ "on: is :cpu or :fpga"
  end

  test "a stage's on: :fpga in an instance in the FPGA is where it is" do
    compile("""
    defmodule FpgaStageOn do
      use EHLS
      defhls inc(x :: u8) :: u8 do
        x + 1
      end
      defhls count(x :: u8, n :: u8) :: {u8, u8} do
        {x + n, n + 1}
      end
      definstance there(x), on: :fpga do
        x |> map(&inc/1, on: :fpga) |> transform(0, &count/2, on: :fpga, name: :n)
      end
    end
    """)

    assert_raise ArgumentError, ~r/runs on a board/, fn -> FpgaStageOn.there([1]) end
  end

  test "an instance in the FPGA wiring an instance of levels on the CPU says where that one is" do
    msg =
      assert_raise(CompileError, fn ->
        compile("""
        defmodule LevelOnCpu do
          use EHLS
          defhls scale(x :: u8, k :: u8) :: u16 do
            x * k
          end
          definstance gain(k :: u8), initial: 3 do
            k
          end
          definstance there(x), on: :fpga do
            x |> map(&scale(&1, gain(:value)))
          end
        end
        """)
      end).description

    assert msg =~ "gain runs on the CPU"
  end

  test "sinks: hold(name) keeps the latest element, read by :value; run() keeps nothing" do
    CpuInst.last_sum(:start)
    assert CpuInst.last_sum(:value, :last) == 0
    assert CpuInst.last_sum([1, 2]) == :ok
    assert CpuInst.last_sum(:value, :last) == 6
    # an empty call leaves it
    assert CpuInst.last_sum([]) == :ok
    assert CpuInst.last_sum(:value, :last) == 6
    assert CpuInst.last_sum(:state, :sum) == 6
    assert CpuInst.dropped([1, 2, 3]) == :ok
    assert_raise ErlangError, ~r/no_hold_stage/, fn -> CpuInst.last_sum(:value, :nope) end
  end

  test ":state reads a named transform's state as it goes" do
    CpuInst.named(:start)
    assert CpuInst.named(:state, :acc) == 5
    assert CpuInst.named([1, 2]) == [7, 11]
    assert CpuInst.named(:state, :acc) == 11
    assert_raise ErlangError, ~r/no_named_state/, fn -> CpuInst.named(:state, :other) end
  end

  describe "a source on the CPU" do
    setup do
      unless Code.ensure_loaded?(CpuTick) do
        compile("""
        defmodule CpuTick do
          use EHLS

          defhls id(x :: u32) :: u32 do
            x
          end

          defhls low8(x :: u32) :: u8 do
            x &&& 0xFF
          end

          defhls count(_x :: u32, n :: u32) :: {u32, u32} do
            {n + 1, n + 1}
          end

          definstance counter do
            ticks(1000) |> transform(0, &count/2) |> hold(:n)
          end

          definstance counts do
            ticks(1000) |> map(&low8/1)
          end

          # what waits for the CPU is held to 10 elements: the timer waits too, nothing is lost
          definstance small, buffer: 10 do
            ticks(1000) |> map(&id/1)
          end

          # or the counts go on and what does not fit is dropped
          definstance lossy, buffer: 10, overflow: :drop do
            ticks(1000) |> map(&id/1)
          end

          defhls scale(x :: u32, k :: u8) :: u32 do
            x * k
          end

          # a level of another module, found only when the circuits are put together: on the CPU, read at run time,
          # and there is no such module: the stage fails
          definstance failing do
            ticks(1000) |> map(&scale(&1, NoSuchModule.k(:value)))
          end

          definstance quiet do
            ticks(1000) |> transform(0, &count/2) |> hold(:n)
          end
        end
        """)
      end

      :ok
    end

    test "ticks runs from the start, into a hold; :stop stops it" do
      CpuTick.counter(:start)
      Process.sleep(60)
      n = CpuTick.counter(:value, :n)
      assert n > 20
      CpuTick.counter(:stop)
      m = CpuTick.counter(:value, :n)
      Process.sleep(30)
      assert CpuTick.counter(:value, :n) == m
    end

    test "f(:out, n) takes the next n, in order; f(:request, :out, n) sends them, packed" do
      CpuTick.counts(:start)
      assert CpuTick.counts(:out, 5, as: :list) == [0, 1, 2, 3, 4]
      assert CpuTick.counts(:out, 3) == <<5, 6, 7>>
      assert CpuTick.counts(:request, :out, 2) == :ok
      assert_receive {:counts, :out, <<8, 9>>}, 1000
    end

    test "a caller waiting on an instance whose process dies is told at once" do
      CpuTick.counts(:start)
      me = self()
      spawn(fn ->
        r =
          try do
            CpuTick.counts(:out, 100_000, timeout: 60_000)
          catch
            :error, e -> e
          end

        send(me, {:got, r})
      end)

      Process.sleep(20)
      Process.exit(Process.whereis(:"CpuTick.counts"), :kill)
      assert_receive {:got, {:instance_down, :killed}}, 1000
    end

    test "with the buffer full the source waits: nothing lost" do
      CpuTick.small(:start)
      Process.sleep(60)
      assert CpuTick.small(:out, 25, as: :list) == Enum.to_list(0..24)
    end

    test "a source waits for f(:start); reading does not start it" do
      assert CpuTick.quiet(:value, :n) == 0
      Process.sleep(30)
      assert CpuTick.quiet(:value, :n) == 0
      CpuTick.quiet(:start)
      Process.sleep(30)
      assert CpuTick.quiet(:value, :n) > 0
      CpuTick.quiet(:stop)
    end

    test "overflow: :drop: the counts go on, what does not fit is dropped" do
      CpuTick.lossy(:start)
      Process.sleep(60)
      [first | _] = got = CpuTick.lossy(:out, 10, as: :list)
      assert got == Enum.to_list(first..(first + 9))
      # the next ones come after a gap: dropped while the buffer was full
      [next | _] = CpuTick.lossy(:out, 1, as: :list)
      assert next > first + 10
      CpuTick.lossy(:stop)
    end

    test "a timed-out f(:out) leaves nothing late in the mailbox; :stop answers what waits" do
      CpuTick.small(:start)
      # more than come in 50 ms: a time-out, the asker forgotten
      assert_raise ErlangError, ~r/timeout/, fn -> CpuTick.small(:out, 100_000, timeout: 50) end
      Process.sleep(30)
      refute_received {_, {:ok, _}}
      # a stopped instance answers at once
      CpuTick.small(:stop)
      assert CpuTick.small(:out, 5) == {:error, :stopped}
      CpuTick.small(:start)
      task = Task.async(fn -> CpuTick.small(:out, 100_000, timeout: 2000) end)
      Process.sleep(20)
      CpuTick.small(:stop)
      assert Task.await(task) == {:error, :stopped}
    end

    test "a stage that fails under the source stops the instance, which stays" do
      CpuTick.failing(:start)
      Process.sleep(30)
      pid = Process.whereis(:"CpuTick.failing")
      assert is_pid(pid)
      assert CpuTick.failing(:out, 1, timeout: 500) == {:error, :stopped}
      assert Process.whereis(:"CpuTick.failing") == pid
    end

    test "what ticks gives must fit the first stage" do
      assert_raise CompileError, ~r/u32 goes into narrow, which takes u8/, fn ->
        compile("""
        defmodule CpuTickNarrow do
          use EHLS
          defhls narrow(x :: u8) :: u8 do
            x
          end
          definstance t do
            ticks(10) |> map(&narrow/1)
          end
        end
        """)
      end
    end
  end

  describe "levels on the CPU" do
    setup do
      unless Code.ensure_loaded?(CpuLvl) do
        compile("""
        defmodule CpuLvl do
          use EHLS

          defhls scale(x :: u8, k :: u8) :: u16 do
            x * k
          end

          defhls add(a :: u8, b :: u8) :: u9 do
            a + b
          end

          definstance gain(k :: u8), initial: 3 do
            k
          end

          definstance sum2(a :: u8, b :: u8) do
            add(a, b)
          end

          # a level wired into a stage: read once per call
          definstance scaled(x) do
            x |> map(&scale(&1, gain(:value)))
          end

          definstance doubled(x) do
            x |> map(&scale(&1, 2))
          end
        end
        """)
      end

      :ok
    end

    test "an instance of levels: a call computes and holds, :value reads, initial: at the start" do
      CpuLvl.gain(:start)
      assert CpuLvl.gain(:value) == 3
      assert CpuLvl.gain(5) == 5
      assert CpuLvl.gain(:value) == 5
      assert CpuLvl.gain(7, wait: false) == :ok
      assert CpuLvl.gain(:value) == 7
      assert CpuLvl.sum2(200, 100) == 300
      # the argument cut to its type, as in the circuit
      assert CpuLvl.gain(258) == 2
    end

    test "a level wired into a stage of an instance on the CPU" do
      CpuLvl.gain(:start)
      assert CpuLvl.scaled([1, 2]) == [3, 6]
      CpuLvl.gain(10)
      assert CpuLvl.scaled([1, 2]) == [10, 20]
      assert CpuLvl.doubled([4]) == [8]
    end
  end

  describe "joins and forks on the CPU" do
    setup do
      unless Code.ensure_loaded?(CpuGraph) do
        compile("""
        defmodule CpuGraph do
          use EHLS

          defhls mix(a :: s16, b :: s16) :: s17 do
            a + b
          end

          defhls half(x :: s17) :: s16 do
            x >>> 1
          end

          defhls neg(x :: s16) :: s16 do
            -x
          end

          defhls smooth(x :: s16, y :: s16) :: {s16, s16} do
            {(x + y) >>> 1, x}
          end

          defhls low8(x :: s16) :: u8 do
            x &&& 0xFF
          end

          defhls scale3(x :: s16) :: s18 do
            x * 3
          end

          defhls every_other(x :: s16, 1 :: u1) :: {[s16], u1} do
            {[x], 0}
          end

          defhls every_other(_x :: s16, _n :: u1) :: {[s16], u1} do
            {[], 1}
          end

          # two streams, one element of each together
          definstance mixer(left, right) do
            zip_with(left, right, &mix/2) |> map(&half/1)
          end

          # joins anywhere: (a, b) joined, then with -c
          definstance three(a, b, c) do
            a |> mix(b) |> half() |> mix(c |> neg()) |> half()
          end

          # a stream named and used twice is a fork; one branch into a sink
          definstance tapped(x) do
            y = x |> transform(0, &smooth/2)
            y |> map(&low8/1) |> hold(:last)
            y |> map(&scale3/1)
          end

          # a side giving fewer elements: the other side's wait for the next call
          definstance uneven(a, b) do
            a |> transform(0, &every_other/2) |> zip_with(b, &mix/2)
          end
        end
        """)
      end

      :ok
    end

    test "zip_with: one element of each side together; the call form f(a, b) too" do
      assert CpuGraph.mixer([2, 4, -6], [10, 20, 30]) == [6, 12, 12]
      # (1 + 3) / 2 = 2, then (2 + -10) / 2 = -4
      assert CpuGraph.three([1], [3], [10]) == [-4]
    end

    test "a binary for each side, a binary out" do
      assert CpuGraph.mixer(<<2::little-signed-16>>, <<10::little-signed-16>>) == <<6::little-signed-16>>
    end

    test "a fork: the same elements to both branches, a branch into hold" do
      CpuGraph.tapped(:start)
      # smooth: (x + previous) / 2 from 0: 2, 5, 7
      assert CpuGraph.tapped([4, 6, 8]) == [6, 15, 21]
      assert CpuGraph.tapped(:value, :last) == 7
    end

    test "what one side of a join has more waits for the next call" do
      CpuGraph.uneven(:start)
      # every_other from state 0 gives the 2nd and 4th of a: 20 and 40, joined with 1 and 2
      assert CpuGraph.uneven([10, 20, 30, 40], [1, 2, 3]) == [21, 42]
      # b's 3 waited; a gives 60 (the 2nd of 50, 60)
      assert CpuGraph.uneven([50, 60], [4]) == [63]
    end

    test "an argument used twice, an expression before the last not ending in a sink" do
      msg = fn body ->
        assert_raise(CompileError, fn ->
          compile("""
          defmodule CpuGraphBad#{System.unique_integer([:positive])} do
            use EHLS
            defhls mix(a :: s16, b :: s16) :: s17 do
              a + b
            end
            defhls half(x :: s17) :: s16 do
              x >>> 1
            end
            #{body}
          end
          """)
        end).description
      end

      assert msg.("definstance t(a) do\nzip_with(a, a, &mix/2)\nend") =~ "a goes in twice"
      assert msg.("definstance t(a, b) do\nzip_with(a, b, &mix/2)\na |> map(&half/1)\nend") =~ "only the last expression goes to the CPU"
      assert msg.("definstance t(a, b) do\nzip_with(a, a, &mix/2)\nend") =~ "goes in twice"
      assert msg.("definstance t(a, b) do\na |> map(&half/1)\nend") =~ "nothing happens to b"
    end
  end
end
