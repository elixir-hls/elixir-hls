#!/usr/bin/env python3
"""Give every block of a func its own copies of the constants it uses.

`mlir-opt --canonicalize` hoists all constants into the entry block; CIRCT's handshake
lowering then passes each one used after a loop through the loop like a variable (a mux, a
fork and a buffer per constant, every iteration). A constant defined in the block that uses
it costs nothing of the kind.

usage: sink_constants.py <in.mlir> <out.mlir>
"""
import re
import sys

src, dst = sys.argv[1:3]
lines = open(src).read().split("\n")
CONST = re.compile(r"^\s*(%[\w-]+) = arith\.constant (.*)$")
LABEL = re.compile(r"^\s*\^(bb\d+)")

consts = {}
for line in lines:
    m = CONST.match(line)
    if m:
        consts[m.group(1)] = m.group(2)
    if LABEL.match(line):
        break

out, block, n = [], None, 0
for line in lines:
    m = LABEL.match(line)
    if m:
        block = m.group(1)
        out.append(line)
        continue
    if block and not line.strip().startswith("}"):
        used = [c for c in consts if re.search(re.escape(c) + r"(?![\w-])", line)]
        for c in used:
            local = f"{c}_{block}"
            if not any(l.strip().startswith(f"{local} =") for l in out):
                # right after the block's label (before its first use)
                i = len(out) - 1
                while not LABEL.match(out[i]):
                    i -= 1
                out.insert(i + 1, f"    {local} = arith.constant {consts[c]}")
                n += 1
            line = re.sub(re.escape(c) + r"(?![\w-])", local, line)
    if line.strip() == "}":
        block = None
    out.append(line)
open(dst, "w").write("\n".join(out))
print(f"sink_constants: {n} constant(s) into their blocks", file=sys.stderr)
