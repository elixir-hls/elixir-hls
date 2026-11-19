#!/usr/bin/env python3
"""Cut long combinational paths of a CIRCT handshake function by inserting one-slot buffers.

hlstool's buffering strategies are all or nothing here: `cycles` leaves a kernel's arithmetic
as one combinational path (a de-emphasis filter missed 50 MHz with 28 logic levels), `all`
registers every channel (thousands of flip-flops for two small kernels). This pass sits
between `hlstool --output-level=post-compile` and `--input-level=post-compile`: it estimates
each value's arrival time from a rough per-operation delay (carry chains grow with the width,
multipliers are slow, shifts by constants / extensions / truncations / forks are wires) and
puts a `buffer [1] seq` in front of an operand when the operation would end later than the
budget.

It also makes hlstool's loop buffers one slot deep (`buffer [2] seq` -> `[1] seq`): a loop
iteration goes through the buffer behind each loop-carried value and the one behind the
loop condition, so two-slot buffers cost 3 clocks per iteration, one-slot ones 2 (and half
the registers). A one-slot seq buffer is a skid buffer: it still registers valid and ready.

The delays come from the device backend (EHLS.Device.delay_model/0, the environment's
DELAY_MODEL as JSON; the generic model without it).

usage: pipeline_buffers.py <in.mlir> <out.mlir> [budget]     (budget in ns, default 12)
"""
import json
import os
import re
import sys

src, dst = sys.argv[1:3]
budget = float(sys.argv[3]) if len(sys.argv) > 3 else 12.0

FREE = {"arith.extsi", "arith.extui", "arith.trunci", "fork", "constant", "buffer", "sink",
        "join", "source", "lazy_fork"}


def width(t):
    m = re.match(r"i(\d+)", t)
    return int(m.group(1)) if m else 1


# the generic model (EHLS.Device.default_model/0): carry chains grow with the width,
# multipliers are slow
M = {"shift": [1.5, 0.1], "logic": 0.6, "select": 0.8, "add": [1.2, 0.05], "mul": [7.0, 0.1],
     "div_per_bit": 4.0, "other": 1.0}
M.update(json.loads(os.environ.get("DELAY_MODEL") or "{}"))


def op_delay(op, w, operands, consts):
    if op in FREE:
        return 0.0
    if op in ("arith.shli", "arith.shrui", "arith.shrsi"):
        return 0.0 if operands[1] in consts else M["shift"][0] + M["shift"][1] * w
    if op in ("arith.andi", "arith.ori", "arith.xori"):
        return M["logic"]
    if op == "arith.select":
        return M["select"]
    if op in ("arith.addi", "arith.subi", "arith.cmpi", "arith.maxsi", "arith.minsi",
              "arith.maxui", "arith.minui"):
        return M["add"][0] + M["add"][1] * w
    if op == "arith.muli":
        return M["mul"][0] + M["mul"][1] * w
    if op.startswith("arith.div") or op.startswith("arith.rem"):
        return M["div_per_bit"] * w
    return M["other"]


DEF = re.compile(r"^(\s*)(%[\w]+)(?::(\d+))? = ([\w.]+)\b(.*?)(?:\s*\{[^}]*\})?\s*:\s*(.*)$")

lines = open(src).read().split("\n")
types, arrival, consts = {}, {}, set()
out, n_buf = [], 0
for line in lines:
    m = DEF.match(line)
    if not m:
        out.append(line)
        continue
    indent, res, nres, op, rest, ty = m.groups()
    result_type = ty.split(" to ")[-1].strip() if " to " in ty else ty.strip()
    # result type of comparisons is i1; operand type is the annotated one
    operand_type = ty.split(" to ")[0].strip()
    if op == "arith.cmpi":
        result_type = "i1"
    if op == "arith.select":
        operand_type = None
    if op == "buffer" and rest.lstrip().startswith("[2] seq"):
        rest = rest.replace("[2] seq", "[1] seq", 1)
        line = line.replace(m.group(5), rest, 1)
    operands = re.findall(r"%[\w]+(?:#\d+)?", rest)
    if op == "constant":
        consts.add(res)
    w = width(result_type if op != "arith.cmpi" else operand_type)
    d = op_delay(op, w, operands, consts)
    start = max([arrival.get(o, 0.0) for o in operands] or [0.0])
    if d > 0 and start + d > budget:
        new_rest = rest
        # longest names first (%10 before %1 for the replace below); otherwise in operand
        # order, so that the output does not depend on Python's hash seed
        for o in sorted(dict.fromkeys(operands), key=len, reverse=True):
            if arrival.get(o, 0.0) > 0:
                t = types.get(o, operand_type)
                b = f"%pb{n_buf}"
                n_buf += 1
                out.append(f"{indent}{b} = buffer [1] seq {o} : {t}")
                new_rest = re.sub(re.escape(o) + r"(?![\w#])", b, new_rest)
                arrival[b] = 0.0
        rest = new_rest
        line = line.replace(m.group(5), rest, 1)
        start = 0.0
    end = start + d
    if nres:
        for i in range(int(nres)):
            types[f"{res}#{i}"] = result_type
            arrival[f"{res}#{i}"] = end
    types[res] = result_type
    arrival[res] = end
    if op == "constant" or (op == "buffer" and "seq" in rest):
        arrival[res] = 0.0       # a register
    out.append(line)
open(dst, "w").write("\n".join(out))
print(f"pipeline_buffers: {n_buf} buffer(s), budget {budget} ns", file=sys.stderr)
