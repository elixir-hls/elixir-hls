#!/usr/bin/env bash
# The CIRCT flow of `mix ehls.compile` (lib/mix/tasks/ehls.compile.ex sets the environment):
# compile the Elixir files (EHLS_OUT_DIR: defhls / definstance write MLIR and JSON), then each
# kernel
#   <kernel>.mlir --(mlir-opt canonicalize/cse, sink_constants.py, CIRCT hlstool --dynamic-hw
#   to handshake, pipeline_buffers.py, hlstool to SystemVerilog, prefix_modules.py)-->
#   <kernel>.sv (+ <kernel>_space.v for tables / memories, gen_space.py)
#   --(iverilog)--> compared with the same function run by Elixir (N vectors)
# and the description (gen_manifest.py): kernels.json, pipelines.json, peripherals.json,
# packages.json in $OUT/hw.
# Environment: EHLS_EBIN (elixir_hls' beams and the project's, ':'-separated), EHLS_PRIV (this directory), OUT, CIRCT_BIN, N,
# PIPE_BUDGET and DELAY_MODEL (the device backend's, JSON); arguments: the Elixir files (the first ones may be "--with" files: compiled
# too, e.g. block package modules, but their defhls functions as well).
set -euo pipefail
shopt -s nullglob
: "${EHLS_EBIN:?}" "${EHLS_PRIV:?}" "${OUT:?}" "${CIRCT_BIN:?}"
[ $# -gt 0 ] || { echo "usage: mix ehls.compile [--out DIR] [--with FILE]... FILE.ex..."; exit 1; }
SRCS=()
for f in "$@"; do SRCS+=("$(realpath "$f")"); done
HW="$OUT/hw"
PA=()
IFS=: read -r -a _ebins <<< "$EHLS_EBIN"
for d in "${_ebins[@]}"; do PA+=(-pa "$d"); done
HOSTC="$OUT/hostc"
rm -rf "$HW" "$HOSTC" && mkdir -p "$HW" "$HOSTC"
EHLS_OUT_DIR="$HW" elixirc "${PA[@]}" -o "$HOSTC" "${SRCS[@]}" > "$HW/elixirc.log" 2>&1 \
    || { cat "$HW/elixirc.log"; exit 1; }

for SIG in "$HW"/*.sig; do
    # module function kernel arg ret ns emit init (state words, comma separated hex)
    # (pure: a function with tables, in hardware a step function with a dummy state word)
    # (args: the level arguments' values, as the CPU passes them and the testbench ties them)
    read -r MOD FUN K ARG RET NS EMIT INIT PURE PARAMS NI LANE < <(python3 -c '
import json, sys
s = json.load(open(sys.argv[1]))
t = lambda v: "{" + ",".join(map(t, v)) + "}" if isinstance(v, list) else v
print(s["module"], s["function"], s["kernel"], t(s["arg"]), t(s["ret"]), len(s["state"]),
      int(s.get("emit", False)), ",".join("%08x" % w for w in s["init"]) or "-", int(s.get("pure", False)),
      ",".join(str(p["default"]) for p in s.get("args", [])) or "-", s.get("in_words", 1), s.get("lane", 32))' "$SIG")
    [ "$INIT" = - ] && INIT=""
    "$CIRCT_BIN/mlir-opt" "$HW/$K.mlir" --canonicalize --cse -o "$HW/$K.opt.mlir"
    # constants back into the blocks using them (hoisted ones would go round every loop)
    python3 "$EHLS_PRIV/sink_constants.py" "$HW/$K.opt.mlir" "$HW/$K.opt.mlir" 2> /dev/null
    # handshake IR with the minimal buffers, then buffers where combinational paths get long
    # (pipeline_buffers.py: the device's delay model, budget PIPE_BUDGET ns), then SystemVerilog
    "$CIRCT_BIN/hlstool" "$HW/$K.opt.mlir" --dynamic-hw --buffering-strategy=cycles \
        --output-level=post-compile --ir -o "$HW/$K.hs.mlir"
    python3 "$EHLS_PRIV/pipeline_buffers.py" "$HW/$K.hs.mlir" "$HW/$K.hsb.mlir" "${PIPE_BUDGET:-12}"
    "$CIRCT_BIN/hlstool" "$HW/$K.hsb.mlir" --dynamic-hw --input-level=post-compile --buffering-strategy=cycles --verilog \
        --lowering-options=disallowLocalVariables,disallowPackedStructAssignments -o "$HW/$K.sv"
    python3 "$EHLS_PRIV/prefix_modules.py" "$HW/$K.sv" "$K"     # unique helper module names
    # tables / memories: the kernel's memory space module, its port counts into the .sig
    python3 - "$SIG" "$HW/$K.sv" "$EHLS_PRIV/gen_space.py" <<'PY'
import json, subprocess, sys
sig_path, sv, gen = sys.argv[1:4]
sig = json.load(open(sig_path))
if sig.get("space"):
    out = sv[:-3] + "_space.v"
    k, nld, nst = map(int, subprocess.check_output(["python3", gen, sig_path, sv, out]).split())
    sig["space"].update(arg=k, nld=nld, nst=nst, module=sig["kernel"] + "_space", file=out)
    json.dump(sig, open(sig_path, "w"))
PY

    # vectors: edge values + random inputs as wide as the kernel's ports (LANE), expected results from the Elixir function;
    # stateful kernels: a stream from the initial state, restarted halfway ("R")
    elixir "${PA[@]}" -pa "$HOSTC" -e '
      import Bitwise
      [mod, fun, n, ns, pure, params, ni, lane] = System.argv()
      ni = String.to_integer(ni)
      lane = String.to_integer(lane)
      mask = (1 <<< lane) - 1
      hex = fn v -> String.pad_leading(Integer.to_string(v &&& mask, 16), div(lane, 4), "0") end
      ps = if params == "-", do: [], else: params |> String.split(",") |> Enum.map(&String.to_integer/1)
      phex = Enum.map_join(ps, "", &:io_lib.format("~8.16.0b ", [&1 &&& 0xFFFFFFFF]))
      mod = Module.concat([mod]); fun = String.to_atom(fun)
      :rand.seed(:exsss, {1, 2, 3})
      edge = [0, 1, 0x7FFF, 0x8000, 0xFFFF, 0x10000, 0x7FFFFFFF, 0x80000000, 0xFFFFFFFF, 0x80008000, 0x7FFF7FFF] ++
        if(lane > 32, do: [0x100000000, 0x7FFFFFFFFFFF, 0x800000000000, 0xFFFFFFFFFFFF, 0x7FFFFFFFFFFFFFFF, 0x8000000000000000, mask], else: [])
      rnd = fn -> :rand.uniform(1 <<< lane) - 1 end
      n = String.to_integer(n)
      # a tuple: each of its values gets the edge values in turn, the others random (written joined by ",")
      xs =
        if ni == 1 do
          edge ++ for(_ <- 1..n, do: rnd.())
        else
          at = for p <- 0..(ni - 1), e <- edge, do: List.to_tuple(for(i <- 0..(ni - 1), do: if(i == p, do: e, else: rnd.())))
          at ++ for(_ <- 1..n, do: List.to_tuple(for(_ <- 1..ni, do: rnd.())))
        end
      words = fn
        v when is_tuple(v) -> v |> Tuple.to_list() |> Enum.map_join(",", hex)
        v -> hex.(v)
      end
      # an output that may be missing: a list of at most one
      line = fn
        x, [] -> IO.puts([words.(x), " -"])
        x, [y] -> IO.puts([words.(x), " ", words.(y)])
        x, y -> IO.puts([words.(x), " ", words.(y)])
      end
      line0 = fn x, y -> IO.puts([hex.(x), " ", phex, hex.(y)]) end
      cond do
       ns == "0" ->
        for x <- xs, do: line0.(x, apply(mod, fun, [x | ps]))
       pure == "1" ->
        IO.puts("R")
        for x <- xs, do: line.(x, apply(mod, fun, [x | ps]))
       true ->
        {a, b} = Enum.split(xs, div(length(xs), 2))
        for part <- [a, b] do
          IO.puts("R")
          st = Enum.reduce(part, apply(mod, fun, [:zero]), fn x, st ->
            {y, st} = apply(mod, fun, [x, st | ps])
            line.(x, y)
            st
          end)
          # a state with memories: what they hold now, read through the memory space (gen_stream_tb.py)
          mems = :"__hw_mems_#{fun}__"
          if function_exported?(mod, mems, 1) do
            for {m, t} <- apply(mod, mems, [st]),
                do: IO.puts(["M #{m} ", t |> Tuple.to_list() |> Enum.map_join(",", &Integer.to_string(&1 &&& 0xFFFFFFFF, 16))])
          end
        end
      end
    ' "$MOD" "$FUN" "${N:-2000}" "$NS" "$PURE" "$PARAMS" "$NI" "$LANE" > "$HW/$K.vec"
    if [ "$NS" = 0 ]; then
        python3 "$EHLS_PRIV/gen_tb.py" "$HW/$K.opt.mlir" "$HW/$K.sv" "$HW/$K.vec" "$K" "$HW/tb_$K.sv"
        iverilog -g2012 -o "$HW/sim_$K" "$HW/tb_$K.sv" "$HW/$K.sv"
    else
        python3 "$EHLS_PRIV/gen_stream_tb.py" "$K" "$NS" "$INIT" "$HW/$K.vec" "$HW/tb_$K.sv" "$EMIT" "$SIG"
        iverilog -g2012 -o "$HW/sim_$K" "$HW/tb_$K.sv" "$HW/$K.sv" $(ls "$HW/${K}_space.v" 2>/dev/null) \
            "$EHLS_PRIV/verilog/hls_state_adapter.v"
    fi
    RES=$(vvp -n "$HW/sim_$K" | grep -E "^(RESULT|MISMATCH|TIMEOUT)" | head -3)
    echo "$RES   $MOD.$FUN ($ARG -> $([ "$EMIT" = 1 ] && echo "emit ")$RET, $NS state words)"
    case "$RES" in *"errors=0"*) ;; *) echo "simulation failed: $K"; exit 1 ;; esac
done

python3 "$EHLS_PRIV/gen_manifest.py" "$HW"
