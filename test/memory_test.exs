defmodule EHLS.MemoryTest do
  use ExUnit.Case

  # A tuple in a function's state is a value, as in Elixir: the next state replaces it whole. Placed with transform it
  # is registers; with memory: [:h] the tuple h is a memory (block RAM), written in place (EHLS.TupleState)

  defmodule Mem do
    use EHLS

    # the old one under another name, and a read of the one rewritten in the step
    defhls swap(x :: u8, {pos, m} :: {u2, tuple(u8, 4)}) :: {u16, {u2, tuple(u8, 4)}} do
      old = m
      m2 = put_elem(m, pos, x)
      {elem(old, pos) + elem(m2, pos) * 256, {pos + 1, m2}}
    end

    # the tuple the whole state, a list for a missing output, an if choosing the next one
    defhls every2(x :: u8, m :: tuple(u8, 2)) :: {[u8], tuple(u8, 2)} do
      if elem(m, 0) == 1, do: {[x], put_elem(m, 0, 0)}, else: {[], put_elem(m, 0, 1)}
    end

    # a new tuple as the next state: fine in registers
    defhls shift(x :: u8, m :: {u8, u8, u8}) :: {u8, {u8, u8, u8}} do
      {a, b, _} = m
      {elem(m, 2), {x, a, b}}
    end

    # two tuples, one a memory, the other registers; and a tuple written out
    defhls two(x :: u8, {pos, a, b} :: {u2, tuple(u8, 4), {u8, u8, u8, u8}}) :: {u8, {u2, tuple(u8, 4), {u8, u8, u8, u8}}} do
      {elem(a, pos) + elem(b, pos), {pos + 1, put_elem(a, pos, x + 200), put_elem(b, pos, x + 100)}}
    end

    # a chunk is no state: a function of a chunk and a state, its output a list
    defhls sums(w :: tuple(u8, 2), acc :: u8) :: {[u8], u8} do
      s = elem(w, 0) + elem(w, 1)
      if s > acc, do: {[s], s}, else: {[], acc}
    end

    definstance two_a(w), on: :cpu do
      w |> transform({0, Tuple.duplicate(0, 4), {0, 0, 0, 0}}, &two/2, memory: [:a])
    end

    definstance two_b(w), on: :cpu do
      w |> transform({0, Tuple.duplicate(0, 4), {0, 0, 0, 0}}, &two/2, memory: [:b])
    end

    definstance halves(w), on: :cpu do
      w |> transform(Tuple.duplicate(0, 2), &every2/2)
    end

    definstance halves_m(w), on: :cpu do
      w |> transform(Tuple.duplicate(0, 2), &every2/2, memory: [:m])
    end

    definstance shifted(w), on: :cpu do
      w |> transform({7, 8, 9}, &shift/2)
    end
  end

  test "a function with a tuple in its state is the Elixir function, the values cut to their types" do
    assert Mem.swap(300, {1, {1, 2, 3, 4}}) == {2 + 44 * 256, {2, {1, 44, 3, 4}}}
    assert Mem.every2(7, {1, 0}) == {[7], {0, 0}}
    # a state of another shape is no state of the function
    assert_raise MatchError, fn -> Mem.swap(1, {3, {1, 2}}) end
  end

  test "placed in registers or in a memory, an instance gives the same" do
    assert Mem.halves([1, 2, 3, 4]) == [2, 4]
    assert Mem.halves_m([1, 2, 3, 4]) == [2, 4]
    xs = [1, 2, 3, 4, 100, 150, 200]
    {want, last} = EHLS.run_cpu(&Mem.two/2, xs, {0, Tuple.duplicate(0, 4), {0, 0, 0, 0}})
    assert Mem.two_a(xs) == want and Mem.two_b(xs) == want
    # the function made where it is placed, as the simulation runs it: the tuple left in registers cut to its type
    assert EHLS.run_cpu(&Mem.two__m_b/2, xs, Mem.two__m_b(:zero)) == {want, last}
    assert EHLS.run_cpu(&Mem.two__m_a/2, xs, Mem.two__m_a(:zero)) == {want, last}
    assert Mem.sums({1, 5}, 0) == {[6], 6} and Mem.sums({1, 2}, 6) == {[], 6}
    # registers take any initial value and a new tuple as the next state
    assert Mem.shifted([1, 2, 3]) == [9, 8, 7]
  end

  defmodule FakeRT do
    # a stage's words and its memory space, as the board's runtime gives them
    def peek(3, 2), do: [7, 0xFE]
    def mem_read(3, 8, 4), do: [1, 0xFFFF, 0x8000, 5]
  end

  test "a named state with a memory is read whole: its values, then the memory word by word" do
    parts = [{:val, 0}, {:val, 0}, {:mem, 8, 4, {16, true}}]
    assert EHLS.__state__(FakeRT, 3, [{8, false}, {8, true}], parts) == {7, -2, {1, -1, -32768, 5}}
    # the whole state one memory: no words of values
    assert EHLS.__state__(FakeRT, 3, [], [{:mem, 8, 4, {16, false}}]) == {1, 0xFFFF, 0x8000, 5}
    # a value that is a tuple takes its words in order
    assert EHLS.__state__(FakeRT, 3, [{8, false}, {8, false}], [{:val, {0, 0}}, {:mem, 8, 4, {8, false}}]) == {{7, 0xFE}, {1, 0xFF, 0, 5}}
  end

  test "with memory: what a memory cannot be stops the compile" do
    place = fn body, init, mem ->
      Code.compile_string("""
      defmodule MemBad#{System.unique_integer([:positive])} do
        use EHLS
        defhls f(x :: u8) :: u8 do
          x
        end
        defhls g(x :: u8, {pos, m} :: {u2, tuple(u8, 4)}) :: {u8, {u2, tuple(u8, 4)}} do
          #{body}
        end
        definstance i(w), on: :cpu do
          w |> transform(#{init}, &g/2, memory: #{mem})
        end
      end
      """)
    end

    zero = "{0, Tuple.duplicate(0, 4)}"

    for {body, init, mem, msg} <- [
          {"{f(m), {pos, m}}", zero, "[:m]", ~r/m, a tuple of the state, is read with elem\(m, i\)/},
          {"{x, {pos, Tuple.duplicate(0, 4)}}", zero, "[:m]", ~r/a new tuple would be a copy/},
          {"{x, {pos, put_elem(m, 0, x)}}", "{0, {1, 0, 0, 0}}", "[:m]", ~r/starts from zeros/},
          {"{x, {pos, put_elem(m, 0, x)}}", zero, "[:nope]", ~r/no part nope/},
          {"{x, {pos, put_elem(m, 0, x)}}", zero, "[:pos]", ~r/pos is no tuple of one type/}
        ] do
      assert_raise CompileError, msg, fn -> place.(body, init, mem) end
    end

    # without memory: the same bodies are registers, fine
    for body <- ["{f(elem(m, 0)), {pos, m}}", "{x, {pos, Tuple.duplicate(0, 4)}}"] do
      Code.compile_string("""
      defmodule MemReg#{System.unique_integer([:positive])} do
        use EHLS
        defhls f(x :: u8) :: u8 do
          x
        end
        defhls g(x :: u8, {pos, m} :: {u2, tuple(u8, 4)}) :: {u8, {u2, tuple(u8, 4)}} do
          #{body}
        end
        definstance i(w), on: :cpu do
          w |> transform({0, {1, 2, 3, 4}}, &g/2)
        end
      end
      """)
    end

    one = fn src ->
      Code.compile_string("defmodule MemOne#{System.unique_integer([:positive])} do\nuse EHLS\n#{src}\nend")
    end

    # a whole state of one type written out is a memory as tuple(t, n) is
    [{m, _}] =
      one.("""
      defhls r(x :: u8, h :: {u8, u8, u8, u8}) :: {u8, {u8, u8, u8, u8}} do
        {elem(h, 3), put_elem(h, x &&& 3, x)}
      end
      definstance i(w), on: :cpu do
        w |> transform(Tuple.duplicate(0, 4), &r/2, memory: [:h])
      end
      """)

    assert m.i([1, 3, 7, 2]) == [0, 0, 3, 7]

    # a state that is a tuple of one part, {h}: a tuple holding the memory, on the CPU and when read
    [{m1, _}] =
      one.("""
      defhls r1(x :: u8, {h} :: {tuple(u8, 4)}) :: {u8, {tuple(u8, 4)}} do
        {elem(h, 3), {put_elem(h, x &&& 3, x)}}
      end
      definstance i(w), on: :cpu do
        w |> transform({Tuple.duplicate(0, 4)}, &r1/2, memory: [:h], name: :s)
      end
      """)

    assert m1.r1__m_h(:zero) == {{0, 0, 0, 0}}
    assert m1.i([1, 3, 7, 2]) == [0, 0, 3, 7]
    assert m1.i(:state, :s) == {{0, 1, 2, 7}}

    assert_raise CompileError, ~r/levels with a memory are not there yet/, fn ->
      one.("""
      defhls l(x :: u8, {pos, h} :: {u2, tuple(u8, 4)}, k :: u8) :: {u8, {u2, tuple(u8, 4)}} do
        {elem(h, pos) + k, {pos + 1, put_elem(h, pos, x)}}
      end
      definstance i(w), on: :cpu do
        w |> transform({0, Tuple.duplicate(0, 4)}, &l(&1, &2, 3), memory: [:h])
      end
      """)
    end

    assert_raise CompileError, ~r/test its parts in the body/, fn ->
      one.("""
      defhls gd(x :: u8, {pos, h} :: {u2, tuple(u8, 4)}) :: {u8, {u2, tuple(u8, 4)}} when pos < 3 do
        {x, {pos, h}}
      end
      """)
    end

    assert_raise CompileError, ~r/a memory is a tuple in the state/, fn ->
      Code.compile_string("""
      defmodule MemOld#{System.unique_integer([:positive])} do
        use EHLS
        defhls g(x :: u8, pos :: u2, m :: memory(u8, 4)) :: {u8, u2} do
          {x, pos}
        end
      end
      """)
    end
  end
end
