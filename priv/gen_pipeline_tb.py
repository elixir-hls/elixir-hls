#!/usr/bin/env python3
"""Generate an iverilog testbench for consecutive kernel stages of an instance (mix ehls.sim):
the stages behind their adapters with the initial state each stage gives, linked as in the SoC
(hls_litex.py Pipeline: one element per clock, as wide as the values of the producer's type, each
sign- or zero-extended to 32 bits, a FIFO before a kernel with a memory space).

An instance of levels (EHLS.Level) instead: its kernel behind hls_level_adapter.v, called as the CPU
does (level_tb below).

usage: gen_pipeline_tb.py <hw dir> <pipeline index> <first stage> <last stage> <in.hex> <out.hex> <out_tb.sv>

in.hex / out.hex: the values into the first stage and those expected from the last, one per
line, an element's in order. Input and output are stalled at random. Prints "RESULT <name>: words=N outputs=M
errors=E clocks/word=C" (or TIMEOUT). Lists the Verilog files to compile on stdout.
"""
import json
import os
import sys

hw, pi, first, last, in_hex, out_hex, out = sys.argv[1:8]
pi, first, last = int(pi), int(first), int(last)
kernels = {k["kernel"]: k for k in json.load(open(os.path.join(hw, "kernels.json")))}
pipe = json.load(open(os.path.join(hw, "pipelines.json")))[pi]
stages = pipe["stages"][first:last + 1]
priv = os.path.dirname(os.path.abspath(__file__))
FIFO_DEPTH = 4      # hls_litex.py Pipeline: before a time-multiplexed kernel
name = f"{pipe['name']}[{first}..{last}]"


def fields(t):
    """As hls_litex.py _fields: [(bits, signed)], one per value of the element."""
    if isinstance(t, list):
        return [f for e in t for f in fields(e)]
    return [(int(t[1:]), t[0] == "s")]


def lane(k):
    """Bits per value at a kernel's ports (hls_litex.py Kernel)."""
    return k.get("lane", 32)


def count(path):
    return sum(1 for line in open(path) if line.strip())


L = ["`timescale 1ns/1ps"]
# the links: a FIFO of W bits
L += """module hls_sim_link #(parameter integer W = 32, parameter integer DEPTH = 2) (
  input wire clk, input wire rst,
  input wire s_valid, output wire s_ready, input wire [W-1:0] s_data,
  output wire m_valid, input wire m_ready, output wire [W-1:0] m_data);
  reg [W-1:0] mem [0:DEPTH-1];
  integer rp = 0, wp = 0, n = 0;
  assign s_ready = n < DEPTH;
  assign m_valid = n > 0;
  assign m_data = mem[rp];
  always @(posedge clk)
    if (rst) begin rp <= 0; wp <= 0; n <= 0; end
    else begin
      if (s_valid && s_ready) begin mem[wp] <= s_data; wp <= (wp + 1) % DEPTH; end
      if (m_valid && m_ready) rp <= (rp + 1) % DEPTH;
      n <= n + ((s_valid && s_ready) ? 1 : 0) - ((m_valid && m_ready) ? 1 : 0);
    end
endmodule""".split("\n")
L += ["module tb;", "  reg clk = 0, rst = 1; wire restart = 0;", "  always #5 clk = ~clk;"]
n_in, n_out = count(in_hex), count(out_hex)
ni_first = kernels[stages[0]["kernel"]].get("in_words", 1)
ny_last = kernels[stages[-1]["kernel"]].get("out_words", 1)
w_first, w_last = lane(kernels[stages[0]["kernel"]]), lane(kernels[stages[-1]["kernel"]])
L.append(f"  reg in_valid = 0; wire in_ready; reg [{ni_first * w_first - 1}:0] in_data = 0;")
L.append(f"  wire out_valid; reg out_ready = 0; wire [{ny_last * w_last - 1}:0] out_data;")


def stage(i, st):
    """A kernel behind its adapter: ports p<i>_s_* in, p<i>_m_* out (hls_litex.py Kernel)."""
    k = kernels[st["kernel"]]
    p = f"p{i}"
    ns, emit, np_ = len(k["state"]), int(k.get("emit", False)), len(k.get("args", []))
    ni, ny, space = k.get("in_words", 1), k.get("out_words", 1), k.get("space")
    W = lane(k)
    L.append(f"  wire {p}_s_valid, {p}_s_ready, {p}_m_valid, {p}_m_ready; wire [{ni * W - 1}:0] {p}_s_data; wire [{ny * W - 1}:0] {p}_m_data;")
    n, no = ni + ns, emit + ny + ns
    L.append(f"  wire [{n * W - 1}:0] {p}_ki; wire [{no * W - 1}:0] {p}_ko;")
    L.append(f"  wire [{n}:0] {p}_kiv, {p}_kir; wire [{no}:0] {p}_kov, {p}_kor;")
    stream = (f".clk(clk), .rst(rst), .engaged(), .s_valid({p}_s_valid), .s_ready({p}_s_ready), .s_data({p}_s_data), "
              f".m_valid({p}_m_valid), .m_ready({p}_m_ready), .m_data({p}_m_data)")
    if ns == 0:
        L.append(f"  hls_stream_adapter #(.IW({W}), .OW({W})) {p}_adapter ({stream}, "
                 f".k_in0({p}_ki), .k_in0_valid({p}_kiv[0]), .k_in0_ready({p}_kir[0]), "
                 f".k_in1_valid({p}_kiv[1]), .k_in1_ready({p}_kir[1]), "
                 f".k_out0({p}_ko), .k_out0_valid({p}_kov[0]), .k_out0_ready({p}_kor[0]), "
                 f".k_out1_valid({p}_kov[1]), .k_out1_ready({p}_kor[1]));")
    else:
        init = st.get("init", k["init"])
        assert len(init) == ns, f"{k['kernel']}: {len(init)} initial words for {ns} state words"
        hexinit = "".join(f"{w:0{W // 4}x}" for w in reversed(init))
        L.append(f"  hls_state_adapter #(.W({W}), .NS({ns}), .INIT({ns * W}'h{hexinit}), .EMIT({emit}), .NI({ni}), .NY({ny})) "
                 f"{p}_adapter ({stream}, .restart(restart), .state_out(), "
                 f".k_in_data({p}_ki), .k_in_valid({p}_kiv), .k_in_ready({p}_kir), "
                 f".k_out_data({p}_ko), .k_out_valid({p}_kov), .k_out_ready({p}_kor));")
    ports = [".clock(clk), .reset(rst)"]
    for j in range(n):
        ports.append(f".in{j}({p}_ki[{j * W} +: {W}]), .in{j}_valid({p}_kiv[{j}]), .in{j}_ready({p}_kir[{j}])")
    # the level arguments at the value the stage is wired to at first, then the memory space, then the start token
    for j, prm in enumerate(st.get("args") or k.get("args", [])):
        ports.append(f".in{n + j}(32'h{prm['default'] & 0xFFFFFFFF:08x}), .in{n + j}_valid(1'b1), .in{n + j}_ready()")
    tok = n + np_ + (1 if space else 0)
    ports.append(f".in{tok}_valid({p}_kiv[{n}]), .in{tok}_ready({p}_kir[{n}])")
    for j in range(no):
        ports.append(f".out{j}({p}_ko[{j * W} +: {W}]), .out{j}_valid({p}_kov[{j}]), .out{j}_ready({p}_kor[{j}])")
    ports.append(f".out{no}_valid({p}_kov[{no}]), .out{no}_ready({p}_kor[{no}])")
    if space:
        a, aw = space["arg"], space["aw"]
        sp = [".clk(clk), .rst(rst), .restart(restart)"]
        for j in range(space["nld"]):
            L.append(f"  wire [{aw - 1}:0] {p}_ld{j}_addr; wire [31:0] {p}_ld{j}_data; "
                     f"wire {p}_ld{j}_addr_valid, {p}_ld{j}_addr_ready, {p}_ld{j}_data_valid, {p}_ld{j}_data_ready;")
            for s in ["addr", "addr_valid", "addr_ready", "data", "data_valid", "data_ready"]:
                ports.append(f".in{a}_ld{j}_{s}({p}_ld{j}_{s})")
                sp.append(f".ld{j}_{s}({p}_ld{j}_{s})")
        for j in range(space["nst"]):
            L.append(f"  wire [{aw + 31}:0] {p}_st{j}; wire {p}_st{j}_valid, {p}_st{j}_ready, "
                     f"{p}_st{j}_done_valid, {p}_st{j}_done_ready;")
            for s in ["", "_valid", "_ready", "_done_valid", "_done_ready"]:
                ports.append(f".in{a}_st{j}{s}({p}_st{j}{s})")
                sp.append(f".st{j}{s}({p}_st{j}{s})")
        sp.append(".cpu_addr('0), .cpu_req(1'b0), .cpu_q(), .cpu_done()")
        L.append(f"  {space['module']} {p}_space ({', '.join(sp)});")
    L.append(f"  {k['kernel']} {p}_kernel ({', '.join(ports)});")


for i, st in enumerate(stages):
    stage(i, st)


def level_tb():
    """An instance of levels: its kernel behind hls_level_adapter.v, driven as the CPU does. in.hex: per
    call a flag, 1 (wait for the result and check it), 0 (no wait: the next start may come while it
    computes) or 2 (stop and start: the result goes back to the initial one), then for 0 and 1 the
    values of the arguments. out.hex: the initial result, then the expected result of every call, each
    value cut to its type. Whenever the count held with the result changes, the result must be that
    start's: what the CPU reads together cannot belong to different writes."""
    k = kernels[stages[0]["kernel"]]
    W, ni, ny = lane(k), k.get("in_words", 1), k.get("out_words", 1)
    bits = [b for b, _ in fields(k["ret"])]
    init = 0
    for i, v in enumerate(pipe["level"]["initial"]):
        init |= (v & ((1 << W) - 1)) << (W * i)
    L.append(f"  reg enable = 1, wr = 0, start = 0; reg [7:0] wr_index = 0; reg [31:0] wr_data = 0;")
    L.append(f"  wire [31:0] issued, done; wire [{W * ny - 1}:0] result; reg [31:0] my;")
    L.append(f"  hls_level_adapter #(.W({W}), .NI({ni}), .NY({ny}), .INIT({W * ny}'h{init:x})) level (.clk(clk), .rst(rst), "
             f".enable(enable), .wr(wr), .wr_index(wr_index), .wr_data(wr_data), .start(start), .issued(issued), "
             f".result(result), .done(done), .s_valid(p0_s_valid), .s_ready(p0_s_ready), .s_data(p0_s_data), "
             f".m_valid(late_valid & late), .m_ready(late_ready), .m_data(late_data));")
    # the results held back at random, as a kernel that takes long would: starts then come while it computes
    L.append(f"  reg late = 0; wire late_valid, late_ready; wire [{W * ny - 1}:0] late_data;")
    L.append("  always @(negedge clk) late <= ($random % 8) == 0;")
    L.append(f"  hls_sim_link #(.W({W * ny}), .DEPTH(2)) late_link (.clk(clk), .rst(rst), .s_valid(p0_m_valid), "
             f".s_ready(p0_m_ready), .s_data(p0_m_data), .m_valid(late_valid), .m_ready(late_ready & late), .m_data(late_data));")
    L.append(f"  reg [63:0] xs [0:{max(n_in, 1) - 1}]; reg [63:0] ys [0:{max(n_out, 1) - 1}];")
    L.append("  integer i, j, k, t, yi = 0, calls = 0, errors = 0, held = 0;")
    L.append(f"  integer at [0:{max(n_in, 1)}]; reg [31:0] done_d = 0; reg enable_d = 1;")
    L.append(f'  initial begin $readmemh("{in_hex}", xs); $readmemh("{out_hex}", ys); end')
    L.append("  task check(input integer y); begin")
    for j, b in enumerate(bits):
        L.append(f"    if ((result[{j * W} +: {b}]) !== ys[y + {j}][{b - 1}:0]) begin errors = errors + 1;")
        L.append(f'      if (errors <= 5) $display("MISMATCH result of call %0d value {j}: got %h expected %h", y / {ny}, result[{j * W} +: {b}], ys[y + {j}][{b - 1}:0]); end')
    L.append("  end endtask")
    # a new result held while running: the one of the start it says (sampled at the rising edge, the
    # values of the clock before; enable_d: whether that clock ran)
    L.append("  always @(posedge clk) begin")
    L.append("    if (!rst && enable_d && done != done_d) begin check(at[done]); held = held + 1; end")
    L.append("    done_d <= done; enable_d <= enable;")
    L.append("  end")
    L.append("  initial begin")
    L.append("    repeat (4) @(posedge clk); @(negedge clk) rst = 0;")
    L.append("    @(negedge clk) check(0);")
    L.append(f"    i = 0; yi = {ny};")
    L.append(f"    while (i < {n_in}) begin")
    L.append("      calls = calls + 1;")
    L.append("      if (xs[i] == 2) begin")
    L.append("        enable = 0; repeat (1 + $urandom % 8) @(negedge clk); enable = 1;")
    L.append(f"        @(negedge clk); @(negedge clk) check(yi); i = i + 1; yi = yi + {ny};")
    L.append("      end else begin")
    L.append(f"        for (j = 0; j < {ni}; j = j + 1)")
    L.append(f"          for (k = 0; k < {W // 32}; k = k + 1) begin")
    L.append("            while (($random % 3) == 0) @(negedge clk);")
    L.append(f"            wr = 1; wr_index = j * {W // 32} + k; wr_data = xs[i + 1 + j] >> (32 * k); @(negedge clk) wr = 0;")
    L.append("          end")
    L.append("        while (($random % 3) == 0) @(negedge clk);")
    L.append("        start = 1; at[issued + 1] = yi; @(negedge clk) start = 0; my = issued;")
    L.append("        if (xs[i] == 1) begin")
    L.append("          t = 0; while (done != my && t < 100000) begin @(negedge clk); t = t + 1; end")
    L.append(f'          if (t >= 100000) begin $display("TIMEOUT {name}: call %0d", calls); $finish; end')
    L.append("          check(yi);")
    L.append("        end")
    L.append(f"        yi = yi + {ny};")
    L.append(f"        i = i + 1 + {ni};")
    L.append("      end")
    L.append("    end")
    L.append(f'    $display("RESULT {name}: calls=%0d held=%0d errors=%0d ", calls, held, errors);')
    L.append("    $finish;")
    L.append("  end")
    L.append("endmodule")
    open(out, "w").write("\n".join(L) + "\n")
    print("\n".join([k["sv"]] + [os.path.join(priv, "verilog", f) for f in
                                   ("hls_level_adapter.v", "hls_state_adapter.v", "hls_stream_adapter.v")]))
    sys.exit(0)


if "level" in pipe:
    level_tb()


def link(name, s, m, flds, depth, ws, wm):
    """As hls_litex.py _link: the values packed into one word, from ws bits per value at s, each
    extended to wm bits at m."""
    w = sum(b for b, _ in flds)
    packed, wide, at = [], [], 0
    for i, (b, signed) in enumerate(flds):
        packed.append(f"{s}_data[{ws * i} +: {b}]")
        d = f"{name}_q[{at} +: {b}]"
        sign = f"{name}_q[{at + b - 1}]" if signed else "1'b0"
        wide.append(f"{name}_q[{at} +: {wm}]" if b >= wm else f"{{{{{wm - b}{{{sign}}}}}, {d}}}")
        at += b
    L.append(f"  wire [{w - 1}:0] {name}_q;")
    L.append(f"  hls_sim_link #(.W({w}), .DEPTH({depth})) {name} (.clk(clk), .rst(rst), "
             f".s_valid({s}_valid), .s_ready({s}_ready), .s_data({{{', '.join(reversed(packed))}}}), "
             f".m_valid({m}_valid), .m_ready({m}_ready), .m_data({name}_q));")
    L.append(f"  assign {m}_data = {{{', '.join(reversed(wide))}}};")


def depth(st):
    return FIFO_DEPTH if kernels[st["kernel"]].get("space") else 2


link("link_in", "in", "p0_s", [(w_first, False)] * ni_first, depth(stages[0]), w_first, w_first)
for i in range(len(stages) - 1):
    link(f"link{i}", f"p{i}_m", f"p{i + 1}_s", fields(kernels[stages[i]["kernel"]]["ret"]), depth(stages[i + 1]),
         lane(kernels[stages[i]["kernel"]]), lane(kernels[stages[i + 1]["kernel"]]))
link("link_out", f"p{len(stages) - 1}_m", "out", fields(kernels[stages[-1]["kernel"]]["ret"]), 2, w_last, w_last)

# the words of mix ehls.sim: 64-bit hex, each value cut to the ports' width
L.append(f"  reg [63:0] xs [0:{max(n_in, 1) - 1}]; reg [63:0] ys [0:{max(n_out, 1) - 1}];")
L.append(f"  integer i, j, k, mi = 0, errors = 0, t0 = 0;")
L.append(f'  initial begin $readmemh("{in_hex}", xs); $readmemh("{out_hex}", ys); end')
L.append("  always @(negedge clk) out_ready <= ($random % 4) != 0;")
L.append("  always @(posedge clk) if (!rst && out_valid && out_ready) begin")
L.append(f"    for (j = 0; j < {ny_last}; j = j + 1) begin")
L.append(f"      if (mi >= {n_out}) begin")
L.append("        errors = errors + 1;")
L.append('        if (errors <= 5) $display("MISMATCH an output more than expected: %h", out_data);')
L.append(f"      end else if (out_data[j * {w_last} +: {w_last}] !== ys[mi][{w_last - 1}:0]) begin")
L.append("        errors = errors + 1;")
L.append(f'        if (errors <= 5) $display("MISMATCH output %0d: got %h expected %h", mi, out_data[j * {w_last} +: {w_last}], ys[mi][{w_last - 1}:0]);')
L.append("      end")
L.append("      mi = mi + 1;")
L.append("    end")
L.append("  end")
L.append("  initial begin")
L.append("    repeat (4) @(posedge clk); @(negedge clk) rst = 0; t0 = $time;")
L.append(f"    for (i = 0; i < {n_in}; i = i + {ni_first}) begin")
L.append("      while (($random % 3) == 0) @(negedge clk);")
L.append(f"      for (k = 0; k < {ni_first}; k = k + 1) in_data[k * {w_first} +: {w_first}] = xs[i + k];")
L.append("      in_valid = 1;")
L.append("      @(posedge clk); while (!in_ready) @(posedge clk);")
L.append("      @(negedge clk) in_valid = 0;")
L.append("    end")
L.append(f"    wait (mi >= {n_out});")
# what is still on its way comes out now, if anything more does
L.append("    repeat (5000) @(negedge clk);")
L.append(f'    $display("RESULT {name}: words={n_in} outputs=%0d errors=%0d clocks/word=%0d", mi, errors, '
         f"(($time - t0) / 10 - 5000) / {max(n_in, 1)});")
L.append("    $finish;")
L.append("  end")
L.append(f'  initial begin #({max(n_in, 1)} * {len(stages)} * 20000 + 1000000); '
         f'$display("TIMEOUT {name}: %0d of {n_out} outputs", mi); $finish; end')
L.append("endmodule")
open(out, "w").write("\n".join(L) + "\n")

files = []
for st in stages:
    k = kernels[st["kernel"]]
    files.append(k["sv"])
    if k.get("space"):
        files.append(k["space"]["file"])
files += [os.path.join(priv, "verilog", "hls_state_adapter.v"), os.path.join(priv, "verilog", "hls_stream_adapter.v")]
print("\n".join(dict.fromkeys(files)))
