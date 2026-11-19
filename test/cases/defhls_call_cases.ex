defmodule DefhlsCallCases do
  @moduledoc "defhls functions calling others; checked by `mix ehls.compile test/cases/...` in simulation against the CPU."
  use EHLS

  # saturation, the usual reason to have a function
  defhls sat8(x :: s18) :: s8 do
    if x > 127, do: 127, else: if(x < -128, do: -128, else: x)
  end

  defhls mix2(a :: s8, b :: s8, k :: u4) :: s18 do
    a * k + b
  end

  # a call with its arguments and result wrapped, used twice: its names do not meet
  defhls twice(x :: u32) :: u32 do
    a = sat8(signed(x, 18))
    b = sat8(signed(x >>> 14, 18))
    unsigned(mix2(a, b, 3), 18) ||| unsigned(mix2(b, a, 5), 14) <<< 18
  end

  # tuples in and out
  defhls swap(p :: {u16, u16}) :: {u16, u16} do
    {a, b} = p
    {b, a}
  end

  defhls swapped(x :: u32) :: u32 do
    {l, h} = swap({x &&& 0xFFFF, x >>> 16})
    l ||| h <<< 16
  end

  # a table in the callee; a callee calling a callee
  @t [3, 1, 4, 1, 5, 9, 2, 6]
  defhls look(i :: u3) :: u8 do
    Enum.at(@t, i)
  end

  defhls look2(i :: u3, j :: u3) :: u8 do
    look(i) + look(j)
  end

  defhls tabled(x :: u32) :: u32 do
    look2(x, x >>> 3)
  end

  # a loop in the callee, called inside an if
  defhls sum4(x :: u32) :: u18 do
    for k <- 0..3, reduce: 0 do
      acc -> acc + (x >>> (k * 8) &&& 0xFF)
    end
  end

  defhls loop_in_if(x :: u32) :: u32 do
    if (x &&& 1) == 1, do: sum4(x), else: x >>> 4
  end

  # unrolled: k stays a constant through the call, so the shift by it is wiring
  defhls bit(x :: u32, k :: u5) :: u1 do
    x >>> k
  end

  defhls popcount(x :: u32) :: u32 do
    Enum.reduce(0..31, 0, fn k, acc -> acc + bit(x, k) end)
  end
end
