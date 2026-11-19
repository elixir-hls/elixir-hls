defmodule EHLS.GPIOTest do
  use ExUnit.Case

  defmodule Regs do
    # the runtime backend, its registers in an Agent-less process dictionary
    def reg_write(r, v) do
      Process.put(:writes, [{r, v} | Process.get(:writes, [])])
      :ok
    end

    def reg_read(_r), do: Process.get(:in, 0)
  end

  @opts [out: [relay: "j5:3"], in: [door: {"j5:4", pull: :up}], inout: [sda: {"j5:5", pull: :up, active_low: true}]]

  setup_all do
    table = EHLS.GPIO.table(EHLS.GPIO.options(@opts))
    regs = EHLS.GPIO.registers() |> Map.keys() |> Enum.sort() |> Enum.with_index() |> Map.new()

    Module.create(
      :hw_kernels,
      quote do
        def runtime, do: EHLS.GPIOTest.Regs
        def reg(:ehls_gpio, r), do: Map.fetch!(unquote(Macro.escape(regs)), r)
        def data(:ehls_gpio, k), do: Map.get(unquote(Macro.escape(table)), k, :undefined)
      end,
      Macro.Env.location(__ENV__)
    )

    on_exit(fn ->
      :code.purge(:hw_kernels)
      :code.delete(:hw_kernels)
    end)

    {:ok, regs: regs}
  end

  defp writes, do: Process.get(:writes, [])

  test "options: bits in order, directions, pulls" do
    %{pins: pins} = EHLS.GPIO.options(@opts)
    assert Enum.map(pins, &{&1.name, &1.bit, &1.dir, &1.pull}) ==
             [{:relay, 0, :out, :none}, {:door, 1, :in, :up}, {:sda, 2, :inout, :up}]

    assert Enum.find(pins, &(&1.name == :sda)).active_low
  end

  test "options that cannot be built raise" do
    for {opts, msg} <- [
          {[nope: []], ~r/unknown option/},
          {[out: [a: {"j5:1", pull: :up}]], ~r/an output takes no pull/},
          {[in: [a: {"j5:1", pull: :sideways}]], ~r/pull/},
          {[in: [a: {"j5:1", speed: 1}]], ~r/unknown option/},
          {[in: [a: "j5:1"], out: [a: "j5:2"]], ~r/same name twice/},
          {[in: [a: "j5:1"], out: [b: "j5:1"]], ~r/same pin twice/},
          {[in: for(i <- 0..32, do: {:"p#{i}", "x:#{i}"})], ~r/at most 32/},
          {[board: [:led0]], ~r/no parts/}
        ] do
      assert_raise ArgumentError, msg, fn -> EHLS.GPIO.options(opts) end
    end
  end

  test "board names come from the target's description" do
    file = Path.join(System.tmp_dir!(), "ehls_board_gpio_test.json")
    File.write!(file, ~s({"led0": {"dir": "out", "pin": "J1:17"}, "b": {"dir": "in", "pin": "J1:37", "pull": "down"}}))
    System.put_env("EHLS_BOARD_GPIO", file)

    try do
      %{pins: [a, b]} = EHLS.GPIO.options(board: [:led0, :b])
      assert {a.name, a.dir, a.pin, a.board} == {:led0, :out, "J1:17", true}
      assert {b.dir, b.pull} == {:in, :down}
      assert_raise ArgumentError, ~r/no part :x/, fn -> EHLS.GPIO.options(board: [:x]) end
    after
      System.delete_env("EHLS_BOARD_GPIO")
      File.rm(file)
    end
  end

  test "a write goes to the set or clear register, one bit", %{regs: r} do
    assert EHLS.GPIO.write(:relay, 1) == :ok
    assert EHLS.GPIO.write(:sda, 0) == :ok
    assert writes() == [{r.out_clr, 4}, {r.out_set, 1}]
  end

  test "direction: an inout only", %{regs: r} do
    assert EHLS.GPIO.direction(:sda, :out) == :ok
    assert EHLS.GPIO.direction(:sda, :in) == :ok
    assert writes() == [{r.oe_clr, 4}, {r.oe_set, 4}]
    assert EHLS.GPIO.direction(:door, :out) == {:error, {:not_inout, :door}}
    assert EHLS.GPIO.direction(:relay, :in) == {:error, {:not_inout, :relay}}
  end

  test "read takes the pin's bit" do
    Process.put(:in, 0b010)
    assert {EHLS.GPIO.read(:relay), EHLS.GPIO.read(:door), EHLS.GPIO.read(:sda)} == {0, 1, 0}
  end

  test "errors at run time" do
    assert EHLS.GPIO.write(:door, 1) == {:error, {:input_pin, :door}}
    assert EHLS.GPIO.write(:nope, 1) == {:error, {:no_pin, :nope}}
    assert EHLS.GPIO.read(:nope) == {:error, {:no_pin, :nope}}
  end

  test "literal names that cannot work are found in the sources" do
    table = %{relay: {0, :out}, door: {1, :in}, sda: {2, :inout}}

    src = """
    defmodule A do
      alias EHLS.GPIO
      def ok(n) do
        EHLS.GPIO.write(:relay, 1)
        EHLS.GPIO.read(:door)
        GPIO.direction(:sda, :out)
        EHLS.GPIO.write(n, 1)
      end

      def bad do
        EHLS.GPIO.write(:door, 1)
        GPIO.write(:nope, 1)
        EHLS.GPIO.direction(:relay, :in)
        EHLS.GPIO.write(:relay, 2)
      end
    end
    """

    found = EHLS.GPIO.check_source("a.ex", src, table)
    assert Enum.map(found, &elem(&1, 1)) == [11, 12, 13, 14]
    assert [{_, _, m} | _] = found
    assert m =~ "is an input"
  end

  test "the package's description for the manifest" do
    d = EHLS.Blocks.describe(EHLS.GPIO, @opts)
    assert d.gateware == "ehls_gpio"
    assert d.table[:door] == [1, "in"]
    assert %{name: :out_set, mode: :w} in d.registers
    assert JSON.encode!(d) =~ ~s("pull":"up")
  end

  describe "pins in pipelines" do
    defp compile_pipeline(stage) do
      System.put_env("EHLS_SOC", "litex")

      try do
        Code.compile_string("""
        defmodule PipeCase#{System.unique_integer([:positive])} do
          use EHLS, blocks: [{EHLS.GPIO, in: [b: "x:1"], out: [l: "x:2"]}]
          defhls count(_p :: u1, n :: u16) :: {u16, u16} do
            {n + 1, n + 1}
          end
          definstance p do
            #{stage}
          end
        end
        """)
      after
        System.delete_env("EHLS_SOC")
      end
    end

    test "changes, hold, sample and pin_out compile" do
      assert [{_, _}] = compile_pipeline("changes(:b, :rising) |> transform(0, &count/2) |> hold(:count)")
      assert [{_, _}] = compile_pipeline("ticks(1000) |> sample(:b) |> transform(0, &count/2) |> pin_out(:l)")
    end

    test "a source that cannot wait, into a stage on the CPU, needs overflow: :drop" do
      cut = fn opts ->
        System.put_env("EHLS_SOC", "litex")

        try do
          Code.compile_string("""
          defmodule CutPin#{System.unique_integer([:positive])} do
            use EHLS, blocks: [{EHLS.GPIO, in: [b: "x:1"], out: [l: "x:2"]}]
            defhls count(_p :: u1, n :: u16) :: {u16, u16} do
              {n + 1, n + 1}
            end
            defhls big(x :: u16) :: u16 do
              x * 3
            end
            definstance p#{opts} do
              changes(:b, :rising) |> transform(0, &count/2) |> map(&big/1, on: :cpu)
            end
          end
          """)
        after
          System.delete_env("EHLS_SOC")
        end
      end

      assert_raise CompileError, ~r/definstance p: its source cannot wait until the CPU stage reads.*write overflow: :drop/, fn -> cut.("") end
      assert [{_, _}] = cut.(", overflow: :drop")
    end

    test "a pin a pipeline drives is no more the CPU's" do
      assert EHLS.GPIO.stage_table(:pin_out, [:l], %{l: [3, "out"]}) == %{l: [3, "stage"]}
      assert EHLS.GPIO.stage_table(:sample, [:l], %{l: [3, "out"]}) == %{}
      [{_, _, m}] = EHLS.GPIO.check_source("a.ex", "EHLS.GPIO.write(:l, 1)", %{l: {3, :stage}})
      assert m =~ "driven by a pipeline"
    end

    test "what cannot work stops the compile" do
      for {stage, msg} <- [
            {"changes(:nope, :rising) |> transform(0, &count/2) |> hold(:c)", ~r/no pin :nope/},
            {"changes(:l, :rising) |> transform(0, &count/2) |> hold(:c)", ~r/:l is an output/},
            {"changes(:b, :up) |> transform(0, &count/2) |> hold(:c)", ~r/edge :up/},
            {"changes(:b, :rising) |> transform(0, &count/2) |> hold(1)", ~r/hold\(name\)/},
            {"ticks(10) |> sample(:nope) |> hold(:c)", ~r/sample: no pin :nope/},
            # a source that cannot wait, with a stream to the CPU
            {"changes(:b, :rising) |> transform(0, &count/2)", ~r/cannot wait until the CPU reads: write overflow: :drop/},
            {"changes(:b, :rising) |> pin_out(:b)", ~r/:b is not an output/},
            {"changes(:b, :rising) |> pin_out(:nope)", ~r/pin_out: no pin :nope/},
            # a level wired to a firing input
            {"ticks(10) |> hold(:c) |> transform(0, &count/2)", ~r/hold gives a level, which cannot fire count/},
            {"ticks(10) |> hold(:c) |> pin_out(:l)", ~r/hold gives a level, which cannot fire pin_out/},
            # what has no way to start or to finish would stand still without a word
            {"sample(:b) |> hold(:c)", ~r/sample takes a stream, and nothing comes before it/},
            {"transform(0, &count/2) |> hold(:c)", ~r/count takes a stream, and nothing comes before it/},
            {"hold(:c)", ~r/hold takes a stream, and nothing comes before it/},
            {"ticks(10) |> pin_out(:l) |> hold(:c)", ~r/pin_out must come last/},
            {"ticks(10) |> ticks(10) |> hold(:c)", ~r/ticks must come first/}
          ] do
        assert_raise CompileError, msg, fn -> compile_pipeline(stage) end
      end
    end
  end
end
