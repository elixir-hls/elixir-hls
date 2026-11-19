#!/usr/bin/env bash
# Runs instances placed on the CPU (placement_demo.ex, EHLS_PLACEMENT=cpu) in a real AtomVM built for the host, through
# ehls_placement_test.erl: what the generated code needs at run time is EHLS (wrap, run_cpu, pack) and EHLS.CpuInstance.
#
# With --nif the stages run as C (EHLS_CPU=nif): `mix ehls.compile --target cpu` writes their C and the kernel table,
# which are linked into the AtomVM with the NIFs (ehls_nif.c, hwstream_pack.c) and host_shim.c, as host_atomvm.sh
# does. The same test, the same results.
#
# usage: host_placement.sh [--nif] <AtomVM build dir (cmake, generic_unix: src/AtomVM, tools/packbeam, libs)> <work dir>
# (host_atomvm.sh builds one: <its work dir>/vm.) Needs elixirc, erlc; with --nif gcc too.
set -euo pipefail
NIF=0
if [ "${1:-}" = --nif ]; then NIF=1; shift; fi
VM=$(realpath "${1:?AtomVM build dir}")
W=$(mkdir -p "${2:?work dir}" && realpath "$2")
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd "$HERE/../../../.." && pwd)
(cd "$ROOT" && mix compile > /dev/null)
EBIN="$ROOT/_build/dev/lib/elixir_hls/ebin"
rm -rf "$W/p" && mkdir -p "$W/p"
PRIV=$(dirname "$HERE")
EXA=$(find "$VM" -name exavmlib.avm | head -1)

if [ "$NIF" = 0 ]; then
    EHLS_PLACEMENT=cpu elixirc --no-docs -pa "$EBIN" -o "$W/p" "$HERE/placement_demo.ex" > "$W/p/elixirc.log" 2>&1 || { cat "$W/p/elixirc.log"; exit 1; }
    erlc -o "$W/p" "$HERE/ehls_placement_test.erl"
    cp "$EBIN/Elixir.EHLS.beam" "$EBIN/Elixir.EHLS.CpuInstance.beam" "$W/p/"
    (cd "$W/p" && "$VM/tools/packbeam/packbeam" create ../placement.avm ehls_placement_test.beam Elixir.PlacementDemo.beam \
        Elixir.EHLS.beam Elixir.EHLS.CpuInstance.beam)
    "$VM/src/AtomVM" "$W/placement.avm" "$VM/libs/atomvmlib.avm" "$EXA" 2>&1 | tail -25
    exit 0
fi

# the stages' C, checked against Elixir on the host, and the module compiled to call them through the NIF
# (a failing check stops here: mix raises on a kernel that differs, and errors=0 is asked of every one)
(cd "$ROOT" && EHLS_RUNTIME=atomvm EHLS_PLACEMENT=cpu EHLS_CPU=nif mix ehls.compile --target cpu --out "$W/nb" --vectors 200 \
    "$HERE/placement_demo.ex") > "$W/p/check.log" 2>&1 || { grep -E "RESULT|MISMATCH|rror" "$W/p/check.log"; exit 1; }
grep -E "^RESULT" "$W/p/check.log"
if grep -E "^RESULT" "$W/p/check.log" | grep -qv "errors=0 "; then echo "a kernel's C differs from its function"; exit 1; fi
[ -f "$W/nb/gen/ehls_nif_kernels.c" ] || { echo "no kernel table"; exit 1; }

# the AtomVM with the NIFs linked in
FL=$(ninja -C "$VM" -t commands src/AtomVM | grep -m1 "libAtomVM/context.c" |
     sed -E 's/^(\/usr\/bin\/)?cc//; s/ -MD -MT [^ ]+ -MF [^ ]+//; s/ -o [^ ]+//; s/ -c [^ ]+$//')
OBJ=()
for c in "$PRIV/src/ehls_nif.c" "$PRIV/src/hwstream_pack.c" "$HERE/host_shim.c"; do
    o="$W/p/$(basename "$c").o"
    # shellcheck disable=SC2086
    cc $FL -I"$PRIV/src" -I"$W/nb/gen" -c "$c" -o "$o"
    OBJ+=("$o")
done
LIBS=("$VM/src/platforms/generic_unix/libAtomVM/liblibAtomVM.a" "$VM/src/platforms/generic_unix/lib/liblibAtomVMLinux-x86_64.a")
cc -Wl,--export-dynamic -rdynamic -Wl,--wrap=platform_nifs_get_nif "$VM/src/platforms/generic_unix/CMakeFiles/AtomVM.dir/main.c.o" \
    "${OBJ[@]}" -o "$W/p/AtomVM-ehls" "${LIBS[@]}" "${LIBS[@]}" -lm -lz -ldl -lrt 2> /dev/null

(cd "$W/p" && erlc -o . "$HERE/ehls_placement_test.erl" "$W/nb/gen/hw_nif.erl" "$PRIV/lib/hwnif.erl" "$PRIV/lib/hwstream.erl" &&
 elixirc --no-docs --ignore-module-conflict -o . "$PRIV/lib/nif_run.ex" > /dev/null &&
 cp "$W/nb/hostc/Elixir.PlacementDemo.beam" "$EBIN/Elixir.EHLS.beam" "$EBIN/Elixir.EHLS.CpuInstance.beam" . &&
 "$VM/tools/packbeam/packbeam" create ../placement_nif.avm ehls_placement_test.beam Elixir.PlacementDemo.beam \
    Elixir.EHLS.beam Elixir.EHLS.CpuInstance.beam Elixir.EHLS.NIFRun.beam hw_nif.beam hwnif.beam hwstream.beam)
"$W/p/AtomVM-ehls" "$W/placement_nif.avm" "$VM/libs/atomvmlib.avm" "$EXA" 2>&1 | tail -25
