#!/usr/bin/env bash
# Runs the NIF kernels (`mix ehls.compile --target cpu`) as NIFs in a real AtomVM built for the host:
# the NIF (src/ehls_nif.c), the kernel table, EHLS.NIFRun and hwstream:pack/unpack, with the
# Erlang test ehls_nif_test.erl. Not the board: it shows that the NIF builds against AtomVM's headers
# and behaves (state between calls, chunks, the input limit); the Zephyr port is built by the target.
#
# usage: host_atomvm.sh <AtomVM source dir> <work dir>      (needs cmake, ninja, gperf, erlc, elixirc, rebar3, gcc)
# The pinned AtomVM of atomvm-tang25k: scripts/setup_atomvm.sh -> ext/AtomVM.
set -euo pipefail
ATOMVM=$(realpath "${1:?AtomVM source dir}")
W=$(mkdir -p "${2:?work dir}" && realpath "$2")
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PRIV=$(dirname "$HERE")
ROOT=$(cd "$PRIV/../../.." && pwd)
mkdir -p "$W/t"

# the kernels the test calls
cat > "$W/kd.ex" <<'EX'
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
EX
(cd "$ROOT" && EHLS_RUNTIME=atomvm mix ehls.compile --target cpu --out "$W/build" --vectors 200 "$W/kd.ex")

# AtomVM for the host, then its link with the NIF added
[ -d "$W/vm" ] || cmake -G Ninja -S "$ATOMVM" -B "$W/vm" -DAVM_DISABLE_JIT=ON -DAVM_BUILD_DOCS=OFF > /dev/null
ninja -C "$W/vm" AtomVM PackBEAM atomvmlib > /dev/null
FL=$(ninja -C "$W/vm" -t commands src/AtomVM | grep -m1 "libAtomVM/context.c" |
     sed -E 's/^(\/usr\/bin\/)?cc//; s/ -MD -MT [^ ]+ -MF [^ ]+//; s/ -o [^ ]+//; s/ -c [^ ]+$//')
OBJ=()
for c in "$PRIV/src/ehls_nif.c" "$PRIV/src/hwstream_pack.c" "$HERE/host_shim.c"; do
    o="$W/$(basename "$c").o"
    # shellcheck disable=SC2086
    cc $FL -I"$PRIV/src" -I"$W/build/gen" -c "$c" -o "$o"
    OBJ+=("$o")
done
LIBS=("$W/vm/src/platforms/generic_unix/libAtomVM/liblibAtomVM.a" "$W/vm/src/platforms/generic_unix/lib/liblibAtomVMLinux-x86_64.a")
cc -Wl,--export-dynamic -rdynamic -Wl,--wrap=platform_nifs_get_nif "$W/vm/src/platforms/generic_unix/CMakeFiles/AtomVM.dir/main.c.o" \
    "${OBJ[@]}" -o "$W/AtomVM-ehls" "${LIBS[@]}" "${LIBS[@]}" -lm -lz -ldl -lrt 2> /dev/null

# the test's package
(cd "$W/t" && erlc -o . "$HERE/ehls_nif_test.erl" "$W/build/gen/hw_nif.erl" "$PRIV/lib/hwnif.erl" "$PRIV/lib/hwstream.erl" &&
 elixirc --no-docs --ignore-module-conflict -o . "$PRIV/lib/nif_run.ex" "$PRIV/lib/cpu_driver.ex" > /dev/null &&
 "$W/vm/tools/packbeam/packbeam" create ../t.avm ehls_nif_test.beam hw_nif.beam hwnif.beam hwstream.beam Elixir.EHLS.NIFRun.beam Elixir.EHLS.CpuDriver.beam)
EXA=$(find "$W/vm" -name exavmlib.avm | head -1)
"$W/AtomVM-ehls" "$W/t.avm" "$W/vm/libs/atomvmlib.avm" "$EXA" 2>&1 | head -20
