defmodule FakeLevel do
  @moduledoc false
  # a runtime backend's level_start / peek, as a circuit that computes after `delay` peeks
  # (:never: never; :stopped: the instance is stopped)
  import Bitwise

  def reset(f, delay), do: Process.put(:fake_level, %{f: f, delay: delay, issued: 0, done: 0, result: [], writes: [], left: 0, next: nil})
  def writes, do: Process.get(:fake_level).writes |> Enum.reverse()

  def level_start(level, pipe, words) do
    st = Process.get(:fake_level)

    if st.delay == :stopped do
      :stopped
    else
      {a, b} = st.f.(words)
      result = for v <- [a, b], w <- [v &&& 0xFFFFFFFF, v >>> 32 &&& 0xFFFFFFFF], do: w
      left = if st.delay == :never, do: :infinity, else: st.delay
      Process.put(:fake_level, %{st | issued: st.issued + 1, writes: [{level, pipe, words} | st.writes], next: result, left: left})
      st.issued + 1
    end
  end

  def peek(_peek, n) do
    st = Process.get(:fake_level)

    st =
      cond do
        st.left == :infinity -> st
        st.left <= 1 and st.next != nil -> %{st | done: st.issued, result: st.next, left: 0}
        true -> %{st | left: st.left - 1}
      end

    Process.put(:fake_level, st)
    words = [st.done | st.result]
    words ++ List.duplicate(0, n - length(words))
  end
end

defmodule EHLSTest do
  use ExUnit.Case
  import Bitwise

  @tmp Path.expand("../_build/test_out", __DIR__)

  # the cases compiled with EHLS_OUT_DIR set: their MLIR / .sig files and their CPU functions
  setup_all do
    File.rm_rf!(@tmp)
    System.put_env("EHLS_OUT_DIR", Path.join(@tmp, "hw"))
    Code.require_file("cases/defhls_cases.ex", __DIR__)
    Code.require_file("cases/defhls_mem_cases.ex", __DIR__)
    System.delete_env("EHLS_OUT_DIR")
    :ok
  end

  test "a call in a definstance is the same as the pipe, as in Elixir" do
    norm = fn src -> src |> Code.string_to_quoted!() |> EHLS.Pipeline.normalize() |> Macro.to_string() end
    assert norm.("f(words)") == "words |> f()"
    assert norm.("g(f(words), 3)") == "words |> f() |> g(3)"
    assert norm.("f(ticks(1000))") == "ticks(1000) |> f()"
    assert norm.("g(words |> f())") == "words |> f() |> g()"
    # what is not a stream as the first argument stays
    for src <- ["ticks(1000)", "transform(0, &f/2)", "transform({0, 0, 0}, &f/2)", "map(&f/1)", "sample(:button0)", "transform(@init, &f/2)"],
        do: assert(norm.(src) == src)

    pipeline = fn body ->
      mod = "CallFormCase#{System.unique_integer([:positive])}"
      hw = Path.join(@tmp, "callform_#{mod}")
      File.rm_rf!(hw)

      with_env(%{"EHLS_SOC" => "litex", "EHLS_OUT_DIR" => hw}, fn ->
        Code.compile_string("""
        defmodule #{mod} do
          use EHLS
          defhls g(x :: u32) :: u32 do
            x + 1
          end
          defhls h(x :: u32) :: u16 do
            x
          end
          defhls gh(x :: stream(u32)) :: stream(u16) do
            h(g(x))
          end
          definstance i(words) do
            #{body}
          end
        end
        """)
      end)

      p = Path.wildcard(Path.join(hw, "*.pipeline")) |> hd() |> File.read!() |> JSON.decode!()
      # the same but for the module's name in the kernels'
      p |> Map.take(["stages", "links", "input", "input_type", "output_type"]) |> JSON.encode!() |> String.replace(~r/call_form_case\d+_/, "")
    end

    piped = pipeline.("words |> map(&g/1) |> map(&h/1)")
    assert pipeline.("words |> gh()") == piped
    assert pipeline.("gh(words)") == piped
    assert pipeline.("h(g(words))") == piped
  end

  test "without a runtime backend an instance can be called from its module, and the call says where it runs" do
    mod = "NoRuntimeCase#{System.unique_integer([:positive])}"

    [{m, _}] =
      Code.compile_string("""
      defmodule #{mod} do
        use EHLS
        defhls g(x :: u32) :: u32 do
          x + 1
        end
        definstance g_hw(words) do
          words |> map(&g/1)
        end
        def start, do: g_hw([1, 2])
      end
      """)

    assert m.g([1, 2] |> hd()) == 2
    assert_raise ArgumentError, ~r/g_hw: an instance runs on a board/, fn -> m.start() end
    assert_raise ArgumentError, ~r/mix ehls.sim/, fn -> m.g_hw(:out, 4) end
    assert_raise ArgumentError, ~r/runs on a board/, fn -> m.g_hw(:request, :out, 4) end
  end

    test "EHLS.Check packs values as a scalar's bytes" do
    Code.require_file("../priv/backend/atomvm/lib/hls_check.ex", __DIR__)
    assert apply(EHLS.Check, :to_binary, [[1, 0x0102]]) == <<1, 0, 0, 0, 2, 1, 0, 0>>
    assert apply(EHLS.Check, :to_binary, [[1, -2], 2]) == <<1, 0, 0xFE, 0xFF>>
    assert apply(EHLS.Check, :to_binary, [[7], 1]) == <<7>>
  end

  test "at the CPU each scalar takes 1, 2, 4 or 8 bytes, a tuple left to right" do
    for {spec, bytes} <- [
          {{8, false}, 1},
          {{1, false}, 1},
          {{16, true}, 2},
          {{18, true}, 4},
          {{32, false}, 4},
          {{48, false}, 8},
          {{:tuple, [{16, true}, {16, true}]}, 4},
          {{:tuple, [{18, true}, {20, true}]}, 8},
          {{:tuple, [{8, false}, {16, true}]}, 3},
          {{:emit, {8, false}}, 1},
          {:any, 4},
          {nil, 4}
        ],
        do: assert(EHLS.packed_size(spec) == bytes)
  end

  test "defhls writes MLIR and a signature per kernel" do
    hw = Path.join(@tmp, "hw")
    assert File.exists?(Path.join(hw, "defhls_cases_mix.mlir"))
    sig = Path.join(hw, "defhls_cases_mix.sig") |> File.read!() |> JSON.decode!()
    assert sig["arg"] == "u32" and sig["ret"] == "u32" and sig["state"] == []
    assert File.read!(Path.join(hw, "defhls_cases_mix.mlir")) =~ "func.func @defhls_cases_mix"
  end

  test "the CPU function wraps its argument and result to their types" do
    # wrap8(x :: u8) :: s8
    for x <- [0, 1, 127, 128, 255, 256, -1] do
      y = DefhlsCases.wrap8(x)
      assert y in -128..127
    end

    assert DefhlsCases.mix(0x0001_0000) == DefhlsCases.mix(0x1_0001_0000)
  end

  test "a function with a tuple in its state steps on the CPU as written" do
    {y, {1, hist}} = DefhlsMemCases.fir4(1, {0, Tuple.duplicate(0, 8)})
    assert y == 1 and elem(hist, 0) == 1
  end

  test "block package options become JSON maps" do
    assert EHLS.Blocks.json_options(pins: [dout: "j5:7"]) == %{"pins" => %{"dout" => "j5:7"}}
    assert EHLS.Blocks.json_options([]) == []
  end

  test "the backends come from the environment: generic device, no SoC, no runtime by default" do
    assert EHLS.Backend.check!() == {EHLS.Device.Generic, nil, nil}
    assert EHLS.runtime() == nil and EHLS.Blocks.defaults() == []
    # CPU only: no hardware clauses
    assert_raise FunctionClauseError, fn -> DefhlsCases.mix(<<1, 0, 0, 0>>) end

    with_env(%{"EHLS_DEVICE" => "gowin_gw5a", "EHLS_SOC" => "litex", "EHLS_RUNTIME" => "atomvm"}, fn ->
      assert EHLS.Backend.check!() == {EHLS.Device.GowinGW5A, EHLS.SoC.LiteX, EHLS.Runtime.AtomVM}
      assert EHLS.runtime() == :hwstream
      assert EHLS.Blocks.defaults() == [EHLS.SoC.LiteX.Blocks]
    end)

    # the AtomVM runtime needs the LiteX SoC
    with_env(%{"EHLS_RUNTIME" => "atomvm"}, fn ->
      assert_raise ArgumentError, ~r/needs a SoC backend/, fn -> EHLS.Backend.check!() end
    end)

    with_env(%{"EHLS_SOC" => "nope"}, fn ->
      assert_raise ArgumentError, ~r/EHLS_SOC=nope/, fn -> EHLS.Backend.soc() end
    end)
  end

  test "a block package for another SoC backend stops the compile" do
    defmodule OtherSoCBlocks do
      @behaviour EHLS.Blocks
      def soc, do: :other
      def blocks, do: %{}
      def peripherals, do: []
      def gateware, do: "x"
    end

    assert EHLS.Blocks.check_soc!([OtherSoCBlocks]) == :ok

    with_env(%{"EHLS_SOC" => "litex"}, fn ->
      assert_raise ArgumentError, ~r/for the SoC backend :other/, fn -> EHLS.Blocks.check_soc!([OtherSoCBlocks]) end
      assert EHLS.Blocks.check_soc!([EHLS.SoC.LiteX.Blocks]) == :ok
    end)
  end

  test "with a runtime backend, a defhls stays a function: a binary is no call of a circuit" do
    with_env(%{"EHLS_SOC" => "litex", "EHLS_RUNTIME" => "atomvm"}, fn ->
      Code.compile_string("""
      defmodule RuntimeCase do
        use EHLS
        defhls inc(x :: u32) :: u32 do
          x + 1
        end
      end
      """)
    end)

    assert RuntimeCase.inc(1) == 2
    assert_raise FunctionClauseError, fn -> RuntimeCase.inc(<<1, 0, 0, 0>>) end
  end

  describe "errors" do
    defp compile_error(source, env \\ %{"EHLS_SOC" => "litex"}) do
      with_env(env, fn ->
        try do
          Code.compile_string(source, "errors.ex")
          flunk("compiled: #{source}")
        rescue
          e in CompileError -> Exception.message(e)
        end
      end)
    end

    defp hw_env, do: %{"EHLS_SOC" => "litex", "EHLS_OUT_DIR" => Path.join(@tmp, "errors")}

    test "at the line of the expression that cannot become a circuit" do
      message =
        compile_error(
          """
          defmodule ErrorCase1 do
            use EHLS
            defhls f(x :: u32) :: u32 do
              y = x + 1
              rem(y, 3)
            end
          end
          """,
          hw_env()
        )

      assert message =~ "errors.ex:5:"
      assert message =~ "cannot call rem/2"
    end

    test "at the line of the stage" do
      message =
        compile_error("""
        defmodule ErrorCase2 do
          use EHLS
          defhls f(x :: u32) :: u32 do
            x
          end
          definstance i do
            ticks(10)
            |> map(&f/1)
            |> nope()
            |> hold(:v)
          end
        end
        """)

      assert message =~ "errors.ex:9:"
      assert message =~ "nope is neither"

      message =
        compile_error("""
        defmodule ErrorCase3 do
          use EHLS
          defhls f(x :: u32) :: u32 do
            x
          end
          definstance i do
            ticks(10)
            |> hold(:v)
            |> map(&f/1)
          end
        end
        """)

      assert message =~ "errors.ex:9:"
      assert message =~ "gives a level"
    end

    test "at the definition when it is about all of it" do
      message =
        compile_error("""
        defmodule ErrorCase4 do
          use EHLS

          definstance i, buffer: -1 do
            ticks(10)
          end
        end
        """)

      assert message =~ "errors.ex:4:"

      message =
        compile_error("""
        defmodule ErrorCase5 do
          use EHLS

          defhls f(x :: u99) :: u32 do
            x
          end
        end
        """)

      assert message =~ "errors.ex:4:"
      assert message =~ "up to 64 bits"
    end
  end

  describe "a defhls calling a defhls" do
    defp calling(source, env \\ %{}) do
      mod = "CallCase#{System.unique_integer([:positive])}"

      with_env(env, fn ->
        Code.compile_string("""
        defmodule #{mod} do
          use EHLS
          #{source}
        end
        """, "calls.ex")
      end)

      Module.concat([mod])
    end

    test "on the CPU, wrapped to the callee's types" do
      m =
        calling("""
        defhls low(x :: u32) :: u8 do
          x
        end
        defhls add(a :: s8, b :: {u4, u4}) :: s8 do
          {c, d} = b
          a + c + d
        end
        defhls f(x :: u32) :: u32 do
          add(low(x), {x, x >>> 4}) + 1000
        end
        """)

      assert m.low(0x1FF) == 0xFF
      assert m.add(127, {1, 0}) == -128
      assert m.add(0x1FF, {0x13, 0}) == 2
      # low(0x7F) == 0x7F, wrapped to s8 at add's argument: 127; +{15, 7} wraps again
      assert m.f(0x7F) == EHLS.signed(127 + 15 + 7, 8) + 1000
    end

    test "in the circuit, the callee's body with its own names" do
      hw = Path.join(@tmp, "calls")
      File.rm_rf!(hw)

      calling(
        """
        @t [1, 2, 3, 4]
        defhls look(i :: u2, x :: u8) :: u8 do
          y = Enum.at(@t, i)
          y + x
        end
        defhls twice(x :: u8) :: u8 do
          y = look(x, x)
          y = look(x, y)
          y
        end
        """,
        %{"EHLS_OUT_DIR" => hw}
      )

      [sig] = Path.wildcard(Path.join(hw, "*twice.sig"))
      # the callee's table came along
      assert JSON.decode!(File.read!(sig))["space"]["regions"] |> Enum.map(& &1["name"]) == ["t"]
      # several arguments: no kernel of its own
      assert Path.wildcard(Path.join(hw, "*look.sig")) == []
    end

    test "what cannot be called stops the compile" do
      for {source, msg} <- [
            {"defhls f(x :: u8) :: u8 do\nf(x)\nend", ~r/calls.ex:\d+: defhls f: it calls itself/},
            {"defhls s(x :: u8, n :: u8) :: {[u8], u8} do\n{[x], n}\nend\ndefhls f(x :: u8) :: u8 do\ns(x, x)\nend",
             ~r/cannot call s, which has a state/},
            {"defhls a(x :: u8, y :: u8) :: u8 do\nx + y\nend\ndefhls f(x :: u8) :: u8 do\na(x)\nend", ~r/a takes 2 argument/},
            {"defhls a(x :: u8, y :: u8) :: u8 do\nx + y\nend\ndefinstance i do\nticks(1) |> map(&a/2) |> run()\nend",
             ~r/a takes 2 arguments: transform\(init, &a\/2\)/}
          ] do
        assert_raise CompileError, msg, fn -> calling(source, %{"EHLS_SOC" => "litex"}) end
      end
    end
  end

  describe "case, cond, clauses and wide values" do
    defp syntax(source, env \\ %{}) do
      mod = "SyntaxCase#{System.unique_integer([:positive])}"

      with_env(env, fn ->
        Code.compile_string("""
        defmodule #{mod} do
          use EHLS
          #{source}
        end
        """, "syntax.ex")
      end)

      Module.concat([mod])
    end

    test "several clauses on the CPU, a callee defined below its caller" do
      m =
        syntax("""
        defhls f(x :: u8) :: u8 do
          g(x) + 1
        end
        defhls g(0 :: u8) :: u8 do
          200
        end
        defhls g(x :: u8) :: u8 when x < 16 do
          x * 2
        end
        defhls g(x :: u8) :: u8 do
          x >>> 1
        end
        """)

      assert m.g(0) == 200 and m.g(3) == 6 and m.g(32) == 16
      assert m.f(0) == 201
    end

    test "a circuit needs a value for every input" do
      hw = %{"EHLS_OUT_DIR" => Path.join(@tmp, "syntax")}

      for {source, msg} <- [
            {"defhls f(x :: u8) :: u8 do\ncase x do\n0 -> 1\n1 -> 2\nend\nend", ~r/syntax.ex:6: case: the last clause must match everything/},
            {"defhls f(x :: u8) :: u8 do\ncond do\nx > 1 -> 1\nend\nend", ~r/cond: the last clause must be true/},
            {"defhls g(0 :: u8) :: u8 do\n1\nend\ndefhls g(1 :: u8) :: u8 do\n2\nend", ~r/the last clause must match everything/},
            {"defhls f(x :: u8) :: u8 do\ncase x do\n[] -> 1\n_ -> 2\nend\nend", ~r/cannot match \[\]/}
          ] do
        assert_raise CompileError, msg, fn -> syntax(source, hw) end
      end
    end

    test "what cannot be merged or called stops the compile" do
      for {source, msg} <- [
            {"defhls f(0 :: u8) :: u8 do\n1\nend\ndefhls f(x :: u16) :: u8 do\nx\nend", ~r/syntax.ex:\d+: defhls f: every clause has the same types/},
            {"defhls f(x :: u8) :: u8 do\ng(x)\nend\ndefhls g(x :: u8) :: u8 do\nf(x)\nend", ~r/it calls itself, through/},
            {"defhls f(x :: u8, m :: tuple(u8, 4)) :: {u8, tuple(u8, 4)} when x > 1 do\n{x, m}\nend", ~r/a function with a tuple\(t, n\) in its state has one clause/},
            {"defhls f(x :: u99) :: u8 do\nx\nend", ~r/up to 64 bits/},
            {"defhls f(x :: u8, n :: u40) :: {[u8], u40} do\n{[x], n}\nend", ~r/a state, a level or a memory is up to 32 bits/},
            {"defhls f(x :: u8, n :: u8, p :: u40) :: {[u8], u8} do\n{[x], n}\nend", ~r/up to 32 bits/},
            {"defhls f(x :: u8, n :: u40) :: {u8, u40} do\n{x, n}\nend\ndefinstance i(s) do\ns |> transform(0, &f/2)\nend",
             ~r/the state of f \(u40\) is up to 32 bits/}
          ] do
        assert_raise CompileError, msg, fn -> syntax(source) end
      end
    end

    test "a kernel with a value over 32 bits has 64-bit ports" do
      hw = Path.join(@tmp, "wide")
      File.rm_rf!(hw)

      m =
        syntax(
          """
          defhls mul48(a :: u24, b :: u24) :: u48 do
            a * b
          end
          defhls wider(x :: u40) :: u40 do
            x + 1
          end
          defhls k(x :: u32) :: u32 do
            wider(mul48(x, 1000)) >>> 8
          end
          """,
          %{"EHLS_OUT_DIR" => hw}
        )

      assert m.wider(0xFF_FFFF_FFFF) == 0
      assert m.k(0xFFFFFF) == Bitwise.bsr(0xFFFFFF * 1000 + 1, 8)
      # mul48 takes two arguments, so only other functions call it; wider and k are kernels
      lanes = for f <- Path.wildcard(Path.join(hw, "*.sig")), into: %{}, do: (sig = JSON.decode!(File.read!(f)); {sig["function"], sig["lane"]})
      assert lanes == %{"wider" => 64, "k" => 32}
      [mlir] = Path.wildcard(Path.join(hw, "*_wider.mlir"))
      assert File.read!(mlir) =~ "%arg0: i64"
    end
  end

  describe "types at the links" do
    defp linked(body) do
      mod = "LinkCase#{System.unique_integer([:positive])}"

      with_env(%{"EHLS_SOC" => "litex"}, fn ->
        Code.compile_string("""
        defmodule #{mod} do
          use EHLS
          defhls wide(x :: u32) :: u32 do
            x
          end
          defhls small(x :: u8) :: u8 do
            x
          end
          defhls u16f(x :: u16) :: u16 do
            x
          end
          defhls s16f(x :: s16) :: s16 do
            x
          end
          defhls pair(x :: {u8, u8}) :: {u8, u8} do
            x
          end
          defhls pair16(x :: {u16, s16}) :: {u16, s16} do
            x
          end
          defhls low(x :: u32) :: u8 do
            x
          end
          definstance i(x) do
            #{body}
          end
        end
        """, "links.ex")
      end)
    end

    test "widening that keeps the value goes" do
      assert EHLS.Pipeline.widens?({8, false}, {16, false})
      assert EHLS.Pipeline.widens?({8, false}, {9, true})
      assert EHLS.Pipeline.widens?({16, true}, {18, true})
      refute EHLS.Pipeline.widens?({8, false}, {8, true})
      refute EHLS.Pipeline.widens?({8, true}, {16, false})
      refute EHLS.Pipeline.widens?({16, false}, {8, false})
      assert EHLS.Pipeline.widens?({:tuple, [{8, false}, {8, false}]}, {:tuple, [{16, false}, {16, true}]})
      refute EHLS.Pipeline.widens?({:tuple, [{8, false}]}, {8, false})

      for body <- ["x |> map(&small/1) |> map(&u16f/1)", "x |> map(&small/1) |> map(&s16f/1)", "x |> map(&pair/1) |> map(&pair16/1)",
                   "x |> map(&wide/1) |> map(&low/1)", "x |> map(&wide/1) |> hold(:v)", "x |> map(&small/1) |> run()"] do
        assert [{_, _}] = linked(body)
      end
    end

    test "what would change a value stops the compile, at the consumer's line" do
      for {body, msg} <- [
            {"x\n|> map(&wide/1)\n|> map(&small/1)", ~r/links.ex:\d+: definstance: wide gives u32 and small takes u8, which would change the value/},
            {"x |> map(&s16f/1) |> map(&u16f/1)", ~r/s16f gives s16 and u16f takes u16/},
            {"x |> map(&pair/1) |> map(&small/1)", ~r/pair gives \{u8, u8\} and small takes u8/},
            {"x |> map(&small/1) |> map(&pair/1)", ~r/small gives u8 and pair takes \{u8, u8\}/}
          ] do
        assert_raise CompileError, msg, fn -> linked(body) end
      end
    end

    test "the description has the types" do
      hw = Path.join(@tmp, "linktypes")
      File.rm_rf!(hw)

      with_env(%{"EHLS_SOC" => "litex", "EHLS_OUT_DIR" => hw}, fn ->
        Code.compile_string("""
        defmodule LinkTypesCase do
          use EHLS
          defhls small(x :: u8) :: u8 do
            x
          end
          defhls s(x :: u16) :: s18 do
            x
          end
          definstance i(x) do
            x |> map(&small/1) |> map(&s/1)
          end
        end
        """)
      end)

      p = Path.wildcard(Path.join(hw, "*.pipeline")) |> hd() |> File.read!() |> JSON.decode!()
      assert [%{"type" => "u8"}] = p["links"]
      assert [%{"type" => "u8"}] = p["inputs"]
      assert p["output_type"] == "s18"
    end
  end

  describe "stream functions" do
    defp streams(source, env \\ %{"EHLS_SOC" => "litex"}) do
      mod = "StreamCase#{System.unique_integer([:positive])}"

      with_env(env, fn ->
        Code.compile_string("""
        defmodule #{mod} do
          use EHLS
          defhls double(x :: s16) :: s18 do
            x * 2
          end
          defhls sum(x :: s16, s :: s32) :: {s32, s32} do
            {s + x, s + x}
          end
          defhls scaled(x :: s16, k :: u8) :: s32 do
            x * k
          end
          defhls every2(x :: s16, on :: u1) :: {[s16], u1} do
            if on == 1, do: {[x], 0}, else: {[], 1}
          end
          defhls avg(w :: tuple(s16, 2)) :: s18 do
            elem(w, 0) + elem(w, 1)
          end
          defhls tup(x :: s16) :: {s16, s16} do
            {x, -x}
          end
          #{source}
        end
        """, "streams.ex")
      end)

      Module.concat([mod])
    end

    test "on the CPU: a list in, a list out, from the initial state each call" do
      m =
        streams("""
        defhls doubled(x :: stream(s16)) :: stream(s18) do
          x |> map(&double/1)
        end
        defhls running(x :: stream(s16)) :: stream(s32) do
          x |> transform(0, &sum/2)
        end
        defhls from_ten(x :: stream(s16)) :: stream(s32) do
          x |> transform(10, &sum/2)
        end
        defhls with_level(x :: stream(s16), k :: u8) :: stream(s32) do
          x |> map(&scaled(&1, k))
        end
        defhls halves(x :: stream(s16)) :: stream(s16) do
          x |> transform(0, &every2/2)
        end
        defhls windowed(x :: stream(s16)) :: stream(s18) do
          x |> chunk_every(2, 2, :discard) |> map(&avg/1)
        end
        defhls nested(x :: stream(s16)) :: stream(s32) do
          x |> halves() |> running()
        end
        defhls tuples(x :: stream(s16)) :: stream({s16, s16}) do
          x |> tup()
        end
        """)

      assert m.doubled([1, -2, 3]) == [2, -4, 6]
      assert m.doubled([]) == []
      # wrapped to the argument's type, as a function's
      assert m.doubled([0x18000]) == [-65536]
      assert m.running([1, 2, 3]) == [1, 3, 6]
      assert m.running([1, 2, 3]) == [1, 3, 6]
      assert m.from_ten([1, 2]) == [11, 13]
      assert m.with_level([1, 2], 3) == [3, 6]
      assert m.halves([1, 2, 3, 4, 5]) == [2, 4]
      assert m.windowed([1, 2, 3, 4]) == [3, 7]
      assert m.nested([1, 2, 3, 4]) == [2, 6]
      assert m.tuples([1, -2]) == [{1, -1}, {-2, 2}]
    end

    test "in an instance: its stages in place, one circuit per use" do
      hw = Path.join(@tmp, "streamfn")
      File.rm_rf!(hw)

      streams(
        """
        defhls running(x :: stream(s16)) :: stream(s32) do
          x |> transform(0, &sum/2)
        end
        defhls windowed(x :: stream(s16)) :: stream(s18) do
          x |> chunk_every(2, 2, :discard) |> map(&avg/1)
        end
        definstance a(x) do
          x |> running() |> run()
        end
        definstance b do
          ticks(10) |> low16() |> windowed() |> widen() |> windowed2() |> run()
        end
        defhls low16(x :: u32) :: s16 do
          x
        end
        defhls widen(x :: s18) :: s16 do
          x
        end
        defhls windowed2(x :: s16) :: s16 do
          x
        end
        definstance twice(x) do
          x |> running() |> low() |> running()
        end
        defhls low(x :: s32) :: s16 do
          x
        end
        """,
        %{"EHLS_SOC" => "litex", "EHLS_RUNTIME" => "atomvm", "EHLS_OUT_DIR" => hw}
      )

      priv = :code.priv_dir(:elixir_hls) |> to_string()
      {_, 0} = System.cmd("python3", [Path.join(priv, "gen_manifest.py"), hw])
      pipes = Path.join(hw, "pipelines.json") |> File.read!() |> JSON.decode!() |> Map.new(&{&1["name"], &1})
      names = fn p -> for st <- pipes[p]["stages"], do: st["kernel"] || st["block"] end
      assert [_, "run"] = names.("a")
      assert length(names.("b")) == 6
      [k1, _, k2] = names.("twice")
      assert k1 == k2 and k1 =~ "sum"

    end

    test "what cannot be stops the compile" do
      for {source, msg} <- [
            {"defhls f(x :: stream(s16)) :: stream(s16) do\nticks(1) |> tup()\nend", ~r/the body starts with its argument x/},
            {"defhls f(x :: stream(s16)) :: stream(s16) do\nx\nend", ~r/nothing happens to x/},
            {"defhls f(x :: stream(s16)) :: stream(s16) do\nx |> hold(:v)\nend", ~r/hold is a block, which cannot run on the CPU/},
            {"defhls f(x :: stream(s16)) :: stream(s16) do\nx |> map(&double/1)\nend", ~r/gives s16 and its last stage gives s18/},
            {"defhls f(x :: stream(s32)) :: stream(s32) do\nx |> map(&double/1)\nend", ~r/takes s32 and its first stage takes s16/},
            {"defhls f(x :: stream(s16)) :: stream(s18) do\nx |> map(&double/1)\nend\ndefinstance i do\nticks(1) |> f() |> run()\nend", ~r/ticks gives u32 and f|ticks gives u32 and double takes s16/},
            {"defhls f(x :: stream(s16)) :: stream(s18) do\nx |> map(&double/1)\nend\ndefhls g(x :: s16) :: s16 do\nf(x)\nend", ~r/cannot call f/},
            # a named state read by that name: used twice, the names meet, at the compile
            {"defhls f(x :: stream(s16)) :: stream(s32) do\nx |> transform(0, &sum/2, name: :total)\nend\ndefhls l(x :: s32) :: s16 do\nx\nend\ndefinstance i(y) do\ny |> f() |> l() |> f()\nend", ~r/total/},
            {"defhls f(x :: stream(s16)) :: stream(s18) do\nx |> map(&double/1)\nend\ndefinstance i(y) do\ny |> f(1) |> run()\nend", ~r/takes its stream from the stage before it/}
          ] do
        assert_raise CompileError, msg, fn -> streams(source) end
      end
    end
  end

  describe "an instance's CPU ends" do
    defp instance(source, env \\ %{"EHLS_SOC" => "litex"}) do
      mod = "EndCase#{System.unique_integer([:positive])}"

      with_env(env, fn ->
        Code.compile_string("""
        defmodule #{mod} do
          use EHLS
          defhls gray(x :: u32) :: u16 do
            x + 1
          end
          defhls two(x :: {u32, u32}) :: u32 do
            {a, b} = x
            a + b
          end
          defhls every_other(x :: u32, on :: u1) :: {[u32], u1} do
            if on == 1, do: {[x], 0}, else: {[], 1}
          end
          defhls fir(w :: tuple(s16, 4)) :: s16 do
            elem(w, 0) + elem(w, 3)
          end
          #{source}
        end
        """)
      end)

      Module.concat([mod])
    end

    defp description(source) do
      hw = Path.join(@tmp, "ends_#{System.unique_integer([:positive])}")
      File.rm_rf!(hw)
      instance(source, %{"EHLS_SOC" => "litex", "EHLS_OUT_DIR" => hw})
      priv = :code.priv_dir(:elixir_hls) |> to_string()
      {_, 0} = System.cmd("python3", [Path.join(priv, "gen_manifest.py"), hw])
      Path.join(hw, "pipelines.json") |> File.read!() |> JSON.decode!()
    end

    test "the argument is the input, a stream at the end the output" do
      [both, sink, source, closed] =
        description("""
        definstance a_both(pixels), buffer: 64 do
          pixels |> map(&gray/1)
        end
        definstance b_sink(samples) do
          samples |> map(&gray/1) |> hold(:v)
        end
        definstance c_source, overflow: :drop do
          ticks(10) |> map(&gray/1)
        end
        definstance d_closed do
          ticks(10) |> map(&gray/1) |> run()
        end
        """)

      assert [%{"name" => "pixels", "to" => 0, "port" => 0}] = both["inputs"]
      assert both["output"] == %{"buffer" => 64, "overflow" => "wait"}
      assert both["ends"] == [%{"name" => "pixels", "dir" => "in", "index" => 0}, %{"name" => "out", "dir" => "out", "index" => 1}]
      assert [%{"name" => "samples"}] = sink["inputs"]
      assert sink["output"] == nil
      assert [%{"name" => "samples", "index" => 2}] = sink["ends"]
      assert source["inputs"] == [] and source["output"]["overflow"] == "drop"
      assert [%{"name" => "out", "index" => 3}] = source["ends"]
      assert closed["inputs"] == [] and closed["output"] == nil and closed["ends"] == []
    end

    test "the calls exist as the instance's ends say" do
      m =
        instance(
          """
          definstance both(x) do
            x |> map(&gray/1)
          end
          definstance sink(x) do
            x |> map(&gray/1) |> hold(:v)
          end
          definstance src do
            ticks(10) |> map(&gray/1)
          end
          definstance closed do
            ticks(10) |> map(&gray/1) |> run()
          end
          """,
          %{"EHLS_SOC" => "litex", "EHLS_RUNTIME" => "atomvm"}
        )

      f = fn name, args -> function_exported?(m, name, args) end
      assert f.(:both, 1) and f.(:both, 2) and f.(:both, 3)
      assert_raise FunctionClauseError, fn -> m.closed(<<>>) end
      assert_raise FunctionClauseError, fn -> m.closed(:out, 4) end
      assert_raise FunctionClauseError, fn -> m.closed(:in, <<>>) end
      assert_raise FunctionClauseError, fn -> m.src(<<>>) end
      assert_raise FunctionClauseError, fn -> m.src(:in, <<>>) end
      assert_raise FunctionClauseError, fn -> m.sink(:out, 4) end
      assert_raise FunctionClauseError, fn -> m.sink(:request, :out, 4) end
    end

    test "what cannot work stops the compile" do
      for {source, msg} <- [
            {"definstance gray(x) do\nx |> map(&two/1)\nend", ~r/a defhls of this module has that name/},
            {"definstance out(out) do\nout |> map(&gray/1)\nend", ~r/cannot be called out/},
            {"definstance f(a, b) do\na |> map(&gray/1)\nend", ~r/nothing happens to b/},
            {"definstance f(x) do\nticks(10) |> map(&gray/1)\nend", ~r/nothing happens to x/},
            {"definstance f(x) do\nx\nend", ~r/nothing happens to x/},
            {"definstance f(x) do\nx |> ticks(10)\nend", ~r/ticks takes nothing/},
            {"definstance f do\nmap(&gray/1)\nend", ~r/gray takes a stream, and nothing comes before it/},
            {"definstance f, buffer: -1 do\nticks(1)\nend", ~r/number of elements/},
            {"definstance f, buffer: 8 do\nticks(1) |> run()\nend", ~r/is about a result/},
            {"definstance f, overflow: :maybe do\nticks(1)\nend", ~r/:wait or :drop/},
            {"definstance f, nope: 1 do\nticks(1)\nend", ~r/unknown option nope/}
          ] do
        assert_raise CompileError, msg, fn -> instance(source) end
      end

      assert_raise CompileError, ~r/a defhls of this module has that name/, fn ->
        with_env(%{"EHLS_SOC" => "litex"}, fn ->
          Code.compile_string("""
          defmodule NameClashCase do
            use EHLS
            defhls g(x :: u32) :: u32 do
              x
            end
            definstance h(x) do
              x |> map(&g/1)
            end
            defhls h(x :: u32) :: u32 do
              x
            end
          end
          """)
        end)
      end
    end

    test "a size follows from the rates when the stages say them" do
      chain = fn s -> Code.string_to_quoted!(s) end
      rates = %{g: {1, 1}, two: {1, 2}, e: nil}
      windows = %{fir: %{etype: {:s16, [], nil}, ret: {:s16, [], nil}}}
      rate = &EHLS.Pipeline.rate(chain.(&1), rates, windows, %{hold: {:level, 1, "x"}, blk: {:block, 0, "x"}})
      assert rate.("map(&g/1) |> g()") == {1, 1}
      assert rate.("g() |> map(&two/1)") == {1, 2}
      assert rate.("chunk_every(4, 4, :discard) |> map(&fir/1)") == {1, 4}
      # overlapping chunks begin after the first four: not known across calls
      assert rate.("chunk_every(4, 1, :discard) |> map(&fir/1)") == nil
      # chunks apart: one output per step
      assert rate.("chunk_every(4, 6, :discard) |> map(&fir/1)") == {1, 6}
      assert rate.("g() |> transform(0, &e/2)") == nil
      assert rate.("g() |> blk()") == nil
      assert EHLS.__out_size__(<<0::96>>, [], 1, 1, 4) == 3
      assert EHLS.__out_size__(<<0::128>>, [], 1, 4, 4) == 1
      assert EHLS.__out_size__(<<0::128>>, [out: 20], 0, 0, 4) == 20
      assert EHLS.__out_size__(<<0::24>>, [], 1, 1, 1) == 3
      assert EHLS.__out_size__(<<0::72>>, [], 1, 1, 3) == 3
      assert_raise ArgumentError, fn -> EHLS.__out_size__(<<0::24>>, [], 1, 1, 2) end
      assert_raise ErlangError, ~r/out_size_needed/, fn -> EHLS.__out_size__(<<0::32>>, [], 0, 0, 4) end
      assert_raise ArgumentError, fn -> EHLS.__out_size__(<<0::32>>, [], 1, 4, 4) end
    end

    # what the driver does, for the code on the CPU
    defmodule FakeRuntime do
      def pipe_enable(_p, _on), do: :ok

      def end_send(_e, _p, _name, :busy_in, _bin), do: :busy
      def end_send(_e, _p, _name, :stopped_in, _bin), do: :stopped
      def end_send(_e, _p, _name, :silent, _bin), do: :ok

      def end_send(_e, _p, name, tag, _bin) do
        send(self(), {name, tag, :sent})
        :ok
      end

      def end_request(_e, _p, name, :out, n) do
        send(self(), {name, :out, :binary.copy(<<7>>, n)})
        :ok
      end

      def end_cancel(e) do
        send(self(), {:cancelled, e})
        :ok
      end
    end

    test "a call waits for its messages and raises what went wrong" do
      rt = FakeRuntime
      assert EHLS.__in__(rt, 0, 1, :f, :x, <<0::32>>, 4, []) == :ok
      assert EHLS.__out__(rt, 0, 2, :f, 2, 4, []) == <<7, 7, 7, 7, 7, 7, 7, 7>>
      assert EHLS.__out__(rt, 0, 2, :f, 3, 1, []) == <<7, 7, 7>>
      assert EHLS.__both__(rt, 0, 1, 2, :f, :x, <<0::32>>, 4, 1, 4, []) == <<7, 7, 7, 7>>
      assert EHLS.__send__(rt, 0, 1, :f, :busy_in, <<0::32>>, 4) == {:error, :busy}
      # nothing to move: answered at once, without the hardware
      assert EHLS.__send__(nil, 0, 1, :f, :x, <<>>, 4) == :ok
      assert_received {:f, :x, :sent}
      assert EHLS.__request__(nil, 0, 2, :f, 0, 4) == :ok
      assert_received {:f, :out, <<>>}
      assert_raise ErlangError, ~r/busy/, fn -> EHLS.__in__(rt, 0, 1, :f, :busy_in, <<0::32>>, 4, []) end
      assert_raise ErlangError, ~r/stopped/, fn -> EHLS.__in__(rt, 0, 1, :f, :stopped_in, <<0::32>>, 4, []) end
      assert_raise ArgumentError, fn -> EHLS.__in__(rt, 0, 1, :f, :x, <<0, 0>>, 4, []) end
      assert_raise ArgumentError, fn -> EHLS.__request__(rt, 0, 2, :f, -1, 4) end

      # the input refused: the output asked for just before is cancelled
      assert_raise ErlangError, ~r/busy/, fn -> EHLS.__both__(rt, 0, 1, 2, :g, :busy_in, <<0::32>>, 4, 1, 4, []) end
      assert_received {:cancelled, 2}
      refute_received {:g, :out, _}

      # a timeout cancels, and nothing of it stays for the next call
      assert_raise ErlangError, ~r/timeout/, fn -> EHLS.__in__(rt, 0, 1, :h, :silent, <<0::32>>, 4, timeout: 1) end
      assert_received {:cancelled, 1}
    end
  end

  describe "lists at the CPU ends" do
    test "pack and unpack: the packed format, values wrapped to their type, tuples as tuples" do
      for {layout, values, bin} <- [
            {8, [0, 255, 256, -1], <<0, 255, 0, 255>>},
            {-16, [-1, 32767, 32768], <<255, 255, 255, 127, 0, 128>>},
            {-18, [-1, 131_071, 131_072], <<255, 255, 255, 255, 255, 255, 1, 0, 0, 0, 254, 255>>},
            {32, [0xDEADBEEF], <<0xEF, 0xBE, 0xAD, 0xDE>>},
            {64, [0xFFFF_FFFF_FFFF_FFFF], :binary.copy(<<255>>, 8)},
            {-64, [-2], <<254>> <> :binary.copy(<<255>>, 7)},
            {{8, -16}, [{1, -2}], <<1, 254, 255>>},
            {{1, {-18, 20}}, [{3, {-1, 1}}], <<1, 255, 255, 255, 255, 1, 0, 0, 0>>}
          ] do
        assert EHLS.pack(values, layout) == bin
      end

      assert EHLS.unpack(<<255, 255, 255, 127, 0, 128>>, -16) == [-1, 32767, -32768]
      assert EHLS.unpack(:binary.copy(<<255>>, 8), 64) == [0xFFFF_FFFF_FFFF_FFFF]
      assert EHLS.unpack(<<1, 254, 255, 2, 0, 128>>, {8, -16}) == [{1, -2}, {2, -32768}]
      # the circuit may leave the upper bits of a scalar as it likes: only its own bits are read
      assert EHLS.unpack(<<255, 255, 3, 0>>, -18) == [-1]
      assert EHLS.unpack(<<>>, 8) == []
      assert EHLS.pack([], {8, 8}) == <<>>

      assert_raise ArgumentError, fn -> EHLS.unpack(<<1, 2>>, {8, -16}) end
      assert_raise ArgumentError, fn -> EHLS.pack([{1, 2, 3}], {8, -16}) end
      assert_raise ArgumentError, fn -> EHLS.pack([:a], 8) end
      assert_raise ArgumentError, fn -> EHLS.pack([1 | 2], 8) end
      assert EHLS.layout({:tuple, [{8, false}, {:tuple, [{18, true}]}]}) == {8, {-18}}
      assert EHLS.layout(:any) == 32
    end

    test "an instance takes a list and gives a list; a binary gives a binary; as: says otherwise" do
      Code.compile_string("""
      # the runtime: an end gives back what was sent to it (an identity circuit)
      defmodule :hwstream do
        def pipe_enable(_p, _on), do: :ok
        def end_cancel(_e), do: :ok
        def pack(list, layout), do: EHLS.pack(list, layout)
        def unpack(bin, layout), do: EHLS.unpack(bin, layout)

        def end_request(_e, _p, name, tag, bytes) do
          case Process.get(:sent) do
            nil -> Process.put(:wanted, {name, tag, bytes})
            bin -> send(self(), {name, tag, binary_part(bin, 0, bytes)})
          end
          :ok
        end

        def end_send(_e, _p, name, tag, bin) do
          send(self(), {name, tag, :sent})
          case Process.delete(:wanted) do
            {n, t, bytes} -> send(self(), {n, t, binary_part(bin, 0, bytes)})
            nil -> Process.put(:sent, bin)
          end
          :ok
        end

        # one element without DMA: full once three are in
        def end_push(_e, _p, words) do
          pushed = Process.get(:pushed, [])
          if length(pushed) == 3, do: :full, else: (Process.put(:pushed, pushed ++ [words]); :ok)
        end
      end

      defmodule :hw_kernels do
        def pipeline(_), do: 0
        def cpu_end(_, _), do: 0
      end
      """)

      with_env(%{"EHLS_SOC" => "litex", "EHLS_RUNTIME" => "atomvm"}, fn ->
        Code.compile_string("""
        defmodule ListEndsCase do
          use EHLS
          defhls same(x :: s16) :: s16 do
            x
          end
          defhls swap(x :: {u8, s16}) :: {u8, s16} do
            x
          end
          definstance s(x) do
            x |> map(&same/1)
          end
          definstance t(x) do
            x |> map(&swap/1)
          end
          definstance sink(x) do
            x |> map(&same/1) |> run()
          end
        end
        """)
      end)

      run = fn f ->
        Process.delete(:sent)
        Process.delete(:wanted)
        f.()
      end

      assert run.(fn -> ListEndsCase.s([1, -2, 70000]) end) == [1, -2, 4464]
      assert run.(fn -> ListEndsCase.s(<<1, 0, 254, 255>>) end) == <<1, 0, 254, 255>>
      assert run.(fn -> ListEndsCase.s([1, -2], as: :binary) end) == <<1, 0, 254, 255>>
      assert run.(fn -> ListEndsCase.s(<<1, 0, 254, 255>>, as: :list) end) == [1, -2]
      assert run.(fn -> ListEndsCase.s([]) end) == []
      assert run.(fn -> ListEndsCase.t([{1, -2}, {255, 32767}]) end) == [{1, -2}, {255, 32767}]
      assert run.(fn -> ListEndsCase.sink([1, 2]) end) == :ok
      assert run.(fn -> ListEndsCase.s(:in, [5, -5]) end) == :ok
      assert Process.get(:sent) == <<5, 0, 251, 255>>
      assert ListEndsCase.s(:out, 2, as: :list) == [5, -5]
      assert ListEndsCase.s(:out, 1) == <<5, 0>>
      assert run.(fn -> ListEndsCase.s(:send, :x, [7]) end) == :ok
      assert_received {:s, :x, :sent}
      # one element: its packed bytes as 32-bit words, little-endian
      assert ListEndsCase.s(:send, :x, -2) == :ok
      assert ListEndsCase.t(:send, :x, {1, -2}) == :ok
      assert ListEndsCase.s(:send, :x, 70000) == :ok
      assert ListEndsCase.s(:send, :x, 1) == {:error, :full}
      assert Process.get(:pushed) == [[0xFFFE], [0xFFFE01], [4464]]
      refute_received {:s, :x, :sent}
      assert_raise ArgumentError, fn -> run.(fn -> ListEndsCase.s([1], as: :words) end) end
      assert_raise ArgumentError, fn -> run.(fn -> ListEndsCase.t([{1, 2, 3}]) end) end
    after
      for m <- [:hwstream, :hw_kernels, ListEndsCase] do
        :code.purge(m)
        :code.delete(m)
      end
    end
  end

  test "levels and state belong to the stage: a kernel in two pipelines has two of each" do
    hw = Path.join(@tmp, "instances")
    File.rm_rf!(hw)
    System.put_env("EHLS_OUT_DIR", hw)
    System.put_env("EHLS_SOC", "litex")

    try do
      Code.compile_string("""
      defmodule InstancesCase do
        use EHLS
        defhls scale(x :: u32, k :: u8) :: u32 do
          x * k
        end
        defhls count(_x :: u32, n :: u32, step :: u8) :: {u32, u32} do
          {n, n + step}
        end
        definstance a do
          ticks(10) |> map(&scale(&1, k_a(:value))) |> transform(0, &count(&1, &2, 1), name: :n) |> hold(:v)
        end
        definstance b do
          ticks(10) |> map(&scale(&1, k_b(:value))) |> transform(0, &count(&1, &2, k_a(:value)), name: :n) |> hold(:v)
        end
        definstance k_a(v :: u8), initial: 2 do
          v
        end
        definstance k_b(v :: u8), initial: 5 do
          v
        end
      end
      """)
    after
      System.delete_env("EHLS_OUT_DIR")
      System.delete_env("EHLS_SOC")
    end

    priv = :code.priv_dir(:elixir_hls) |> to_string()
    {_, 0} = System.cmd("python3", [Path.join(priv, "gen_manifest.py"), hw])
    [a, b, _, _] = Path.join(hw, "pipelines.json") |> File.read!() |> JSON.decode!()

    args = for p <- [a, b], i <- 1..2, do: Enum.at(p["stages"], i)["args"]

    assert [
             [%{"name" => "hw__lv1", "from" => "InstancesCase.k_a", "default" => 2}],
             # an integer is in the kernel made for it, count__s_c1; a level is wired in, count__s_l
             [],
             [%{"name" => "hw__lv1", "from" => "InstancesCase.k_b", "default" => 5}],
             [%{"name" => "hw__lv1", "from" => "InstancesCase.k_a", "default" => 2}]
           ] = args

    # on the CPU it is the plain function: the element, the state, the level
    assert InstancesCase.count(7, 10, 3) == {10, 13}

    peeks = for p <- [a, b], st <- p["stages"], st["peek"] != nil, do: st["peek"]
    assert peeks == [0, 1, 2, 3]
    assert a["links"] == for(i <- 0..2, do: %{"from" => i, "to" => i + 1, "kind" => "stream", "type" => "u32"})
  end

  test "what the CPU reads as a whole is numbered one by one, whatever its words: the circuit picks it by its place" do
    hw = Path.join(@tmp, "peeks")
    File.rm_rf!(hw)

    with_env(%{"EHLS_SOC" => "litex", "EHLS_OUT_DIR" => hw}, fn ->
      Code.compile_string("""
      defmodule PeeksCase do
        use EHLS
        defhls two(_x :: u32, s :: {u32, u32}) :: {u32, {u32, u32}} do
          {a, b} = s
          {a, {b, a + 1}}
        end
        definstance p do
          ticks(10) |> transform({0, 0}, &two/2, name: :s) |> hold(:v)
        end
        definstance k_hw(v :: u8) do
          v
        end
      end
      """)
    end)

    priv = :code.priv_dir(:elixir_hls) |> to_string()
    {_, 0} = System.cmd("python3", [Path.join(priv, "gen_manifest.py"), hw])
    [k, p] = Path.join(hw, "pipelines.json") |> File.read!() |> JSON.decode!()
    assert [%{"peek" => 0, "state_words" => 2}, %{"peek" => 1, "state_words" => 1}] = Enum.slice(p["stages"], 1..2)
    assert %{"peek" => 2, "peek_words" => 2} = k["level"]
  end

  describe "transform: a stage with a state" do
    defp stateful(body, name \\ "StateCase#{System.unique_integer([:positive])}") do
      hw = Path.join(@tmp, "state_#{System.unique_integer([:positive])}")
      File.rm_rf!(hw)

      with_env(%{"EHLS_SOC" => "litex", "EHLS_OUT_DIR" => hw}, fn ->
        Code.compile_string("""
        defmodule #{name} do
          use EHLS
          defhls count(_x :: u32, n :: u16) :: {u32, u16} do
            {n, n + 1}
          end
          defhls pair(x :: u32, st :: {u8, s8}) :: {u32, {u8, s8}} do
            {a, b} = st
            {x + a, {a + 1, b - 1}}
          end
          defhls plain(x :: u32) :: u32 do
            x + 1
          end
          #{body}
        end
        """)
      end)

      priv = :code.priv_dir(:elixir_hls) |> to_string()
      {_, 0} = System.cmd("python3", [Path.join(priv, "gen_manifest.py"), hw])
      Path.join(hw, "pipelines.json") |> File.read!() |> JSON.decode!()
    end

    test "the initial value and the name are the stage's; only a named state is read" do
      [p] =
        stateful("""
        definstance i do
          ticks(10)
          |> transform(7, &count/2, name: :first)
          |> transform(9, &count/2)
          |> transform({1, -1}, &pair/2, name: :second)
          |> run()
        end
        """)

      [a, b, c, d, _] = p["stages"]
      assert a["block"] == "ticks"
      assert b["init"] == [7] and b["state_name"] == "first" and b["peek"] == 0
      assert c["init"] == [9] and c["state_name"] == nil and c["peek"] == nil
      assert d["init"] == [1, 0xFFFFFFFF] and d["state_name"] == "second" and d["peek"] == 1
    end

    test "the same function twice is two states, each with its name" do
      [p] =
        stateful("""
        definstance i do
          ticks(10) |> transform(0, &count/2, name: :a) |> transform(5, &count/2, name: :b) |> run()
        end
        """)

      [_, a, b, _] = p["stages"]
      assert a["kernel"] == b["kernel"]
      assert {a["init"], b["init"]} == {[0], [5]}
      assert {a["peek"], b["peek"]} == {0, 1}
    end

    test "on the CPU a function with a state is a plain function: the element and the state in, the output and the next state out" do
      m = Module.concat([:"StepCase"])
      stateful("", "StepCase")
      assert m.count(1, 41) == {41, 42}
      refute function_exported?(m, :count, 1)
      assert Enum.map_reduce([1, 2], 7, &m.count/2) == {[7, 8], 9}
    end

    test "what hides a state stops the compile" do
      for {source, msg} <- [
            {"definstance i do\nticks(1) |> map(&count/2) |> run()\nend", ~r/count takes 2 arguments: transform\(init, &count\/2\)/},
            {"definstance i do\nticks(1) |> count() |> run()\nend", ~r/count takes 2 arguments/},
            {"definstance i do\nticks(1) |> transform(0, &plain/1) |> run()\nend", ~r/plain has no state: map/},
            {"definstance i do\nticks(1) |> transform(&count/2) |> run()\nend", ~r/transform\(init, &f\/2\)/},
            {"definstance i do\nticks(1) |> transform(0, &count/2, name: 1) |> run()\nend", ~r/name: an atom/},
            {"definstance i do\nticks(1) |> transform(0, &count/2, name: :a) |> transform(0, &count/2, name: :a) |> run()\nend", ~r/two states named a/},
            {"definstance i do\nticks(1) |> transform({0, 0}, &count/2) |> run()\nend", ~r/initial state/},
            {"definstance i do\nticks(1) |> transform(0, &pair/2) |> run()\nend", ~r/initial state/},
            {"definstance i do\nticks(1) |> transform(init(), &count/2) |> run()\nend", ~r/initial state/},
            {"defhls f(x :: u8, n :: u8 \\\\ 0) :: u8 do\n{x, n}\nend", ~r/n has a default: a level has none.*transform\(init, &f\/2\)/},
            {"defhls f(x :: u8, n :: u8 \\\\ 0) :: {u8, u8} do\n{x, n}\nend", ~r/n has a default: a level has none.*transform\(init, &f\/2\)/}
          ] do
        assert_raise CompileError, msg, fn -> stateful(source) end
      end
    end

    test "chunks are a state and a memory: written with transform it gives the same words" do
      m = Module.concat([:"WindowByHand"])

      with_env(%{"EHLS_SOC" => "litex"}, fn ->
        Code.compile_string("""
        defmodule WindowByHand do
          use EHLS
          @taps [1, -2, 3, 4]

          defhls fir(w :: tuple(s16, 4)) :: s32 do
            Enum.sum(for k <- 0..3, do: elem(w, k) * Enum.at(@taps, k))
          end

          # the first chunk once four have come (cnt 3), then every second: the next chunk has two already
          defhls fir_by_hand(x :: s16, {pos, cnt, hist} :: {u2, u2, tuple(s16, 4)}) :: {[s32], {u2, u2, tuple(s16, 4)}} do
            out =
              if cnt == 3 do
                acc =
                  for k <- 0..2, reduce: x * Enum.at(@taps, 3) do
                    acc -> acc + elem(hist, (pos - 3 + k) &&& 3) * Enum.at(@taps, k)
                  end

                {[acc], 2}
              else
                {[], cnt + 1}
              end

            {y, cnt2} = out
            {y, {pos + 1, cnt2, put_elem(hist, pos, x)}}
          end

          defhls low(x :: u32) :: s16 do
            x
          end

          definstance by_window do
            ticks(10) |> map(&low/1) |> chunk_every(4, 2, :discard) |> map(&fir/1) |> run()
          end

          definstance by_hand do
            ticks(10) |> map(&low/1) |> transform({0, 0, Tuple.duplicate(0, 4)}, &fir_by_hand/2) |> run()
          end
        end
        """)
      end)

      xs = for i <- 1..64, do: rem(i * 7919, 65_536) - 32_768
      {w, _} = EHLS.run_cpu(&m.fir_c4_s2/2, xs, m.fir_c4_s2(:zero))
      {h, _} = EHLS.run_cpu(&m.fir_by_hand/2, xs, {0, 0, Tuple.duplicate(0, 4)})
      assert length(w) == 31 and w == h
      # as Elixir: the chunks of Stream.chunk_every, each a tuple, through the function
      assert w == xs |> Stream.chunk_every(4, 2, :discard) |> Enum.map(&m.fir(List.to_tuple(&1)))
    end
  end

  describe "instances of levels" do
    defp levels(source, env) do
      mod = "LevelCase#{System.unique_integer([:positive])}"

      with_env(env, fn ->
        Code.compile_string("""
        defmodule #{mod} do
          use EHLS
          defhls gain_of(volume :: u4) :: u9 do
            volume * 32
          end
          defhls mix2(a :: s16, b :: s16) :: s17 do
            a + b
          end
          defhls step(x :: u8, n :: u8) :: {u8, u8} do
            {x + n, n + 1}
          end
          #{source}
        end
        """)
      end)

      Module.concat([mod])
    end

    test "the description: one kernel of the body, the initial result cut to its type" do
      hw = Path.join(@tmp, "levels_#{System.unique_integer([:positive])}")
      File.rm_rf!(hw)

      m =
        levels(
          """
          definstance k_hw(v :: u9), initial: 600 do
            v
          end
          definstance gain_hw(volume :: u4) do
            gain_of(volume)
          end
          definstance pair_hw(a :: u8, b :: s40), initial: {1, -1} do
            {b, a}
          end
          definstance mix_hw(a :: s16, b :: s16) do
            mix2(a, b)
          end
          """,
          %{"EHLS_SOC" => "litex", "EHLS_OUT_DIR" => hw}
        )

      priv = :code.priv_dir(:elixir_hls) |> to_string()
      {_, 0} = System.cmd("python3", [Path.join(priv, "gen_manifest.py"), hw])
      ps = Path.join(hw, "pipelines.json") |> File.read!() |> JSON.decode!() |> Map.new(&{&1["name"], &1})
      ks = Path.join(hw, "kernels.json") |> File.read!() |> JSON.decode!() |> Map.new(&{&1["function"], &1})

      # 600 cut to u9; a tuple of the result: 1 the s40, -1 the u8 (255)
      assert %{"args" => ["v"], "arg_types" => ["u9"], "ret" => "u9", "initial" => [88]} = ps["k_hw"]["level"]
      assert ps["gain_hw"]["level"]["initial"] == [0]
      assert %{"ret" => ["s40", "u8"], "initial" => [1, 0xFF]} = ps["pair_hw"]["level"]
      assert [%{"kernel" => kernel}] = ps["pair_hw"]["stages"]
      assert ks["pair_hw__level"]["kernel"] == kernel and ks["pair_hw__level"]["arg"] == ["u8", "s40"]
      assert ks["pair_hw__level"]["lane"] == 64

      # a number each for the writes, and one for reading the count and the result together: a word
      # of count, then a word per value (two for 64-bit ports)
      levels = for n <- ~w(gain_hw k_hw mix_hw pair_hw), do: Map.take(ps[n]["level"], ["index", "peek", "peek_words"])

      assert levels == [
               %{"index" => 0, "peek" => 0, "peek_words" => 2},
               %{"index" => 1, "peek" => 1, "peek_words" => 2},
               %{"index" => 2, "peek" => 2, "peek_words" => 2},
               %{"index" => 3, "peek" => 3, "peek_words" => 5}
             ]

      # the kernel is a defhls on the CPU too
      assert m.pair_hw__level({300, -2}) == {-2, 44}
      assert m.mix_hw__level({-30000, -30000}) == -60000
    end

    test "what cannot be stops the compile" do
      for {source, msg} <- [
            {"definstance a(v :: u8, w) do\nv\nend", ~r/levels and a stream in one instance are not there yet/},
            {"definstance a(v :: u8) do\nv + 1\nend", ~r/the body of an instance of levels is one of its arguments/},
            {"definstance a(v :: u8), buffer: 4 do\nv\nend", ~r/unknown option buffer/},
            {"definstance a(v :: u8), initial: :x do\nv\nend", ~r/initial: :x is not a value of the result's type/},
            {"definstance a(v :: u8, w :: u8), initial: 3 do\n{v, w}\nend", ~r/initial: 3 is not a value/},
            {"definstance a(v :: u8), initial: x do\nv\nend", ~r/initial: is a literal/},
            {"definstance a(v :: u8) do\nmix2(v)\nend", ~r/mix2 takes 2 argument/},
            {"definstance gain_of(v :: u4) do\nv\nend", ~r/a defhls of this module has that name/},
            {"definstance a(out :: u4) do\nout\nend", ~r/cannot be called out/}
          ] do
        assert_raise CompileError, msg, fn -> levels(source, %{"EHLS_SOC" => "litex"}) end
      end
    end

    test "without a runtime backend the calls say where the instance runs" do
      m = levels("definstance mix_hw(a :: s16, b :: s16) do\nmix2(a, b)\nend", %{"EHLS_SOC" => "litex"})
      assert_raise ArgumentError, ~r/runs on a board/, fn -> m.mix_hw(1, 2) end
      assert_raise ArgumentError, ~r/runs on a board/, fn -> m.mix_hw(1, 2, wait: false) end
      assert_raise ArgumentError, ~r/runs on a board/, fn -> m.mix_hw(:value) end
    end

    test "with a runtime backend: the calls of a level instance" do
      m =
        levels("definstance mix_hw(a :: s16, b :: s16) do\nmix2(a, b)\nend", %{"EHLS_SOC" => "litex", "EHLS_RUNTIME" => "atomvm"})

      for {f, n} <- [mix_hw: 1, mix_hw: 2, mix_hw: 3], do: assert(function_exported?(m, f, n))
      assert_raise FunctionClauseError, fn -> m.mix_hw(1, 2, 3) end
    end

    test "a level wired into a function placed in a stream: a kernel of one argument, its param from the level" do
      hw = Path.join(@tmp, "wires_#{System.unique_integer([:positive])}")
      File.rm_rf!(hw)

      m =
        levels(
          """
          defhls scale(x :: s16, k :: u9) :: s16 do
            x * k
          end
          defhls offset(b :: s8, x :: s16) :: s16 do
            x + b
          end
          definstance k_hw(v :: u9), initial: 3 do
            v
          end
          definstance b_hw(v :: s8), initial: -5 do
            v
          end
          definstance player(samples) do
            scale(samples, k_hw(:value)) |> map(&offset(b_hw(:value), &1)) |> map(&offset(-2, &1)) |> map(&scale(&1, Other.k_hw(:value)))
          end
          """,
          %{"EHLS_SOC" => "litex", "EHLS_OUT_DIR" => hw}
        )

      [player] = for p <- Path.wildcard(Path.join(hw, "*.pipeline")), p = p |> File.read!() |> JSON.decode!(), p["name"] == "player", do: p
      names = for st <- player["stages"], do: st["kernel"] |> String.split("_case") |> List.last() |> String.replace(~r/^\d+_/, "")
      assert names == ["scale__x_l", "offset__x_l", "offset__x_cm2", "scale__x_l"]
      mod = inspect(m)

      assert Enum.map(player["stages"], & &1["wires"]) == [
               [%{"arg" => "hw__lv1", "from" => "#{mod}.k_hw", "type" => "u9"}],
               [%{"arg" => "hw__lv1", "from" => "#{mod}.b_hw", "type" => "s8"}],
               [],
               [%{"arg" => "hw__lv1", "from" => "Other.k_hw", "type" => "u9"}]
             ]

      # the CPU function of the kernel: the stream, then the levels; at first the level's initial: value
      assert m.scale__x_l(-4, 3) == -12 and m.offset__x_l(10, -5) == 5 and m.offset__x_cm2(7) == 5

      # put together: Other.k_hw is not in this build
      priv = :code.priv_dir(:elixir_hls) |> to_string()
      assert {msg, 1} = System.cmd("python3", [Path.join(priv, "gen_manifest.py"), hw], stderr_to_stdout: true)
      assert msg =~ "Other.k_hw is no instance of levels of this build"
    end

    test "a pin's level wired into a function placed in a stream: EHLS.GPIO.read(:pin)" do
      hw = Path.join(@tmp, "pins_#{System.unique_integer([:positive])}")
      File.rm_rf!(hw)
      mod = "PinCase#{System.unique_integer([:positive])}"

      source = fn pin ->
        """
        defmodule #{mod}#{pin} do
          use EHLS, blocks: [{EHLS.GPIO, in: [sw: "j5:4"], out: [led: "j5:3"]}]
          defhls scale(x :: s16, k :: u9) :: s16 do
            x * k
          end
          definstance follower(samples) do
            samples |> map(&scale(&1, EHLS.GPIO.read(:sw))) |> map(&scale(&1, EHLS.GPIO.read(:#{pin})))
          end
        end
        """
      end

      with_env(%{"EHLS_SOC" => "litex", "EHLS_OUT_DIR" => hw}, fn -> Code.compile_string(source.("led")) end)
      priv = :code.priv_dir(:elixir_hls) |> to_string()
      {_, 0} = System.cmd("python3", [Path.join(priv, "gen_manifest.py"), hw])
      [p] = Path.join(hw, "pipelines.json") |> File.read!() |> JSON.decode!()
      assert for(st <- p["stages"], do: Enum.map(st["args"], &Map.take(&1, ["pin", "type", "default"]))) ==
               [[%{"pin" => "sw", "type" => "u9", "default" => 0}], [%{"pin" => "led", "type" => "u9", "default" => 0}]]

      # a pin not declared in the build: when the circuits are put together
      hw2 = hw <> "_nopin"
      with_env(%{"EHLS_SOC" => "litex", "EHLS_OUT_DIR" => hw2}, fn -> Code.compile_string(source.("door")) end)
      assert {msg, 1} = System.cmd("python3", [Path.join(priv, "gen_manifest.py"), hw2], stderr_to_stdout: true)
      assert msg =~ "no pin door (EHLS.GPIO) in this build"
    end

    test "a stream function takes levels after its stream: on the CPU values, where it is placed their sources" do
      hw = Path.join(@tmp, "sfl_#{System.unique_integer([:positive])}")
      File.rm_rf!(hw)

      m =
        levels(
          """
          defhls smooth(x :: s16) :: s16 do
            x >>> 1
          end
          defhls scale(x :: s16, k :: u9) :: s16 do
            x * k
          end
          defhls louder(x :: stream(s16), k :: u9) :: stream(s16) do
            x |> map(&smooth/1) |> map(&scale(&1, k))
          end
          defhls twice(x :: stream(s16), a :: u8, b :: u8) :: stream(s16) do
            x |> louder(a) |> map(&scale(&1, b))
          end
          definstance k_hw(v :: u9), initial: 3 do
            v
          end
          definstance player(samples) do
            louder(samples, k_hw(:value))
          end
          definstance two(samples) do
            samples |> twice(k_hw(:value), 2)
          end
          """,
          %{"EHLS_SOC" => "litex", "EHLS_OUT_DIR" => hw}
        )

      # on the CPU a level is a value, the same for the whole list; wrapped to its type
      assert m.louder([100, -7, 3], 5) == [250, -20, 5]
      assert m.twice([100, -7], 4, 2) == [400, -32]
      assert m.louder([100], 512 + 5) == [250]

      ps = for p <- Path.wildcard(Path.join(hw, "*.pipeline")), p = p |> File.read!() |> JSON.decode!(), into: %{}, do: {p["name"], p}
      wires = fn name -> for st <- ps[name]["stages"], do: for(w <- st["wires"] || [], do: w["from"]) end
      mod = inspect(m)
      assert wires.("player") == [[], ["#{mod}.k_hw"]]
      assert wires.("two") == [[], ["#{mod}.k_hw"], []]
    end

    test "a stream function's levels: what cannot be stops the compile" do
      for {source, msg} <- [
            {"defhls f(x :: stream(s16), k :: u16) :: stream(s16) do\nx |> map(&scale(&1, k))\nend", ~r/k is u16 and scale's k is u9/},
            {"defhls f(x :: stream(s16), k :: u40) :: stream(s16) do\nx |> map(&scale(&1, k))\nend", ~r/a level argument k is one value up to 32 bits/},
            {"defhls f(x :: stream(s16), k) :: stream(s16) do\nx |> map(&scale(&1, k))\nend", ~r/bad parameter k/}
          ] do
        assert_raise CompileError, msg, fn ->
          levels("defhls scale(x :: s16, k :: u9) :: s16 do\nx * k\nend\n" <> source, %{"EHLS_SOC" => "litex"})
        end
      end
    end

    test "what cannot be wired stops the compile" do
      defs = """
      defhls scale(x :: s16, k :: u9) :: s16 do
        x * k
      end
      definstance k_hw(v :: u9) do
        v
      end
      definstance w_hw(v :: u16) do
        v
      end
      definstance t_hw(a :: u4, b :: u4) do
        {a, b}
      end
      defhls neg(x :: s16, s :: s1) :: s16 do
        x * s
      end
      defhls louder(x :: stream(s16), k :: u9) :: stream(s16) do
        x |> map(&scale(&1, k))
      end
      """

      for {body, msg} <- [
            {"x |> map(&scale(&1, 3 + 4))", ~r/an argument besides the stream is an integer or a level/},
            {"x |> map(&scale(&1, w_hw(:value)))", ~r/w_hw gives u16 and scale's k is u9, which would change the value/},
            {"x |> map(&scale(&1, t_hw(:value)))", ~r/t_hw gives \{u4, u4\}, a tuple/},
            {"x |> map(&scale(&1, nope(:value)))", ~r/nope is not an instance of levels/},
            {"x |> map(&scale(&1, &1))", ~r/takes the stream as &1, once/},
            {"x |> map(&scale(3, k_hw(:value)))", ~r/takes the stream as &1, once/},
            {"x |> scale(k_hw(:value), 1)", ~r/scale takes 2 arguments/},
            {"x |> map(&scale(&1, EHLS.GPIO.read(\"sw\")))", ~r/EHLS.GPIO.read takes a pin's name, an atom/},
            {"x |> map(&neg(&1, EHLS.GPIO.read(:sw)))", ~r/a pin gives u1 and neg's s is s1, which would change the value/},
            {"x |> louder(w_hw(:value))", ~r/w_hw gives u16 and scale's k is u9/},
            {"x |> louder()", ~r/the stream function louder takes its stream from the stage before it, and 1 level/},
            {"x |> louder(1, 2)", ~r/the stream function louder takes its stream from the stage before it, and 1 level/}
          ] do
        assert_raise CompileError, msg, fn ->
          levels(defs <> "definstance i(x) do\n#{body}\nend", %{"EHLS_SOC" => "litex"})
        end
      end
    end

    # a runtime that is a circuit computing at once (FakeLevel below)
    test "a call writes the words, waits for its own start's result, and builds it" do
      info = {{4, 9}, 64, [{8, false}, {40, true}], [{40, true}, {8, false}], {:tuple, [{40, true}, {8, false}]}}
      FakeLevel.reset(fn [a, 0, lo, hi] -> {lo ||| hi <<< 32, a} end, 2)

      # words of 64-bit ports, low first; values wrapped to their types
      assert EHLS.__level_call__(FakeLevel, 0, info, [300, -2], []) == {-2, 44}
      assert FakeLevel.writes() == [{4, 0, [44, 0, 0xFFFFFFFE, 0xFFFFFFFF]}]
      assert EHLS.__level_value__(FakeLevel, info) == {-2, 44}

      # the result held is the one of this start: the earlier ones do not count
      assert EHLS.__level_call__(FakeLevel, 0, info, [1, 5], wait: false) == :ok
      assert EHLS.__level_call__(FakeLevel, 0, info, [2, 6], []) == {6, 2}

      FakeLevel.reset(fn _ -> {0, 0} end, :never)
      assert catch_error(EHLS.__level_call__(FakeLevel, 0, info, [1, 1], timeout: 20)) == :timeout
      FakeLevel.reset(fn _ -> {0, 0} end, :stopped)
      assert catch_error(EHLS.__level_call__(FakeLevel, 0, info, [1, 1], [])) == :stopped
      assert_raise ArgumentError, fn -> EHLS.__level_call__(FakeLevel, 0, info, [1, {1, 2}], []) end
    end
  end

  describe "two streams into one function: zip_with" do
    defp joins(source, env) do
      mod = "JoinCase#{System.unique_integer([:positive])}"

      with_env(env, fn ->
        Code.compile_string("""
        defmodule #{mod} do
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
          defhls count(_x :: s16, n :: u8) :: {u8, u8} do
            {n, n + 1}
          end
          defhls wide(x :: s16) :: s32 do
            x
          end
          defhls low16(x :: u32) :: s16 do
            x
          end
          #{source}
        end
        """)
      end)

      Module.concat([mod])
    end

    test "a join block, then a kernel of the pair; the second stream through its own pipe into the join" do
      hw = Path.join(@tmp, "joins_#{System.unique_integer([:positive])}")
      File.rm_rf!(hw)

      m =
        joins(
          """
          definstance mixer(left, right) do
            zip_with(left, right, &mix/2) |> map(&half/1)
          end
          definstance mixer2(left, right) do
            mix(left |> map(&neg/1), right |> neg()) |> half()
          end
          """,
          %{"EHLS_SOC" => "litex", "EHLS_OUT_DIR" => hw}
        )

      priv = :code.priv_dir(:elixir_hls) |> to_string()
      {_, 0} = System.cmd("python3", [Path.join(priv, "gen_manifest.py"), hw])
      [a, b] = Path.join(hw, "pipelines.json") |> File.read!() |> JSON.decode!()
      short = fn st -> (st["kernel"] && st["kernel"] |> String.split("_case") |> List.last() |> String.replace(~r/^\d+_/, "")) || st["block"] end

      assert Enum.map(a["stages"], short) == ["hw__zip", "mix__zip", "half"]
      assert hd(a["stages"])["args"] == [32, 1, 1] and hd(a["stages"])["fields"] == [[16, true], [16, true]]
      assert a["inputs"] == [%{"name" => "left", "type" => "s16", "to" => 0, "port" => 0}, %{"name" => "right", "type" => "s16", "to" => 0, "port" => 1}]
      assert Enum.map(a["ends"], & &1["name"]) == ["left", "right", "out"] and a["output_from"] == 2

      # the call form: each stream's pipe, then the join, its kernel, and what follows
      assert Enum.map(b["stages"], short) == ["neg", "neg", "hw__zip", "mix__zip", "half"]
      assert Enum.map(b["links"], &Map.take(&1, ["from", "to", "port"])) == [
               %{"from" => 2, "to" => 3}, %{"from" => 0, "to" => 2, "port" => 0}, %{"from" => 1, "to" => 2, "port" => 1}, %{"from" => 3, "to" => 4, "port" => 0}
             ]
      assert [%{"name" => "left", "to" => 0}, %{"name" => "right", "to" => 1, "port" => 0}] = b["inputs"]
      assert b["output_from"] == 4

      # the kernel of the pair is a defhls on the CPU too
      assert m.mix__zip({30000, 30000}) == 60000
    end

    test "a join anywhere: in the middle of a pipe, and joins inside joins" do
      hw = Path.join(@tmp, "joins_#{System.unique_integer([:positive])}")
      File.rm_rf!(hw)

      joins(
        """
        definstance mid(left, right) do
          left |> map(&neg/1) |> zip_with(right, &mix/2) |> map(&half/1)
        end
        definstance three(a, b, c) do
          a |> mix(b) |> half() |> mix(c |> neg()) |> half()
        end
        definstance src(right) do
          ticks(10) |> map(&low16/1) |> mix(right) |> half() |> run()
        end
        """,
        %{"EHLS_SOC" => "litex", "EHLS_OUT_DIR" => hw}
      )

      priv = :code.priv_dir(:elixir_hls) |> to_string()
      {_, 0} = System.cmd("python3", [Path.join(priv, "gen_manifest.py"), hw])
      ps = Path.join(hw, "pipelines.json") |> File.read!() |> JSON.decode!() |> Map.new(&{&1["name"], &1})
      short = fn st -> (st["kernel"] && st["kernel"] |> String.split("_case") |> List.last() |> String.replace(~r/^\d+_/, "")) || st["block"] end
      edges = fn p -> p["links"] |> Enum.map(&{&1["from"], &1["to"], &1["port"] || 0}) |> Enum.sort() end

      mid = ps["mid"]
      assert Enum.map(mid["stages"], short) == ["neg", "hw__zip", "mix__zip", "half"]
      assert edges.(mid) == [{0, 1, 0}, {1, 2, 0}, {2, 3, 0}]
      assert [%{"name" => "left", "to" => 0}, %{"name" => "right", "to" => 1, "port" => 1}] = mid["inputs"]

      # (a, b) joined, halved, joined with c
      three = ps["three"]
      assert Enum.map(three["stages"], short) == ["hw__zip", "mix__zip", "half", "neg", "hw__zip", "mix__zip", "half"]
      assert edges.(three) == [{0, 1, 0}, {1, 2, 0}, {2, 4, 0}, {3, 4, 1}, {4, 5, 0}, {5, 6, 0}]
      assert Enum.map(three["inputs"], &{&1["name"], &1["to"], &1["port"]}) == [{"a", 0, 0}, {"b", 0, 1}, {"c", 3, 0}]
      assert three["output_from"] == 6 and Enum.map(three["ends"], & &1["name"]) == ["a", "b", "c", "out"]

      # a source joined with an argument
      assert Enum.map(ps["src"]["stages"], short) == ["ticks", "low16", "hw__zip", "mix__zip", "half", "run"]
      assert [%{"name" => "right", "to" => 2, "port" => 1}] = ps["src"]["inputs"]
    end

    test "a stream bound and used twice is a fork; a statement before the last ends in a sink" do
      hw = Path.join(@tmp, "forks_#{System.unique_integer([:positive])}")
      File.rm_rf!(hw)

      joins(
        """
        definstance tapped(x) do
          y = x |> map(&neg/1)
          y |> map(&neg/1) |> hold(:last)
          y |> map(&neg/1) |> map(&neg/1)
        end
        definstance again(x) do
          y = x |> map(&neg/1)
          y |> mix(y |> map(&neg/1)) |> half()
        end
        definstance once(x) do
          y = x |> map(&neg/1)
          y |> map(&neg/1)
        end
        """,
        %{"EHLS_SOC" => "litex", "EHLS_OUT_DIR" => hw}
      )

      priv = :code.priv_dir(:elixir_hls) |> to_string()
      {_, 0} = System.cmd("python3", [Path.join(priv, "gen_manifest.py"), hw])
      ps = Path.join(hw, "pipelines.json") |> File.read!() |> JSON.decode!() |> Map.new(&{&1["name"], &1})
      short = fn st -> (st["kernel"] && st["kernel"] |> String.split("_case") |> List.last() |> String.replace(~r/^\d+_/, "")) || st["block"] end
      edges = fn p -> p["links"] |> Enum.map(&{&1["from"], &1["from_port"] || 0, &1["to"], &1["port"] || 0}) |> Enum.sort() end

      # y, a fork of two, a branch into a sink, a branch to the CPU
      tap = ps["tapped"]
      assert Enum.map(tap["stages"], short) == ["neg", "hw__fork", "neg", "hold", "neg", "neg"]
      assert Enum.at(tap["stages"], 1)["args"] == [32, 1, 2]
      assert edges.(tap) == [{0, 0, 1, 0}, {1, 0, 2, 0}, {1, 1, 4, 0}, {2, 0, 3, 0}, {4, 0, 5, 0}]
      assert tap["output_from"] == 5 and tap["output_port"] == nil

      # a fork joined again
      again = ps["again"]
      assert Enum.map(again["stages"], short) == ["neg", "hw__fork", "neg", "hw__zip", "mix__zip", "half"]
      assert edges.(again) == [{0, 0, 1, 0}, {1, 0, 3, 0}, {1, 1, 2, 0}, {2, 0, 3, 1}, {3, 0, 4, 0}, {4, 0, 5, 0}]

      # used once: no fork
      assert Enum.map(ps["once"]["stages"], short) == ["neg", "neg"]
    end

    test "with a runtime backend: f(a, b) with two lists, :send per input" do
      m = joins("definstance mixer(left, right) do\nzip_with(left, right, &mix/2)\nend", %{"EHLS_SOC" => "litex", "EHLS_RUNTIME" => "atomvm"})
      for n <- [2, 3], do: assert(function_exported?(m, :mixer, n))
      assert_raise FunctionClauseError, fn -> m.mixer(:in, [1]) end
    end

    test "what cannot be stops the compile" do
      for {source, msg} <- [
            {"definstance i(a, b) do\nzip_with(a, b, &mix(&1, &2))\nend", ~r/zip_with\(a, b, &f\/2\)/},
            {"definstance i(a, b) do\nzip_with(a, b, &nope/2)\nend", ~r/nope is no defhls of two arguments/},
            {"definstance i(a, b) do\nzip_with(a, b, &half/2)\nend", ~r/zip_with takes a function of two arguments, half has 1/},
            {"definstance i(a, b) do\nzip_with(a, a, &mix/2)\nend", ~r/a used twice: an argument goes in once/},
            {"definstance i(a, b) do\nzip_with(a, c, &mix/2)\nend", ~r/c is no argument of i/},
            {"definstance i(a, b) do\nzip_with(a, b |> map(&count/1), &mix/2)\nend", ~r/count takes 2 arguments/},
            {"definstance i(a) do\ny = a |> neg()\ny |> neg()\ny |> neg()\nend", ~r/a stream nobody takes/},
            {"definstance i(a) do\ny = a |> neg()\na |> neg()\nend", ~r/nothing happens to y/},
            {"definstance i(a) do\ny = a\ny |> neg()\nend", ~r/y = an argument: use the argument/},
            {"definstance i(a) do\na = a |> neg()\na |> neg()\nend", ~r/a is an argument already/},
            {"definstance i(a) do\n{y, z} = a |> neg()\ny\nend", ~r/a stream is named by a variable/},
            {"definstance i(a) do\ny |> neg()\nend", ~r/y is no argument of i and no stream bound before/},
            {"definstance i(a, b) do\nzip_with(a, b |> map(&wide/1), &mix/2)\nend", ~r/wide gives s32 and mix's second argument is s16, which would change the value/}
          ] do
        assert_raise CompileError, msg, fn -> joins(source, %{"EHLS_SOC" => "litex"}) end
      end
    end
  end

  describe "an instance called inside an instance" do
    defp calls_manifest(source) do
      hw = Path.join(@tmp, "calls_#{System.unique_integer([:positive])}")
      File.rm_rf!(hw)

      with_env(%{"EHLS_SOC" => "litex", "EHLS_OUT_DIR" => hw}, fn ->
        Code.compile_string("""
        defmodule CallOther#{Path.basename(hw)} do
          use EHLS
          defhls neg(x :: s16) :: s16 do
            -x
          end
          definstance fir_hw(x) do
            x |> map(&neg/1)
          end
        end
        defmodule CallCase#{Path.basename(hw)} do
          use EHLS
          alias CallOther#{Path.basename(hw)}, as: Other
          defhls dbl(x :: s16) :: s16 do
            x * 2
          end
          defhls wide(x :: s16) :: s32 do
            x
          end
          definstance inner(x) do
            x |> map(&dbl/1)
          end
          #{source}
        end
        """)
      end)

      priv = :code.priv_dir(:elixir_hls) |> to_string()
      {msg, status} = System.cmd("python3", [Path.join(priv, "gen_manifest.py"), hw], stderr_to_stdout: true)
      {status, msg, if(status == 0, do: Path.join(hw, "pipelines.json") |> File.read!() |> JSON.decode!() |> Map.new(&{&1["name"], &1}))}
    end

    test "wired: the callee's input and output are no CPU ends" do
      {0, _, ps} = calls_manifest("definstance outer(s) do\ns |> map(&dbl/1) |> inner() |> Other.fir_hw() |> map(&dbl/1)\nend")
      outer = ps["outer"]
      assert [%{"call" => _, "in_type" => "s16", "out_type" => "s16"}, %{"in_type" => "s16", "out_type" => "s16", "gives_to" => "s16"}] =
               Enum.filter(outer["stages"], &Map.has_key?(&1, "call"))

      assert Enum.map(outer["ends"], & &1["name"]) == ["s", "out"]
      assert ps["inner"]["wired"] == %{"in" => "x", "out" => true} and ps["inner"]["ends"] == []
      assert ps["fir_hw"]["ends"] == []
    end

    test "a call as a statement: the callee's output stays its own" do
      {0, _, ps} = calls_manifest("definstance outer(s) do\ny = s |> map(&dbl/1)\ny |> inner()\ny |> map(&dbl/1)\nend")
      assert ps["inner"]["wired"] == %{"in" => "x"} and Enum.map(ps["inner"]["ends"], & &1["name"]) == ["out"]
    end

    test "what cannot be stops putting the circuits together, or the compile" do
      for {source, msg} <- [
            {"definstance a(s) do\ns |> map(&dbl/1) |> inner() |> map(&dbl/1)\nend\ndefinstance b(s) do\ns |> map(&dbl/1) |> inner() |> map(&dbl/1)\nend", "is called in"},
            {"definstance a(s) do\ns |> map(&wide/1) |> inner() |> map(&dbl/1)\nend", "s32 goes into"},
            {"definstance a(s) do\ns |> map(&dbl/1) |> Nope.f() |> map(&dbl/1)\nend", "Nope.f is no instance of this build"},
            {"definstance a do\nOther.fir_hw() |> map(&dbl/1)\nend", "takes a stream, and none goes in"}
          ] do
        assert {1, out, _} = calls_manifest(source)
        assert out =~ msg
      end

      assert_raise CompileError, ~r/it ends in inner, an instance/, fn -> calls_manifest("definstance a(s) do\ns |> map(&dbl/1) |> inner()\nend") end
      assert_raise CompileError, ~r/s goes straight into inner, an instance/, fn -> calls_manifest("definstance a(s) do\ns |> inner() |> map(&dbl/1)\nend") end
      assert_raise CompileError, ~r/it calls itself/, fn -> calls_manifest("definstance a(s) do\ns |> a() |> map(&dbl/1)\nend") end
    end
  end

  describe "events: EHLS.PubSub.broadcast(topic) and EHLS.PubSub.subscribe(topic)" do
    defp events_manifest(source) do
      hw = Path.join(@tmp, "events_#{System.unique_integer([:positive])}")
      File.rm_rf!(hw)

      with_env(%{"EHLS_SOC" => "litex", "EHLS_OUT_DIR" => hw}, fn ->
        Code.compile_string("""
        defmodule EventsCase#{Path.basename(hw)} do
          use EHLS
          defhls count(_x :: u32, n :: u16) :: {u16, u16} do
            {n + 1, n + 1}
          end
          defhls neg(x :: s16) :: s16 do
            -x
          end
          defhls wide(x :: u32) :: u40 do
            x
          end
          #{source}
        end
        """)
      end)

      priv = :code.priv_dir(:elixir_hls) |> to_string()
      {msg, status} = System.cmd("python3", [Path.join(priv, "gen_manifest.py"), hw], stderr_to_stdout: true)

      if status == 0,
        do: {0, Path.join(hw, "topics.json") |> File.read!() |> JSON.decode!(), Path.join(hw, "pipelines.json") |> File.read!() |> JSON.decode!()},
        else: {status, msg, nil}
    end

    test "each element of what goes into EHLS.PubSub.broadcast(topic) an event; topics numbered by name, typed" do
      {0, topics, ps} =
        events_manifest("""
        definstance presses do
          ticks(10) |> transform(0, &count/2) |> EHLS.PubSub.broadcast(:presses)
        end
        definstance both(x) do
          y = x |> map(&neg/1)
          y |> EHLS.PubSub.broadcast(:negated)
          y |> map(&neg/1)
        end
        """)

      assert topics == [%{"name" => "negated", "id" => 0, "type" => "s16"}, %{"name" => "presses", "id" => 1, "type" => "u16"}]
      ids = for p <- ps, st <- p["stages"], st["block"] == "broadcast", do: {hd(st["args"]), st["topic_id"]}
      assert Enum.sort(ids) == [{"negated", 0}, {"presses", 1}]
      # a sink: the instance ending in broadcast has no output to the CPU
      assert Enum.find(ps, &(&1["name"] == "presses"))["output"] == nil
    end

    test "what cannot be stops the compile, or putting the circuits together" do
      assert {1, msg, _} = events_manifest("definstance a do\nticks(10) |> map(&wide/1) |> EHLS.PubSub.broadcast(:w)\nend")
      assert msg =~ "an event is one value up to 32 bits"

      assert {1, msg, _} =
               events_manifest("definstance a do\nticks(10) |> transform(0, &count/2) |> EHLS.PubSub.broadcast(:t)\nend\ndefinstance b(x) do\nx |> map(&neg/1) |> EHLS.PubSub.broadcast(:t)\nend")

      assert msg =~ "one type per topic"
      assert_raise CompileError, ~r/broadcast\(topic\), a topic as an atom/, fn -> events_manifest("definstance a do\nticks(10) |> EHLS.PubSub.broadcast(1)\nend") end
    end

    test "EHLS.PubSub.subscribe(topic) in an instance: a source of the topic's events, typed when the circuits are put together" do
      {0, _topics, ps} =
        events_manifest("""
        definstance ticker do
          ticks(10) |> transform(0, &count/2) |> EHLS.PubSub.broadcast(:presses)
        end
        definstance doubler do
          EHLS.PubSub.subscribe(:presses) |> map(&dbl/1) |> EHLS.PubSub.broadcast(:doubled)
        end
        definstance last do
          EHLS.PubSub.subscribe(:presses) |> map(&dbl/1) |> hold(:v)
        end
        definstance to_cpu, overflow: :drop do
          EHLS.PubSub.subscribe(:doubled) |> map(&dbl/1)
        end
        defhls dbl(x :: u32) :: u32 do
          x * 2
        end
        """)

      subs = for p <- ps, st <- p["stages"], st["block"] == "subscribe", do: {p["name"], hd(st["args"]), st["type"], st["gives_to"]}
      assert Enum.sort(subs) == [{"doubler", "presses", "u16", "u32"}, {"last", "presses", "u16", "u32"}, {"to_cpu", "doubled", "u32", "u32"}]
    end

    test "EHLS.PubSub.subscribe(topic): what cannot be stops the compile, or putting the circuits together" do
      assert {1, msg, _} = events_manifest("definstance a do\nEHLS.PubSub.subscribe(:nobody) |> map(&neg/1) |> run()\nend")
      assert msg =~ "nothing in this build publishes nobody"

      assert {1, msg, _} =
               events_manifest("definstance p do\nticks(10) |> transform(0, &count/2) |> EHLS.PubSub.broadcast(:t)\nend\ndefinstance a do\nEHLS.PubSub.subscribe(:t) |> map(&neg/1) |> run()\nend")

      assert msg =~ "EHLS.PubSub.subscribe(t) gives u16, taken as s16: that would change the value"
      assert_raise CompileError, ~r/its source cannot wait/, fn -> events_manifest("definstance a do\nEHLS.PubSub.subscribe(:t) |> map(&neg/1)\nend") end
      assert_raise CompileError, ~r/whose type is known only when the circuits are put together/, fn ->
        events_manifest("definstance a, overflow: :drop do\nEHLS.PubSub.subscribe(:t)\nend")
      end
    end

    test "filter(&f/1) keeps what f says yes to, as Enum.filter; changes(k_hw(:value)) gives each change" do
      hw = Path.join(@tmp, "filter_#{System.unique_integer([:positive])}")
      File.rm_rf!(hw)
      mod = "FilterCase#{System.unique_integer([:positive])}"

      with_env(%{"EHLS_SOC" => "litex", "EHLS_OUT_DIR" => hw}, fn ->
        Code.compile_string("""
        defmodule #{mod} do
          use EHLS
          defhls big?(x :: s16) :: u1 do
            if x > 100, do: 1, else: 0
          end
          defhls neg(x :: s16) :: s16 do
            -x
          end
          defhls bigs(x :: stream(s16)) :: stream(s16) do
            x |> filter(&big?/1) |> map(&neg/1)
          end
          definstance k_hw(k :: u16) do
            k
          end
          definstance watcher do
            y = changes(k_hw(:value))
            y |> EHLS.PubSub.broadcast(:k)
            y |> filter(&small/1) |> EHLS.PubSub.broadcast(:small)
          end
          defhls small(x :: u16) :: u1 do
            if x < 10, do: 1, else: 0
          end
        end
        """)
      end)

      m = Module.concat([mod])
      assert m.bigs([5, 200, -3, 101, 100]) == [-200, -101]

      priv = :code.priv_dir(:elixir_hls) |> to_string()
      {_, 0} = System.cmd("python3", [Path.join(priv, "gen_manifest.py"), hw])
      [w] = for p <- Path.join(hw, "pipelines.json") |> File.read!() |> JSON.decode!(), p["name"] == "watcher", do: p
      assert [%{"block" => "hw__changes", "from" => from, "type" => "u16"} | _] = w["stages"]
      assert from == "#{mod}.k_hw"
      assert Enum.any?(w["stages"], &(&1["kernel"] && String.ends_with?(&1["kernel"], "small__filter")))

      for {source, msg} <- [
            {"definstance a do\nchanges(nope(:value)) |> EHLS.PubSub.broadcast(:x)\nend", ~r/nope is no instance of values/},
            {"definstance a(x) do\nx |> filter(&neg/2)\nend", ~r/filter\(&f\/1\)/},
            {"definstance a(x) do\nx |> filter(&nope/1)\nend", ~r/nope is no defhls of one argument/}
          ] do
        assert_raise CompileError, msg, fn ->
          with_env(%{"EHLS_SOC" => "litex"}, fn ->
            Code.compile_string("defmodule F#{System.unique_integer([:positive])} do\nuse EHLS\ndefhls neg(x :: s16) :: s16 do\n-x\nend\n#{source}\nend")
          end)
        end
      end
    end

    test "without a runtime backend subscribing says where events come from" do
      assert_raise ArgumentError, ~r/events come from a board/, fn -> EHLS.PubSub.subscribe(:presses) end
    end

    test "active: and timestamps: go to the runtime as a count and a flag" do
      Code.compile_string("""
      defmodule :hw_kernels do
        def runtime, do: :hw_events_stub
        def topic(:presses), do: {3, 16, false}
      end

      defmodule :hw_events_stub do
        def event_subscribe(id, topic, bits, signed, pid, active, stamps) do
          send(pid, {:subscribed, id, topic, bits, signed, active, stamps})
          :ok
        end
      end
      """)

      assert EHLS.PubSub.subscribe(:presses) == :ok
      assert_received {:subscribed, 3, :presses, 16, false, -1, false}
      EHLS.PubSub.subscribe(:presses, active: :once, timestamps: true)
      assert_received {:subscribed, 3, :presses, 16, false, 1, true}
      EHLS.PubSub.subscribe(:presses, active: 5)
      assert_received {:subscribed, 3, :presses, 16, false, 5, false}
      assert_raise ArgumentError, ~r/active: true, :once or a positive integer/, fn -> EHLS.PubSub.subscribe(:presses, active: 0) end
      assert_raise ArgumentError, ~r/timestamps: true or false/, fn -> EHLS.PubSub.subscribe(:presses, timestamps: :yes) end
    after
      for m <- [:hw_kernels, :hw_events_stub] do
        :code.purge(m)
        :code.delete(m)
      end
    end
  end

  defp with_env(vars, fun) do
    old = Map.new(vars, fn {k, _} -> {k, System.get_env(k)} end)
    Enum.each(vars, fn {k, v} -> System.put_env(k, v) end)

    try do
      fun.()
    after
      Enum.each(old, fn {k, v} -> if v, do: System.put_env(k, v), else: System.delete_env(k) end)
    end
  end

  @tag :circt
  @tag timeout: :infinity
  test "every case matches its Elixir function in simulation (CIRCT, iverilog)" do
    out = Path.join(@tmp, "circt")
    cases = Enum.map(["cases/defhls_cases.ex", "cases/defhls_mem_cases.ex", "cases/defhls_call_cases.ex", "cases/defhls_syntax_cases.ex"], &Path.expand(&1, __DIR__))
    Mix.Tasks.Ehls.Compile.run(["--out", out | cases])
    assert File.exists?(Path.join([out, "hw", "kernels.json"]))

    # a tuple's second value gets the edge values too, not only random ones
    xs =
      for line <- File.read!(Path.join([out, "hw", "defhls_call_cases_swap.vec"])) |> String.split("\n"),
          [x | _] <- [String.split(line)], x != "R",
          do: x |> String.split(",") |> Enum.map(&String.to_integer(&1, 16))

    assert length(xs) == 2 * 11 + 2000
    for e <- [0, 0x8000, 0xFFFF, 0x7FFFFFFF, 0x80000000], do: assert(Enum.any?(xs, &match?([_, ^e], &1)))
  end

  describe "instances in simulation" do
    defp sim_broken(hw, name, first, last, change) do
      path = Path.join(hw, "pipelines.json")
      saved = File.read!(path)
      pipelines = JSON.decode!(saved)
      pi = Enum.find_index(pipelines, &(&1["name"] == name))
      File.write!(path, JSON.encode!(List.update_at(pipelines, pi, change)))

      try do
        Mix.Tasks.Ehls.Sim.simulate(hw, pi, first, last)
      after
        File.write!(path, saved)
      end
    end

    @tag :circt
    @tag timeout: :infinity
    test "each piece matches its Elixir functions, and a changed circuit does not" do
      out = Path.join(@tmp, "sim")
      hw = Path.join(out, "hw")

      with_env(%{"EHLS_SOC" => "litex"}, fn ->
        Mix.Tasks.Ehls.Sim.run(["--out", out, "--vectors", "200", Path.expand("cases/instance_cases.ex", __DIR__)])
      end)

      stage = fn i, f -> fn p -> Map.update!(p, "stages", &List.update_at(&1, i, f)) end end
      for {name, last, change} <- [
            {"from_seven", 1, stage.(0, &Map.put(&1, "init", [8]))},
            {"from_seven", 1, stage.(1, &Map.put(&1, "init", [101]))},
            {"signs", 2, stage.(1, &Map.put(&1, "init", [0]))},
            {"sum_hw", 0, &put_in(&1, ["level", "initial"], [8])},
            # the level as the stage takes it: another value is another result
            {"stepped", 3, stage.(3, fn st -> Map.update!(st, "args", fn [prm] -> [%{prm | "default" => -6}] end) end)},
            {"wide_hw", 0, &put_in(&1, ["level", "initial"], [2, 0xFF])}
          ] do
        assert Enum.any?(sim_broken(hw, name, 0, last, change), &String.starts_with?(&1, "MISMATCH")), "#{name} was not caught"
      end

      [%{"init" => [3], "state_name" => "n"}] =
        for p <- Path.join(hw, "pipelines.json") |> File.read!() |> JSON.decode!(), p["name"] == "between", do: Enum.at(p["stages"], 1)
    end
  end
end
