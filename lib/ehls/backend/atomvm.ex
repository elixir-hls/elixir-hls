defmodule EHLS.Runtime.AtomVM do
  @moduledoc """
  The AtomVM runtime backend (`priv/backend/atomvm`): the generated functions call the
  `:hwstream` NIFs, which drive the LiteX backend's CSRs and DMA.

  `generate/1` writes `<out>/gen/hw_kernels.erl` (kernel / pipeline / param / state
  indices). A target builds into AtomVM and the application:

    * `src/hwstream_nif.c` (the NIFs; needs `hwstream_csr.h`) and `src/hwstream_pack.c` (a
      list of elements to the packed format of a CPU end and back; no hardware),
    * `gen_csr_header.py <csr.json> <out dir> [package root]...` (that header from the SoC's
      csr.json, and the headers the block packages' csr_headers.json ask for),
    * `lib/hwstream.erl` (the NIF stubs) and `lib/hls_check.ex` (`EHLS.Check`: a kernel on
      the FPGA against the CPU, on the board).

  With `mix ehls.compile --target cpu` (`generate_nif/1`) the `defhls` functions run on the CPU as C
  instead of Elixir: `gen/ehls_nif_kernels.c` and `gen/hw_nif.erl` with `src/ehls_nif.c`
  (`hwnif:info/1`, `init/1`, `run/4`; `src/ehls_nif.h`), `lib/hwnif.erl` and `lib/nif_run.ex`
  (`EHLS.NIFRun`, which cuts a long input into chunks so that the VM is not held).

  The generated CPU code stays within what AtomVM runs (immediate terms, no
  `Enum.map_reduce/3`).
  """
  @behaviour EHLS.Runtime

  @impl true
  def name, do: :atomvm

  @impl true
  def module, do: :hwstream

  @impl true
  def socs, do: [:litex]

  @impl true
  def generate(out) do
    script = Path.join(EHLS.Backend.priv("atomvm"), "gen_hw_kernels.py")
    File.mkdir_p!(Path.join(out, "gen"))

    case System.cmd(
           "python3",
           [script, Path.join(out, "hw"), Path.join([out, "gen", "hw_kernels.erl"])],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {msg, _} -> raise "gen_hw_kernels.py: #{msg}"
    end
  end

  @doc """
  For `mix ehls.compile --target cpu`: `<out>/gen/ehls_nif_kernels.c` (the kernels' C and their table,
  `ehls_nif.h`) and `<out>/gen/hw_nif.erl` (their numbers and layouts). A target builds
  `src/ehls_nif.c` with them and `lib/hwnif.erl` and `lib/nif_run.ex` (`EHLS.NIFRun`)
  into AtomVM and the application.
  """
  @impl true
  def generate_nif(out) do
    {c, erl} = EHLS.NIF.registry(Path.join(out, "cpu"))
    File.mkdir_p!(Path.join(out, "gen"))
    File.write!(Path.join([out, "gen", "ehls_nif_kernels.c"]), c)
    File.write!(Path.join([out, "gen", "hw_nif.erl"]), erl)
    :ok
  end
end
