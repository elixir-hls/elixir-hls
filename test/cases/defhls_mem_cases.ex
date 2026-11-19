defmodule DefhlsMemCases do
  @moduledoc "defhls with tuples in the state placed as memories (transform(..., memory: [:hist])), tables and loops; checked by `mix ehls.compile test/cases/defhls_mem_cases.ex` (test/ehls_test.exs)."
  use EHLS

  @taps [1, -2, 3, 4]
  # FIR-like coefficient tables of 32 and 224 taps (a windowed sinc in Q15, symmetric)
  @fir1 for k <- 0..31, do: round(4000 * :math.cos(:math.pi() * (k - 15.5) / 32) * (1 - abs(k - 15.5) / 16))
  @fir2 for k <- 0..223, do: round(1500 * :math.cos(:math.pi() * (k - 111.5) / 224) * (1 - abs(k - 111.5) / 112))
  @taps6 [3, -1, 4, 1, -5, 9]

  # 4-tap FIR: the history a tuple in the state (a memory), the coefficients in a table
  defhls fir4(x :: s16, {pos, hist} :: {u8, tuple(s16, 8)}) :: {s32, {u8, tuple(s16, 8)}} do
    acc =
      for k <- 1..3, reduce: x * Enum.at(@taps, 0) do
        acc -> acc + elem(hist, (pos - k) &&& 7) * Enum.at(@taps, k)
      end

    {acc, {pos + 1, put_elem(hist, pos &&& 7, x)}}
  end

  # 6 taps, every third sample (a loop inside a branch)
  defhls dec3(x :: s16, {pos, cnt, hist} :: {u8, u8, tuple(s16, 16)}) :: {[s32], {u8, u8, tuple(s16, 16)}} do

    out =
      if cnt == 2 do
        acc =
          for k <- 1..5, reduce: x * Enum.at(@taps6, 0) do
            acc -> acc + elem(hist, (pos - k) &&& 15) * Enum.at(@taps6, k)
          end

        {[acc >>> 1], 0}
      else
        {[], cnt + 1}
      end

    {y, cnt2} = out
    {y, {pos + 1, cnt2, put_elem(hist, pos &&& 15, x)}}
  end

  # The FM FIRs written out by hand (ring buffer, counter, loop): what
  # FMRadio.mpx_tap / audio_tap, with a history from zeros (chunk_every waits for a whole chunk instead).
  # d (s16, 960 kS/s) -> MPX x (s18, 240 kS/s): 32-tap FIR, every 4th sample, saturated.
  # The history a tuple in the state, the coefficients in a table, the taps in a loop (time
  # multiplexed); bit-exact with fir_dec.v (TAPS 32, DEC 4, PHASE 3, SH 15, SAT 1).
  defhls mpx_fir(x :: s16, {pos, cnt, hist} :: {u8, u8, tuple(s16, 64)}) :: {[s18], {u8, u8, tuple(s16, 64)}} do

    out =
      if cnt == 3 do
        acc =
          for k <- 1..31, reduce: x * Enum.at(@fir1, 0) do
            acc -> acc + elem(hist, (pos - k) &&& 63) * Enum.at(@fir1, k)
          end

        v = acc >>> 15
        {[if(v > 131_071, do: 131_071, else: if(v < -131_072, do: -131_072, else: v))], 0}
      else
        {[], cnt + 1}
      end

    {y, cnt2} = out
    {y, {pos + 1, cnt2, put_elem(hist, pos &&& 63, x)}}
  end

  # MPX x (s18, 240 kS/s) -> L+R (s22, 48 kHz): 224-tap FIR, every 5th sample (fir_dec.v
  # TAPS 224, DEC 5, PHASE 4, SH 17, SAT 0: the low 22 bits)
  defhls audio_fir(x :: s18, {pos, cnt, hist} :: {u8, u8, tuple(s18, 256)}) :: {[s22], {u8, u8, tuple(s18, 256)}} do

    out =
      if cnt == 4 do
        acc =
          for k <- 1..223, reduce: x * Enum.at(@fir2, 0) do
            acc -> acc + elem(hist, (pos - k) &&& 255) * Enum.at(@fir2, k)
          end

        {[acc >>> 17], 0}
      else
        {[], cnt + 1}
      end

    {y, cnt2} = out
    {y, {pos + 1, cnt2, put_elem(hist, pos &&& 255, x)}}
  end

  # each placed with its history as a memory (block RAM), so that the circuits are those of a memory
  definstance fir4_m(x) do
    x |> transform({0, Tuple.duplicate(0, 8)}, &fir4/2, memory: [:hist])
  end

  # the same function with its history in registers (elem / put_elem with a variable index: selects)
  definstance fir4_r(x) do
    x |> transform({0, Tuple.duplicate(0, 8)}, &fir4/2)
  end

  definstance dec3_m(x) do
    x |> transform({0, 0, Tuple.duplicate(0, 16)}, &dec3/2, memory: [:hist])
  end

  definstance mpx_fir_m(x) do
    x |> transform({0, 0, Tuple.duplicate(0, 64)}, &mpx_fir/2, memory: [:hist])
  end

  definstance audio_fir_m(x) do
    x |> transform({0, 0, Tuple.duplicate(0, 256)}, &audio_fir/2, memory: [:hist])
  end
end
