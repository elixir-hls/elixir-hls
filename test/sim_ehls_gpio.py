#!/usr/bin/env python3
"""EHLS.GPIO's circuit in simulation (Migen), no FPGA: set / clear, direction, polarity,
synchronized inputs, edge events.
usage: test/sim_ehls_gpio.py  (with LiteX importable; EHLS_DEVICE unset)"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "priv", "backend", "litex"))
from types import SimpleNamespace

from migen import Module, Record, Signal, run_simulation
from ehls_gpio import GPIO, Changes, PinOut, Sample
from hls_litex_blocks import Hold

PINS = [
    dict(name="a", bit=0, dir="out", active_low=False),
    dict(name="b", bit=1, dir="out", active_low=True),
    dict(name="c", bit=2, dir="in", active_low=False),
    dict(name="d", bit=3, dir="in", active_low=True),
    dict(name="e", bit=4, dir="inout", active_low=False),
]
pads = {p["name"]: Signal() for p in PINS if p["dir"] != "inout"}
pads["e"] = Record([("o", 1), ("oe", 1), ("i", 1)])
dut = GPIO(PINS, pads)


def csr_write(csr, v):
    yield csr.r.eq(v)
    yield csr.re.eq(1)
    yield
    yield csr.re.eq(0)
    yield
    yield


def bench():
    # at reset
    yield
    yield
    assert (yield pads["a"]) == 0
    assert (yield pads["b"]) == 1, "active low: value 0 is a high pin"
    assert (yield pads["e"].oe) == 0, "an inout starts as an input"
    # set and clear change one bit each
    yield from csr_write(dut.out_set, 0b00011)
    assert (yield pads["a"]) == 1 and (yield pads["b"]) == 0
    assert (yield dut.o) == 0b00011
    yield from csr_write(dut.out_clr, 0b00001)
    assert (yield dut.o) == 0b00010
    assert (yield pads["a"]) == 0 and (yield pads["b"]) == 0
    # out reads back the value written
    assert ((yield dut._in.status) & 0b11) == 0b10
    # inputs arrive through the synchronizer, inverted when active low
    yield pads["c"].eq(1)
    yield pads["d"].eq(1)
    yield pads["e"].i.eq(1)
    for _ in range(5):
        yield
    assert (((yield dut._in.status) >> 2) & 7) == 0b101
    yield pads["d"].eq(0)
    for _ in range(5):
        yield
    assert (((yield dut._in.status) >> 2) & 7) == 0b111
    # an inout: a write while an input waits for the direction
    yield from csr_write(dut.out_set, 0b10000)
    assert (yield pads["e"].oe) == 0 and (yield pads["e"].o) == 1
    yield from csr_write(dut.oe_set, 0b10000)
    assert (yield pads["e"].oe) == 1
    yield from csr_write(dut.oe_clr, 0b10000)
    assert (yield pads["e"].oe) == 0
    print("sim_ehls_gpio: ok")


run_simulation(dut, bench())


# changes -> hold: a word per edge, the source waits to be taken; hold keeps the latest, 0 from a start
class Stages(Module):
    def __init__(self):
        self.pin = Signal()
        self.enable = Signal()
        soc = SimpleNamespace(ehls_gpio=SimpleNamespace(levels={"p": self.pin}))
        self.submodules.changes = Changes(soc, self.enable, "p", "rising")
        self.submodules.hold = Hold(soc, self.enable, "h")
        self.comb += self.changes.source.connect(self.hold.sink)


stages = Stages()


def pulse():
    yield stages.pin.eq(1)
    yield
    yield
    yield
    yield stages.pin.eq(0)
    yield
    yield
    yield


def bench_stages():
    c, h = stages.changes, stages.hold
    yield from pulse()
    assert (yield h.state) == 0, "disabled: no words"
    yield stages.enable.eq(1)
    yield
    yield
    assert (yield c.source.valid) == 0
    yield stages.pin.eq(1)
    seen = 0
    for _ in range(6):
        yield
        seen += (yield c.source.valid)
    assert seen == 1, f"one word per edge, {seen}"
    assert (yield h.state) == 1
    yield stages.pin.eq(0)
    for _ in range(4):
        yield
        assert (yield c.source.valid) == 0, "rising only"
    assert (yield h.state) == 1, "a level: kept"
    # a restart: 0 until the first word
    yield stages.enable.eq(0)
    yield
    yield
    assert (yield h.state) == 1, "kept while stopped"
    yield stages.enable.eq(1)
    yield
    yield
    assert (yield h.state) == 0
    print("sim changes, hold: ok")


run_simulation(stages, bench_stages())


# sample: the level at each word; pin_out: the low bit kept, 0 from a start
class Stages2(Module):
    def __init__(self):
        self.pin = Signal()
        self.enable = Signal()
        self.o = Signal(2)
        soc = SimpleNamespace(ehls_gpio=SimpleNamespace(levels={"p": self.pin}, bits={"l": 1}, o=self.o))
        self.submodules.sample = Sample(soc, self.enable, "p")
        self.submodules.pin_out = PinOut(soc, self.enable, "l")
        self.comb += self.sample.source.connect(self.pin_out.sink)


stages2 = Stages2()


def bench_stages2():
    s = stages2
    yield s.enable.eq(1)
    yield
    yield
    assert (yield s.o) == 0
    yield s.pin.eq(1)
    yield
    yield
    assert (yield s.o) == 0, "no word: not read"
    yield s.sample.sink.valid.eq(1)
    yield
    yield s.sample.sink.valid.eq(0)
    yield
    yield
    assert (yield s.o) == 0b10, "word: read, only that bit"
    yield s.pin.eq(0)
    yield
    yield
    assert (yield s.o) == 0b10, "kept"
    yield s.enable.eq(0)
    yield
    yield s.enable.eq(1)
    yield
    yield
    assert (yield s.o) == 0, "0 from a start"
    print("sim sample, pin_out: ok")


run_simulation(stages2, bench_stages2())
