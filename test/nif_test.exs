defmodule EHLS.NIFTest do
  use ExUnit.Case

  # --target cpu: every case of test/cases as C, built with the host's C compiler and compared with Elixir
  @moduletag :nif
  @moduletag timeout: 300_000

  setup_all do
    if System.find_executable("gcc") || System.find_executable("cc"), do: :ok, else: {:skip, "no C compiler"}
  end

  @tag :tmp_dir
  test "every defhls case, as C, gives what the Elixir function gives", %{tmp_dir: dir} do
    files = Path.wildcard(Path.join(__DIR__, "cases/defhls_*.ex"))
    assert files != []

    out =
      ExUnit.CaptureIO.capture_io(fn ->
        Mix.Tasks.Ehls.Compile.run(["--target", "cpu", "--out", dir, "--vectors", "300" | files])
      end)

    results = Regex.scan(~r/^RESULT (\S+): vectors=(\d+) errors=(\d+)/m, out)
    assert length(results) > 20
    assert Enum.all?(results, fn [_, _, _, e] -> e == "0" end), out
  end

  test "the C of a kernel: the step, the packed batch function" do
    mlir = """
    module {
      func.func @k(%arg0: i32) -> (i32) {
        %v0 = arith.constant 3 : i32
        %v1 = arith.addi %arg0, %v0 : i32
        return %v1 : i32
      }
    }
    """

    sig = %{"kernel" => "k", "arg" => "u16", "ret" => "u32", "state" => [], "init" => [], "args" => [], "emit" => false, "space" => nil}
    c = EHLS.NIF.c_source(mlir, sig)
    assert c =~ "k_step(uint64_t arg0, uint64_t *r)"
    assert c =~ "size_t k_run(k_t *st, const uint8_t *in, size_t n, uint8_t *out, const uint64_t *lv)"
    assert c =~ "#define K_IN_BYTES 2"
    assert c =~ "#define K_OUT_BYTES 4"
  end

  @tag :tmp_dir
  test "the AtomVM runtime backend: a table of the kernels that runs through ehls_nif.h", %{tmp_dir: dir} do
    src = Path.join(dir, "kd.ex")

    File.write!(src, """
    defmodule NifKd do
      use EHLS

      defhls stream_kernel(x :: u32) :: u32 do
        a = signed(x &&& 0xFFFF, 16)
        b = signed(x >>> 16, 16)
        if a > b, do: a * 3 + b, else: a + b * 2
      end

      defhls halve(x :: s16, 1 :: u1) :: {[s16], u1} do
        {[x >>> 1], 0}
      end

      defhls halve(_x :: s16, _n :: u1) :: {[s16], u1} do
        {[], 1}
      end
    end
    """)

    System.put_env("EHLS_RUNTIME", "atomvm")

    try do
      ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Ehls.Compile.run(["--target", "cpu", "--out", dir, "--vectors", "50", src]) end)
    after
      System.delete_env("EHLS_RUNTIME")
    end

    assert File.exists?(Path.join(dir, "gen/hw_nif.erl"))
    erl = File.read!(Path.join(dir, "gen/hw_nif.erl"))
    assert erl =~ "kernel('NifKd.halve') -> 0;"
    assert erl =~ "kernel('NifKd.stream_kernel') -> 1;"
    assert erl =~ "layouts('NifKd.stream_kernel') -> {32, 32};"

    # the table runs on the host: stream_kernel(0x00020001) = 5; halve gives every second input, halved
    main = Path.join(dir, "main.c")

    File.write!(main, """
    #include <stdio.h>
    #include <stdlib.h>
    #include "ehls_nif.h"
    int main(void) {
      if (ehls_nif_count != 2) return 1;
      const struct ehls_nif_kernel *k = &ehls_nif_kernels[1];
      void *st = calloc(1, k->state_bytes);
      k->init(st);
      uint8_t in[4] = {1, 0, 2, 0}, out[4];
      if (k->run(st, in, 1, out, 0) != 4 || out[0] != 5 || out[1] || out[2] || out[3]) return 2;
      k = &ehls_nif_kernels[0];
      if (!k->emit || k->in_bytes != 2 || k->out_bytes != 2) return 3;
      st = calloc(1, k->state_bytes);
      k->init(st);
      uint8_t in2[8] = {4, 0, 8, 0, 12, 0, 16, 0}, out2[8];
      size_t n = k->run(st, in2, 2, out2, 0);          /* two calls: the state is kept */
      n += k->run(st, in2 + 4, 2, out2 + n, 0);
      printf("%zu %d %d\\n", n, out2[0], out2[2]);
      return n == 4 && out2[0] == 4 && out2[2] == 8 ? 0 : 4;
    }
    """)

    exe = Path.join(dir, "main")
    cc = System.find_executable("gcc") || System.find_executable("cc")
    inc = Path.join(EHLS.Backend.priv("atomvm"), "src")
    {log, 0} = System.cmd(cc, ["-Wall", "-I", inc, "-o", exe, main, Path.join(dir, "gen/ehls_nif_kernels.c")], stderr_to_stdout: true)
    refute log =~ "error"
    assert {_, 0} = System.cmd(exe, [])
  end

  @tag :tmp_dir
  test "a file without a defhls function is an error, and --vectors 0 still runs the edge values", %{tmp_dir: dir} do
    empty = Path.join(dir, "empty.ex")
    File.write!(empty, "defmodule NifEmpty do\n  def f, do: 1\nend\n")

    assert_raise Mix.Error, ~r/no defhls function/, fn ->
      ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Ehls.Compile.run(["--target", "cpu", "--out", Path.join(dir, "o1"), empty]) end)
    end

    one = Path.join(dir, "one.ex")
    File.write!(one, "defmodule NifOne do\n  use EHLS\n  defhls inc(x :: u8) :: u8 do\n    x + 1\n  end\nend\n")

    out = ExUnit.CaptureIO.capture_io(fn -> Mix.Tasks.Ehls.Compile.run(["--target", "cpu", "--out", Path.join(dir, "o2"), "--vectors", "0", one]) end)
    assert out =~ "RESULT nif_one_inc: vectors=11 errors=0"
  end
end
