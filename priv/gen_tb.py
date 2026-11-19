#!/usr/bin/env python3
"""Generate an iverilog testbench for a CIRCT `hlstool --dynamic-hw` module.
(From the rust-llvm-circt experiment, mir2mlir/testfuncs/gen_tb.py.)

Usage: gen_tb.py <func.mlir> <func.sv> <vectors> <top> <out_tb.sv>

Parameters come from the MLIR signature, in order:
  scalar iW          -> port in<k> (+_valid/_ready)
  memref<NxiW>       -> external memory: in<k>_ld<j>_addr/_data and in<k>_st<j> {address,data}
                        + in<k>_st<j>_done, discovered from the generated SV ports
then in<n> is the start token; outputs are out0 = result (if any) and a done token.

Vector line: <scalar hex | N memory words>... per param, then <expected result> (if any),
then N expected final words for every memref param.
One invocation at a time; memories are reloaded for every vector.
"""
import re
import sys

mlir_path, sv_path, vec, top, out = sys.argv[1:6]
sig = re.search(r"func\.func @\w+\(([^)]*)\)\s*(?:->\s*i(\d+))?\s*\{", open(mlir_path).read())
params = []
for p in re.findall(r"%\w+:\s*(memref<\d+xi\d+>|i\d+)", sig.group(1)):
    m = re.match(r"memref<(\d+)xi(\d+)>", p)
    params.append(("mem", int(m.group(1)), int(m.group(2))) if m else ("int", 0, int(p[1:])))
rw = int(sig.group(2)) if sig.group(2) else None
n = len(params)

sv = open(sv_path).read()
top_ports = re.search(rf"module {top}\((.*?)\);", sv, re.S).group(1)
def port_width(name):
    m = re.search(rf"\[(\d+):0\]\s+{name}\b", top_ports)
    return int(m.group(1)) + 1 if m else 1
def store_addr_width(name):
    # output struct packed {logic [A:0] address; logic [D:0] data; } <name>
    m = re.search(rf"struct packed \{{logic \[(\d+):0\] address; logic \[\d+:0\] data; \}}\s*{name}\b", top_ports)
    return int(m.group(1)) + 1
def ports(k, kind):
    return sorted(set(int(j) for j in re.findall(rf"\bin{k}_{kind}(\d+)", top_ports)))

L = []  # testbench lines
w = L.append
w("`timescale 1ns/1ps")
w("module tb;")
w("  logic clock = 0, reset = 1;")
w("  always #5 clock = ~clock;")
conns = []
for k, (kind, N, W) in enumerate(params):
    if kind == "int":
        w(f"  logic [{W-1}:0] in{k}, v{k}; logic in{k}_valid = 0; wire in{k}_ready;")
        conns += [f".in{k}(in{k})", f".in{k}_valid(in{k}_valid)", f".in{k}_ready(in{k}_ready)"]
        continue
    w(f"  logic [{W-1}:0] mem{k} [0:{N-1}]; logic [{W-1}:0] exp{k} [0:{N-1}];")
    for j in ports(k, "ld"):
        aw = port_width(f"in{k}_ld{j}_addr")
        p = f"in{k}_ld{j}"
        w(f"  wire [{aw-1}:0] {p}_addr; wire {p}_addr_valid; wire {p}_data_ready;")
        w(f"  logic [{aw-1}:0] {p}_q [0:63]; integer {p}_head = 0, {p}_tail = 0;")
        w(f"  wire {p}_data_valid = {p}_head != {p}_tail; wire [{W-1}:0] {p}_data = mem{k}[{p}_q[{p}_head % 64]];")
        # addresses are queued and answered in order, one per cycle
        w(f"  always @(posedge clock) begin")
        w(f"    if ({p}_addr_valid) begin {p}_q[{p}_tail % 64] <= {p}_addr; {p}_tail <= {p}_tail + 1; end")
        w(f"    if ({p}_data_valid && {p}_data_ready) {p}_head <= {p}_head + 1;")
        w(f"  end")
        conns += [f".{p}_addr({p}_addr)", f".{p}_addr_valid({p}_addr_valid)", f".{p}_addr_ready(1'b1)",
                  f".{p}_data({p}_data)", f".{p}_data_valid({p}_data_valid)", f".{p}_data_ready({p}_data_ready)"]
    for j in ports(k, "st"):
        aw = store_addr_width(f"in{k}_st{j}")
        p = f"in{k}_st{j}"
        w(f"  wire [{aw+W-1}:0] {p}; wire {p}_valid, {p}_done_ready; integer {p}_pending = 0;")
        w(f"  wire {p}_done_valid = {p}_pending > 0;")
        # packed struct {address; data}: address is the MSB part
        w(f"  always @(posedge clock) begin")
        w(f"    if ({p}_valid) mem{k}[{p}[{aw+W-1}:{W}]] <= {p}[{W-1}:0];")
        w(f"    {p}_pending <= {p}_pending + ({p}_valid ? 1 : 0) - ({p}_done_valid && {p}_done_ready ? 1 : 0);")
        w(f"  end")
        conns += [f".{p}({p})", f".{p}_valid({p}_valid)", f".{p}_ready(1'b1)",
                  f".{p}_done_valid({p}_done_valid)", f".{p}_done_ready({p}_done_ready)"]
w(f"  logic in{n}_valid = 0; wire in{n}_ready;")
conns += [f".in{n}_valid(in{n}_valid)", f".in{n}_ready(in{n}_ready)"]
if rw:
    w(f"  wire [{rw-1}:0] out0; wire out0_valid, out1_valid; logic [{rw-1}:0] exp;")
    conns += [".out0(out0)", ".out0_valid(out0_valid)", ".out0_ready(1'b1)", ".out1_valid(out1_valid)", ".out1_ready(1'b1)"]
    done_tok = "out1_valid"
else:
    w("  wire out0_valid;")
    conns += [".out0_valid(out0_valid)", ".out0_ready(1'b1)"]
    done_tok = "out0_valid"
w("  integer fd, cnt = 0, errors = 0, lat, lat_min = 1 << 30, lat_max = 0, i, bad;")
w("  logic [63:0] tok;")
w("  bit got_res, got_done;")
scal = [k for k, p in enumerate(params) if p[0] == "int"]
w("  bit " + ", ".join(f"acc{k}" for k in scal + [n]) + ";")
w(f"  {top} dut(.clock(clock), .reset(reset),\n    " + ",\n    ".join(conns) + ");")

rd = lambda dst: f"if ($fscanf(fd, \"%h\", tok) != 1) $finish; {dst} = tok;"
w("  initial begin")
w(f"    fd = $fopen(\"{vec}\", \"r\");")
w("    repeat (4) @(negedge clock);")
w("    reset = 0;")
w("    while ($fscanf(fd, \"%h\", tok) == 1) begin")
first = True
for k, (kind, N, W) in enumerate(params):
    if kind == "int":
        w(f"      v{k} = tok;" if first else f"      {rd(f'v{k}')}")
    else:
        if first:
            w(f"      mem{k}[0] = tok; for (i = 1; i < {N}; i++) begin {rd(f'mem{k}[i]')} end")
        else:
            w(f"      for (i = 0; i < {N}; i++) begin {rd(f'mem{k}[i]')} end")
    first = False
if rw:
    w(f"      {rd('exp')}")
for k, (kind, N, W) in enumerate(params):
    if kind == "mem":
        w(f"      for (i = 0; i < {N}; i++) begin {rd(f'exp{k}[i]')} end")
w("      @(negedge clock);")
for k in scal:
    w(f"      in{k} = v{k}; in{k}_valid = 1; acc{k} = 0;")
w(f"      in{n}_valid = 1; acc{n} = 0; got_res = {0 if rw else 1}; got_done = 0; lat = 0;")
w("      while (!(got_res && got_done)) begin")
w("        @(posedge clock);")
w("        lat = lat + 1;")
for k in scal + [n]:
    w(f"        if (in{k}_valid && in{k}_ready) acc{k} = 1;")
if rw:
    w("        if (out0_valid) begin")
    w("          got_res = 1;")
    w("          if (out0 !== exp) begin errors = errors + 1; if (errors <= 5) $display(\"MISMATCH #%0d result got=%h exp=%h\", cnt, out0, exp); end")
    w("        end")
w(f"        if ({done_tok}) got_done = 1;")
w("        #1;")
for k in scal + [n]:
    w(f"        if (acc{k}) in{k}_valid = 0;")
w("        if (lat > 200000) begin $display(\"TIMEOUT at vector %0d\", cnt); $finish; end")
w("      end")
w("      repeat (2) @(posedge clock);  // let trailing store handshakes settle")
for k, (kind, N, W) in enumerate(params):
    if kind == "mem":
        w(f"      bad = 0; for (i = 0; i < {N}; i++) if (mem{k}[i] !== exp{k}[i]) bad = bad + 1;")
        w(f"      if (bad) begin errors = errors + 1; if (errors <= 5) $display(\"MISMATCH #%0d memory in{k}: %0d words differ\", cnt, bad); end")
w("      if (lat < lat_min) lat_min = lat;")
w("      if (lat > lat_max) lat_max = lat;")
w("      cnt = cnt + 1;")
w("    end")
w(f"    $display(\"RESULT {top}: vectors=%0d errors=%0d latency=%0d..%0d\", cnt, errors, lat_min, lat_max);")
w("    $finish;")
w("  end")
w("endmodule")
open(out, "w").write("\n".join(L) + "\n")
