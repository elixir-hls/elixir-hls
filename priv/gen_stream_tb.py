#!/usr/bin/env python3
"""Generate an iverilog testbench for a stateful defhls kernel behind hls_state_adapter.v.

usage: gen_stream_tb.py <top> <ns> <init words, comma separated hex> <vectors> <out_tb.sv> [emit] [sig]
(sig: the kernel's .sig; with a memory space, its module <top>_space is wired to the kernel)

Vectors: one line per stream element "<x hex> <y hex>" ("<x hex> -": no output, an emit
kernel skipping; a tuple element is its values joined by ","), or "R" = restart the
state before the next element (the testbench waits for all earlier outputs first), or
"M <memory> <words hex, joined by ,>": the memory as the state holds it after the elements so
far, read through the memory space's CPU port once their outputs are out. Input and output are stalled at random. Prints
"RESULT <top>: vectors=N errors=E" (or TIMEOUT).
"""
import sys

top, ns, init, vec_path, out = sys.argv[1:6]
emit = int(sys.argv[6]) if len(sys.argv) > 6 else 0
import json
sig = json.load(open(sys.argv[7])) if len(sys.argv) > 7 else {}
space = sig.get("space")
ni, nyw = sig.get("in_words", 1), sig.get("out_words", 1)     # values per input / output element
W = sig.get("lane", 32)                                        # bits per value at the kernel's ports
ns = int(ns)
init = [int(w, 16) for w in init.split(",")] if init else []
assert len(init) == ns

xs, ys, marks, before = [], [], [], []      # before[i]: outputs expected before word i
mchecks = []                                  # (elements before, outputs before, address, word, width)
regions = {r["name"]: r for r in (space or {}).get("regions", [])}
restart_next = False
for line in open(vec_path):
    f = line.split()
    if not f:
        continue
    if f[0] == "R":
        restart_next = True
        continue
    if f[0] == "M":
        r = regions.get(f[1]) or regions[f"hw__m_{f[1]}"]   # a tuple of the state: its memory, hw__m_<name>
        mask = (1 << r["width"]) - 1
        for i, v in enumerate(f[2].split(",")):
            mchecks.append((len(xs), len(ys), r["base"] + i, int(v, 16) & mask, r["width"]))
        continue
    before.append(len(ys))
    xw = [int(v, 16) for v in f[0].split(",")]
    assert len(xw) == ni
    xs.append(sum(v << (W * i) for i, v in enumerate(xw)))
    if f[1] != "-":
        yw = [int(v, 16) for v in f[1].split(",")]
        ys.append(sum(v << (W * i) for i, v in enumerate(yw)))
    marks.append(1 if restart_next else 0)
    restart_next = False
n = len(xs)                    # elements
ny = len(ys)
nin = ni + ns                  # kernel data inputs
no = emit + nyw + ns           # kernel data outputs
init_param = "".join(f"{w:0{W // 4}x}" for w in reversed(init))   # {s_NS, .., s_1}

L = []
L.append("`timescale 1ns/1ps")
L.append("module tb;")
L.append("  reg clk = 0, rst = 1, restart = 0;")
L.append("  always #5 clk = ~clk;")
L.append(f"  reg s_valid = 0; wire s_ready; reg [{ni * W - 1}:0] s_data = 0;")
L.append(f"  wire m_valid; reg m_ready = 0; wire [{nyw * W - 1}:0] m_data;")
L.append(f"  wire [{nin * W - 1}:0] k_in_data;")
L.append(f"  wire [{no * W - 1}:0] k_out_data;")
L.append(f"  wire [{nin}:0] k_in_valid, k_in_ready;")
L.append(f"  wire [{no}:0] k_out_valid, k_out_ready;")
L.append(f"  hls_state_adapter #(.W({W}), .NS({ns}), .INIT({ns * W}'h{init_param}), .EMIT({emit}), .NI({ni}), .NY({nyw})) adapter (")
L.append("    .clk(clk), .rst(rst), .restart(restart),")
L.append("    .s_valid(s_valid), .s_ready(s_ready), .s_data(s_data),")
L.append("    .m_valid(m_valid), .m_ready(m_ready), .m_data(m_data),")
L.append("    .k_in_data(k_in_data), .k_in_valid(k_in_valid), .k_in_ready(k_in_ready),")
L.append("    .k_out_data(k_out_data), .k_out_valid(k_out_valid), .k_out_ready(k_out_ready));")
ports = ["    .clock(clk), .reset(rst)"]
for k in range(nin):
    ports.append(f"    .in{k}(k_in_data[{k * W} +: {W}]), .in{k}_valid(k_in_valid[{k}]), .in{k}_ready(k_in_ready[{k}])")
for k in range(no):
    ports.append(f"    .out{k}(k_out_data[{k * W} +: {W}]), .out{k}_valid(k_out_valid[{k}]), .out{k}_ready(k_out_ready[{k}])")
# the level arguments (tied to their defaults, always valid), then the memory space, then the start token
args = sig.get("args", [])
for j, p in enumerate(args):
    a = nin + j
    ports.append(f"    .in{a}(32'h{p['default'] & 0xFFFFFFFF:08x}), .in{a}_valid(1'b1), .in{a}_ready()")
np_ = len(args)
tok = nin + np_ + (1 if space else 0)
ports.append(f"    .in{tok}_valid(k_in_valid[{nin}]), .in{tok}_ready(k_in_ready[{nin}])")
if space:
    k, aw = space["arg"], space["aw"]
    sp = ["    .clk(clk), .rst(rst), .restart(restart)"]
    for j in range(space["nld"]):
        L.append(f"  wire [{aw-1}:0] ld{j}_addr; wire ld{j}_addr_valid, ld{j}_addr_ready, ld{j}_data_valid, ld{j}_data_ready; wire [31:0] ld{j}_data;")
        for s in ["addr", "addr_valid", "addr_ready", "data", "data_valid", "data_ready"]:
            ports.append(f"    .in{k}_ld{j}_{s}(ld{j}_{s})")
            sp.append(f"    .ld{j}_{s}(ld{j}_{s})")
    for j in range(space["nst"]):
        L.append(f"  wire [{aw+31}:0] st{j}; wire st{j}_valid, st{j}_ready, st{j}_done_valid, st{j}_done_ready;")
        for s in ["", "_valid", "_ready", "_done_valid", "_done_ready"]:
            ports.append(f"    .in{k}_st{j}{s}(st{j}{s})")
            sp.append(f"    .st{j}{s}(st{j}{s})")
    L.append(f"  reg [{aw-1}:0] cpu_addr = 0; reg cpu_req = 0; wire [31:0] cpu_q; wire cpu_done;")
    sp.append("    .cpu_addr(cpu_addr), .cpu_req(cpu_req), .cpu_q(cpu_q), .cpu_done(cpu_done)")
    L.append(f"  {space['module']} space (")
    L.append(",\n".join(sp))
    L.append("  );")
ports.append(f"    .out{no}_valid(k_out_valid[{no}]), .out{no}_ready(k_out_ready[{no}])")
L.append(f"  {top} kernel (")
L.append(",\n".join(ports))
L.append("  );")
L.append(f"  reg [{ni * W - 1}:0] xs [0:{n - 1}]; reg [{nyw * W - 1}:0] ys [0:{max(ny, 1) - 1}]; reg marks [0:{n - 1}];")
L.append(f"  integer n_before [0:{n - 1}];")
L.append("  integer i, mi = 0, errors = 0, t0 = 0;")
L.append("  initial begin")
for i in range(n):
    L.append(f"    xs[{i}] = {ni * W}'h{xs[i]:0{ni * W // 4}x};")
for i in range(n):
    L.append(f"    marks[{i}] = {marks[i]}; n_before[{i}] = {before[i]};")
for i in range(ny):
    L.append(f"    ys[{i}] = {nyw * W}'h{ys[i]:0{nyw * W // 4}x};")
L.append("  end")
# receiver: random back-pressure, in-order compare
L.append("  always @(negedge clk) m_ready <= ($random % 4) != 0;")
L.append("  always @(posedge clk) if (!rst && m_valid && m_ready) begin")
L.append("    if (m_data !== ys[mi]) begin")
L.append("      errors = errors + 1;")
L.append("      if (errors <= 5) $display(\"MISMATCH output %0d: got %h expected %h\", mi, m_data, ys[mi]);")
L.append("    end")
L.append("    mi = mi + 1;")
L.append("  end")
# the memory as the state holds it: each word through the CPU port, once the outputs before are out
def mem_checks(at):
    out = []
    for (xi, yi, addr, word, width) in mchecks:
        if xi == at:
            out += [f"        wait (mi == {yi}); repeat (20) @(negedge clk);",
                    f"        cpu_addr = {addr}; cpu_req = 1; @(negedge clk) cpu_req = 0;",
                    "        while (!cpu_done) @(negedge clk);",
                    f"        if (cpu_q[{width - 1}:0] !== {width}'h{word:x}) begin errors = errors + 1;",
                    f"          if (errors <= 5) $display(\"MISMATCH memory word {addr}: got %h expected {word:x}\", cpu_q); end"]
    return out
checks_at = sorted({c[0] for c in mchecks})
# sender: random gaps, restarts after draining
L.append("  initial begin")
L.append("    repeat (4) @(posedge clk); @(negedge clk) rst = 0; t0 = $time;")
L.append(f"    for (i = 0; i < {n}; i = i + 1) begin")
for at in checks_at:
    if at < n:
        L.append(f"      if (i == {at}) begin")
        L.extend(mem_checks(at))
        L.append("      end")
L.append("      if (marks[i]) begin")
L.append("        wait (mi == n_before[i]); @(negedge clk) restart = 1; @(negedge clk) restart = 0;")
L.append("      end")
L.append("      while (($random % 3) == 0) @(negedge clk);")
L.append("      s_valid = 1; s_data = xs[i];")
L.append("      @(posedge clk); while (!s_ready) @(posedge clk);")
L.append("      @(negedge clk) s_valid = 0;")
L.append("    end")
L.append(f"    wait (mi == {ny});")
L.extend(l[4:] for l in mem_checks(n))
L.append(f"    $display(\"RESULT {top}: vectors={n} errors=%0d clocks/word=%0d\", errors, ($time - t0) / 10 / {n});")
L.append("    $finish;")
L.append("  end")
L.append(f"  initial begin #({n} * 4000 + 10000); $display(\"TIMEOUT {top}: %0d of {ny} outputs\", mi); $finish; end")
L.append("endmodule")
open(out, "w").write("\n".join(L) + "\n")
