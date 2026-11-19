#!/usr/bin/env python3
"""Prefix every module of a CIRCT-generated .sv except the top one with "<top>__", so that
several kernels can share one design (hlstool names its helper modules after the operation,
e.g. handshake_fork_in_ui16_out_ui16_ui16, the same in every file)."""
import re
import sys

path, top = sys.argv[1:3]
sv = open(path).read()
names = [n for n in re.findall(r"^\s*module\s+(\w+)", sv, re.M) if n != top]
if names:
    pattern = re.compile(r"\b(" + "|".join(map(re.escape, sorted(names, key=len, reverse=True))) + r")\b")
    sv = pattern.sub(lambda m: f"{top}__{m.group(1)}", sv)
open(path, "w").write(sv)
