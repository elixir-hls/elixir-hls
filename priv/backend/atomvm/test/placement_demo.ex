# Instances placed on the CPU, run in AtomVM by host_placement.sh (ehls_placement_test.erl calls them).
defmodule PlacementDemo do
  use EHLS

  defhls inc(x :: u8) :: u8 do
    x + 1
  end

  defhls double(x :: u8) :: u16 do
    x * 2
  end

  defhls running(x :: u16, acc :: u32) :: {u32, u32} do
    {acc + x, acc + x}
  end

  defhls mix(a :: s16, b :: s16) :: s17 do
    a + b
  end

  defhls half(x :: s17) :: s16 do
    x >>> 1
  end

  defhls smooth(x :: s16, y :: s16) :: {s16, s16} do
    {(x + y) >>> 1, x}
  end

  defhls low8(x :: s16) :: u8 do
    x &&& 0xFF
  end

  defhls id(x :: u32) :: u32 do
    x
  end

  defhls count(_x :: u32, n :: u32) :: {u32, u32} do
    {n + 1, n + 1}
  end

  defhls scale(x :: u8, k :: u8) :: u16 do
    x * k
  end

  defhls avg(w :: tuple(u8, 2)) :: u9 do
    elem(w, 0) + elem(w, 1)
  end

  # a negative initial state and a signed level: as C, a word may come sign-extended (the step sees the type's bits)
  defhls first_neg(x :: s16, s :: s16) :: {s16, s16} do
    {if(s == -1, do: x, else: 0), x}
  end

  defhls offset(x :: s16, k :: s8) :: s16 do
    if k == -3, do: x - 100, else: x + 100
  end

  definstance negs(x) do
    x |> transform(-1, &first_neg/2)
  end

  definstance offs(x) do
    x |> map(&offset(&1, -3))
  end

  # a generated kernel: the last two elements, every second one
  definstance pairs(x) do
    x |> chunk_every(2, 2, :discard) |> map(&avg/1)
  end

  definstance summing(x) do
    x |> map(&inc/1) |> map(&double/1) |> transform(0, &running/2, name: :sum)
  end

  definstance mixer(left, right) do
    zip_with(left, right, &mix/2) |> map(&half/1)
  end

  definstance tapped(x) do
    y = x |> transform(0, &smooth/2)
    y |> map(&low8/1) |> hold(:last)
    y |> map(&half/1)
  end

  definstance counts, buffer: 16 do
    ticks(1000) |> map(&id/1)
  end

  definstance presses do
    ticks(1000) |> transform(0, &count/2) |> hold(:n)
  end

  definstance gain(k :: u8), initial: 3 do
    k
  end

  definstance scaled(x) do
    x |> map(&scale(&1, gain(:value)))
  end
end
