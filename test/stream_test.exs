defmodule EHLS.StreamTest do
  use ExUnit.Case

  defmodule Fns do
    use EHLS
    alias EHLS.Stream, as: S

    defhls twice(x :: u8) :: u16 do
      x * 2
    end

    defhls odd(x :: u8) :: u1 do
      x &&& 1
    end

    defhls count(_x :: u16, n :: u8) :: {u8, u8} do
      {n, n + 1}
    end

    defhls half(x :: u16, on :: u1) :: {[u16], u1} do
      if on == 1, do: {[x], 0}, else: {[], 1}
    end

    defhls mix(a :: u8, b :: u8) :: u16 do
      a + b * 256
    end

    defhls diff(w :: tuple(s16, 3)) :: s18 do
      elem(w, 2) - elem(w, 0)
    end

    definstance plain(w), on: :cpu do
      w |> filter(&odd/1) |> map(&twice/1) |> transform(1, &half/2)
    end

    definstance moduled(w), on: :cpu do
      w |> EHLS.Stream.filter(&odd/1) |> S.map(&twice/1) |> S.transform(1, &half/2)
    end

    definstance counted(w), on: :cpu do
      w |> transform(5, &count/2)
    end

    definstance zipped(a, b), on: :cpu do
      zip_with(a, b, &mix/2)
    end

    definstance gaps(w), on: :cpu do
      w |> chunk_every(3, 4, :discard) |> map(&diff/1)
    end

    definstance chunks(w), on: :cpu do
      w |> chunk_every(3, 2, :discard) |> map(&diff/1)
    end
  end

  alias EHLS.Stream, as: S

  test "called as functions they give what the instance gives, as Stream does" do
    xs = Enum.to_list(1..9)
    expected = xs |> S.filter(&Fns.odd/1) |> S.map(&Fns.twice/1) |> S.transform(1, &Fns.half/2) |> Enum.to_list()
    assert expected == [2, 10, 18]
    assert Fns.plain(xs) == expected
    assert Fns.moduled(xs) == expected
    assert Fns.counted([0, 0, 0]) == Enum.to_list(S.transform([0, 0, 0], 5, &Fns.count/2))
    assert Fns.zipped([1, 2], [3, 4]) == Enum.to_list(S.zip_with([1, 2], [3, 4], &Fns.mix/2))
  end

  test "chunk_every: as Stream.chunk_every with :discard, the first chunk once count elements have come" do
    xs = [1, 5, 2, 8, 3, 9, 4]
    # Stream.chunk_every's chunks, each as a tuple
    expected = xs |> Stream.chunk_every(3, 2, :discard) |> Enum.map(&Fns.diff(List.to_tuple(&1)))
    assert expected == [1, 1, 1]
    assert Enum.to_list(xs |> S.chunk_every(3, 2, :discard) |> S.map(&Fns.diff/1)) == expected
    assert Fns.chunks(xs) == expected
    # the instance goes on from where it was, as the circuit does; from the start, two are no chunk yet
    Fns.chunks(:stop)
    Fns.chunks(:start)
    assert Fns.chunks([1, 2]) == []
    assert Fns.chunks([7]) == [6]
  end

  test "chunk_every with a step over the count: the elements between the chunks left out, as Stream.chunk_every" do
    xs = [1, 5, 2, 8, 3, 9, 4, 7, 6, 0]
    expected = xs |> Stream.chunk_every(3, 4, :discard) |> Enum.map(&Fns.diff(List.to_tuple(&1)))
    assert expected == [1, 1]
    assert Fns.gaps(xs) == expected
  end

  test "run takes every element and gives :ok; options are checked" do
    assert S.run(S.map([1, 2], &Fns.twice/1)) == :ok
    assert_raise ArgumentError, ~r/unknown option/, fn -> S.map([1], &Fns.twice/1, nope: 1) end
    assert Enum.to_list(S.transform([1], 0, &Fns.count/2, name: :n)) == [0]
  end

  test "what chunk_every cannot be stops the compile" do
    for {src, msg} <- [
          {"w |> chunk_every(3, 2) |> map(&diff/1)", ~r/chunk_every\(count, step, :discard\)/},
          {"w |> chunk_every(4, 2, :discard) |> map(&diff/1)", ~r/a function of 3 elements/},
          {"w |> chunk_every(3, 2, :discard)", ~r/followed by map\(&f\/1\)/}
        ] do
      assert_raise CompileError, msg, fn ->
        Code.compile_string("""
        defmodule ChunkCase#{System.unique_integer([:positive])} do
          use EHLS
          defhls diff(w :: tuple(s16, 3)) :: s18 do
            elem(w, 2) - elem(w, 0)
          end
          definstance i(w) do
            #{src}
          end
        end
        """)
      end
    end

    assert_raise CompileError, ~r/Enum.at\(@t, i\)/, fn ->
      Code.compile_string("""
      defmodule TableOld#{System.unique_integer([:positive])} do
        use EHLS
        @t [1, 2, 3, 4]
        defhls f(i :: u2) :: u8 do
          table(@t, i)
        end
      end
      """)
    end

    assert_raise CompileError, ~r/w is a tuple: elem\(w, i\)/, fn ->
      Code.compile_string("""
      defmodule ChunkIndex#{System.unique_integer([:positive])} do
        use EHLS
        defhls f(w :: tuple(s16, 2)) :: s16 do
          w[0]
        end
      end
      """)
    end
  end
end
