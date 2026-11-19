defmodule InstanceCases do
  @moduledoc "Instances for `mix ehls.sim`: what happens between the stages and at their start."
  use EHLS

  @taps [3, -1, 4, 1, -5, 9, 2, 6]

  defhls low16(x :: s32) :: s16 do
    x
  end

  defhls low8(x :: u32) :: s8 do
    x
  end

  defhls count(_x :: u32, n :: u16) :: {u16, u16} do
    {n, n + 1}
  end

  # what came in and the state both go on: no stage's initial value is lost in the next
  defhls plus(x :: u16, n :: u16) :: {u16, u16} do
    {x + n, n + 1}
  end

  defhls add(x :: s16, s :: s32) :: {s32, s32} do
    {s + x, s + x}
  end

  defhls scale(x :: s32, k :: u8) :: s32 do
    x * k
  end

  defhls pair(x :: s16, st :: {s16, u8}) :: {{s16, u8}, {s16, u8}} do
    {last, n} = st
    {{last, n}, {x, n + 1}}
  end

  defhls sum2(p :: {s16, u8}) :: s32 do
    {a, b} = p
    a + b
  end

  defhls every_other(x :: s32, on :: u1) :: {[s32], u1} do
    if on == 1, do: {[x], 0}, else: {[], 1}
  end

  defhls fir(w :: tuple(s16, 8)) :: s32 do
    Enum.sum(for k <- 0..7, do: elem(w, k) * Enum.at(@taps, k))
  end

  # the same function with two initial values
  definstance from_seven(x) do
    x |> transform(7, &plus/2) |> transform(100, &plus/2)
  end

  # a negative s8 widened by the link, then a negative initial state
  definstance signs(x) do
    x |> map(&low8/1) |> transform(-1000, &add/2) |> map(&scale(&1, 3))
  end

  # a frame of two words from a state, taken by a function, a rate of 1/2
  definstance frames(x) do
    x |> transform({-5, 200}, &pair/2) |> map(&sum2/1) |> transform(1, &every_other/2)
  end

  # chunks with a rate, with stages on both sides
  definstance windowed(x) do
    x |> map(&low8/1) |> chunk_every(8, 4, :discard) |> map(&fir/1) |> map(&low16/1) |> transform(0, &add/2)
  end

  # chunks apart: the elements between them left out
  definstance gapped(x) do
    x |> map(&low8/1) |> chunk_every(8, 12, :discard) |> map(&fir/1) |> map(&low16/1)
  end

  # a chain with a name, used twice: its stages expanded, a state each
  defhls smooth(x :: stream(u32)) :: stream(u32) do
    x |> map(&low8/1) |> transform(-1000, &add/2) |> map(&scale(&1, 3)) |> map(&wrap_u32/1)
  end

  defhls wrap_u32(x :: s32) :: u32 do
    x
  end

  definstance chained(x) do
    x |> smooth() |> smooth()
  end

  defhls widen(x :: u32) :: u48 do
    x * 0x10001
  end

  defhls fold(v :: u48) :: u16 do
    v >>> 32 ^^^ (v &&& 0xFFFF)
  end

  defhls acc48(x :: u48, s :: u32) :: {u48, u32} do
    {x + s, s + 3}
  end

  # a value over 32 bits between stages: a 32-bit kernel, two of 64-bit ports, back to 32
  definstance wide_links(x) do
    x |> map(&widen/1) |> transform(5, &acc48/2) |> map(&fold/1)
  end

  # instances of levels: a loop of several clocks, so calls come while it computes; two arguments;
  # values over 32 bits in a tuple
  defhls sum4(x :: u32) :: u18 do
    for k <- 0..3, reduce: 0 do
      acc -> acc + (x >>> (k * 8) &&& 0xFF)
    end
  end

  defhls mix2(a :: s16, b :: s16) :: s17 do
    a + b
  end

  definstance sum_hw(x :: u32), initial: 7 do
    sum4(x)
  end

  definstance mix_hw(a :: s16, b :: s16), initial: -1 do
    mix2(a, b)
  end

  definstance wide_hw(a :: u8, b :: s40), initial: {1, -1} do
    {b, a}
  end

  # a level wired into a function placed in the stream: checked at its initial: value (7)
  defhls times(x :: s32, k :: u18) :: s32 do
    x * k
  end

  definstance wired(x) do
    x |> map(&times(&1, sum_hw(:value))) |> map(&times(&1, -1))
  end

  # a function with a state and a level: an integer, then an instance of levels (checked at its initial: -7)
  defhls addk(x :: s16, s :: s32, k :: s8) :: {s32, s32} do
    {s + x + k, s + x}
  end

  definstance k8_hw(v :: s8), initial: -7 do
    v
  end

  definstance stepped(x) do
    x |> map(&low16/1) |> transform(0, &addk(&1, &2, -3)) |> map(&low16/1) |> transform(5, &addk(&1, &2, k8_hw(:value)))
  end

  # two streams into one function: the pipes into the join and out of it are pieces of their own
  definstance joined(left, right) do
    zip_with(left |> map(&low8/1), right |> map(&low16/1), &mix2/2) |> map(&wrap_s32/1)
  end

  defhls wrap_s32(x :: s17) :: s32 do
    x
  end

  # between blocks, the piece in the middle
  definstance between do
    ticks(10) |> transform(3, &count/2, name: :n) |> map(&low8/1) |> run()
  end
end
