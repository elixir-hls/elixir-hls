defmodule DefhlsCases do
  @moduledoc "defhls functions exercising EHLS.MLIR; checked by `mix ehls.compile test/cases/defhls_cases.ex` (test/ehls_test.exs)."
  use EHLS

  # unsigned compare, xor, left shift
  defhls mix(x :: u32) :: u32 do
    lo = x &&& 0xFFFF
    hi = x >>> 16
    if lo < hi, do: (lo ^^^ hi) <<< 4, else: lo - hi
  end

  # negative constants, unary minus, signed result
  defhls neg(x :: s16) :: s16 do
    y = -x * 5 - 1000
    if y >= -3, do: y, else: 3 - y
  end

  # nested if, and/or, |||
  defhls clampish(x :: u32) :: u32 do
    b0 = x &&& 0xFF
    b1 = (x >>> 8) &&& 0xFF
    if b0 > 200 and b1 < 50 do
      0xFF
    else
      if b0 == b1 or not (b0 < 10), do: b0 ||| (b1 <<< 8), else: 0
    end
  end

  # byte-size types, wrap-around of the result
  defhls wrap8(x :: u8) :: s8 do
    x * 3 + 100
  end

  # arithmetic shift of a negative value, s32 arithmetic
  defhls sar(x :: s32) :: s32 do
    (x >>> 3) - (x <<< 1)
  end
end
