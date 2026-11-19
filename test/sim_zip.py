#!/usr/bin/env python3
"""The join of zip_with and a fork in simulation (Migen), no FPGA. Zip (hls_litex.py) between two inputs
offered at random and an output taken at random: every output must be one element of each input, in
order, nothing lost or repeated. Fork between an input offered at random and outputs each taken at
random: every output must get every element, in order. A broken join and a broken fork are caught.
usage: test/sim_zip.py  (with LiteX importable; EHLS_DEVICE unset)"""
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "priv", "backend", "litex"))

from migen import passive, run_simulation

from hls_litex import Fork, Zip

N = 500


def bench(dut):
    rnd = random.Random(7)
    a = [rnd.randrange(1 << 16) for _ in range(N)]
    b = [rnd.randrange(1 << 16) for _ in range(N)]
    got = []

    @passive
    def feed(sink, values):
        for v in values:
            while rnd.random() < 0.4:              # gaps before a value
                yield sink.valid.eq(0)
                yield
            yield sink.valid.eq(1)
            yield sink.data.eq(v)
            yield
            while not (yield sink.ready):
                yield
        yield sink.valid.eq(0)

    def take():
        cycles = 0
        while len(got) < N and cycles < 20 * N:
            yield dut.source.ready.eq(rnd.random() < 0.6)
            yield
            cycles += 1
            if (yield dut.source.valid) and (yield dut.source.ready):
                d = yield dut.source.data
                got.append((d & 0xFFFF, d >> 32 & 0xFFFF))

    run_simulation(dut, [feed(dut.sinks[0], a), feed(dut.sinks[1], b), take()])
    return got, list(zip(a, b))


def check(what, cond, info=""):
    print(("ok  " if cond else "FAIL") + f" {what} {info}")
    if not cond:
        sys.exit(1)


got, want = bench(Zip(32, 1, 1))
check("zip: one element of each, in order", got == want, f"({len(got)} of {len(want)})")


class Broken(Zip):
    """An input taken without waiting for the other: must not pass."""
    def __init__(self, lane, k0, k1):
        super().__init__(lane, k0, k1)
        self.comb += self.sinks[1].ready.eq(self.source.ready)


got, want = bench(Broken(32, 1, 1))
check("a broken join is caught", got != want)


def fork_bench(dut, n):
    rnd = random.Random(11)
    xs = [rnd.randrange(1 << 16) for _ in range(N)]
    got = [[] for _ in range(n)]

    @passive
    def feed():
        for v in xs:
            while rnd.random() < 0.3:
                yield dut.sink.valid.eq(0)
                yield
            yield dut.sink.valid.eq(1)
            yield dut.sink.data.eq(v)
            yield
            while not (yield dut.sink.ready):
                yield
        yield dut.sink.valid.eq(0)

    def take():
        cycles = 0
        while min(len(g) for g in got) < N and cycles < 30 * N:
            for src in dut.sources:
                yield src.ready.eq(rnd.random() < 0.5)
            yield
            cycles += 1
            for g, src in zip(got, dut.sources):
                if (yield src.valid) and (yield src.ready):
                    g.append((yield src.data) & 0xFFFF)

    run_simulation(dut, [feed(), take()])
    return got, xs


got, xs = fork_bench(Fork(32, 1, 3), 3)
check("fork: every element to each output, in order", all(g[:N] == xs for g in got), f"({[len(g) for g in got]})")


class BrokenFork(Fork):
    """The input taken once any output took it: the others miss elements."""
    def __init__(self, lane, k, n):
        super().__init__(lane, k, n)
        self.comb += self.sink.ready.eq(self.sources[0].valid & self.sources[0].ready)


got, xs = fork_bench(BrokenFork(32, 1, 3), 3)
check("a broken fork is caught", not all(g[:N] == xs for g in got))
