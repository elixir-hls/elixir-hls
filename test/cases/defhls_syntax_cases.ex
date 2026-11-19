defmodule DefhlsSyntaxCases do
  @moduledoc "case, cond, patterns, several clauses and wide values; checked by `mix ehls.compile` in simulation against the CPU."
  use EHLS

  # case on an integer, with a variable and guard
  defhls by_case(x :: u32) :: u32 do
    case x &&& 7 do
      0 -> 100
      1 -> x >>> 3
      n when n > 5 -> n * 2
      n -> n + 1000
    end
  end

  # case on a tuple, ^ and _ in it; the clause's names do not reach what follows
  defhls by_tuple(x :: u32) :: u32 do
    n = x &&& 3
    y =
      case {n, x >>> 2 &&& 3} do
        {0, 0} -> 1
        {a, ^n} -> a + 10
        {_, b} -> b + 20
      end

    y + n
  end

  defhls by_cond(x :: s32) :: s32 do
    cond do
      x < -100 -> -1
      x < 100 and x > 0 -> x * 3
      x == 0 -> 77
      true -> x
    end
  end

  # negative literal
  defhls neg_lit(x :: s8) :: s8 do
    case x do
      -1 -> 1
      -128 -> 127
      other -> other
    end
  end

  # calls a function defined below it
  defhls calls_below(x :: u32) :: u32 do
    classify(x &&& 0xFF) + 1
  end

  # several clauses, with patterns and guards
  defhls classify(0 :: u8) :: u8 do
    200
  end

  defhls classify(x :: u8) :: u8 when x < 16 do
    x * 2
  end

  defhls classify(x :: u8) :: u8 do
    x >>> 1
  end

  defhls pair_sum({0, b} :: {u16, u16}) :: u16 do
    b
  end

  defhls pair_sum({a, b} :: {u16, u16}) :: u16 do
    a + b
  end

  defhls of_pair(x :: u32) :: u32 do
    pair_sum({x &&& 0xFFFF, x >>> 16})
  end

  # a step function with clauses: state and emit
  defhls every_third(x :: u32, 2 :: u2) :: {[u32], u2} do
    {[x], 0}
  end

  defhls every_third(_x :: u32, n :: u2) :: {[u32], u2} do
    {[], n + 1}
  end

  # wider than a port: only inside. A 48-bit product of which the kernel keeps the high word
  defhls mul48(a :: u24, b :: u24) :: u48 do
    a * b
  end

  defhls high(v :: u48) :: u32 do
    v >>> 16
  end

  defhls wide(x :: u32) :: u32 do
    high(mul48(x, x >>> 8))
  end

  # kernels with 64-bit ports: a value over 32 bits out, in, both, with a state and in a tuple
  defhls mul_wide(x :: u32) :: u48 do
    x * 0xABCD
  end

  defhls high_of(v :: u48) :: u16 do
    v >>> 32
  end

  defhls neg_wide(x :: s60) :: s60 do
    0 - x
  end

  defhls flip64(x :: u64) :: u64 do
    x ^^^ 0xFFFF_0000_FFFF_0000
  end

  defhls acc_wide(x :: s40, s :: s32) :: {s40, s32} do
    {x + s, s + 1}
  end

  defhls pair_wide(p :: {u8, s48}) :: {s48, u8} do
    {a, b} = p
    {b - a, a + 1}
  end
end
