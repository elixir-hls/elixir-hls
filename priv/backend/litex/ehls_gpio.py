"""
EHLS.GPIO's circuit: pins read and written by the CPU, knowing no board (the options come from
use EHLS, blocks: [{EHLS.GPIO, ...}]: configure). Added as soc.ehls_gpio, CSRs ehls_gpio_*:

  out_set, out_clr  write: bits to set / clear in the output values
  oe_set, oe_clr    write: bits of inouts to turn into outputs / inputs
  in                the levels on the pins (of an out: the value written)

Pipeline stages on the same pins (BLOCKS; built with soc.ehls_gpio there): changes(pin, edge), a
source (a pin's events: changes(pin, edge) |> EHLS.PubSub.broadcast(topic) in an instance); sample(pin), the pin's
level at each word; pin_out(pin), a sink.

Set and clear are separate registers so that changing one pin needs no read-modify-write:
several processes, or a runtime with several schedulers, cannot undo each other's change.
"""
from migen import Cat, If, Signal
from migen.fhdl.specials import Tristate
from migen.genlib.cdc import MultiReg
from litex.build.generic_platform import IOStandard, Pins
from litex.gen import LiteXModule
from litex.soc.interconnect import stream
from litex.soc.interconnect.csr import CSR, CSRStatus

PINS = []


def configure(options):
    """options: {"pins": [{name, bit, dir, pin, pull, active_low, board}]}, from EHLS.GPIO."""
    PINS[:] = options["pins"]


def _pull(soc, pull):
    """The pin constraints for a pull, from the device backend (hls_litex.add_hls's pin_pull)."""
    pin_pull = getattr(soc, "ehls_pin_pull", None)
    if pin_pull:
        return pin_pull(pull)
    if pull == "none":
        return []
    raise SystemExit(f"ehls_gpio: pull {pull}: the target gave add_hls no pin_pull for its device")


class GPIO(LiteXModule):
    """pads: name -> the pin's signal; pins as in configure. A test gives Records with o, oe, i
    for the inouts instead of inout pads."""
    def __init__(self, pins, pads):
        n = len(pins)
        self.out_set = CSR(n)
        self.out_clr = CSR(n)
        self.oe_set = CSR(n)
        self.oe_clr = CSR(n)
        self._in = CSRStatus(n, name="in", description="The levels on the pins.")
        # the values in registers, as the CPU sees them (active_low is at the pin)
        self.o = o = Signal(n)
        self.oe = oe = Signal(n)
        self.sync += [
            If(self.out_set.re, o.eq(o | self.out_set.r)),
            If(self.out_clr.re, o.eq(o & ~self.out_clr.r)),
            If(self.oe_set.re, oe.eq(oe | self.oe_set.r)),
            If(self.oe_clr.re, oe.eq(oe & ~self.oe_clr.r)),
        ]
        levels = []
        for p in pins:
            bit, pad = p["bit"], pads[p["name"]]
            invert = (lambda v: ~v) if p["active_low"] else (lambda v: v)
            if p["dir"] == "out":
                self.comb += pad.eq(invert(o[bit]))
                levels.append(o[bit])
                continue
            raw = Signal()
            if p["dir"] == "in":
                self.comb += raw.eq(pad)
            elif hasattr(pad, "oe"):
                self.comb += [pad.o.eq(invert(o[bit])), pad.oe.eq(oe[bit]), raw.eq(pad.i)]
            else:
                self.specials += Tristate(pad, invert(o[bit]), oe[bit], raw)
            sync = Signal()
            self.specials += MultiReg(invert(raw), sync)
            levels.append(sync)
        self.comb += self._in.status.eq(Cat(*levels))
        self.levels = {p["name"]: levels[p["bit"]] for p in pins}
        self.bits = {p["name"]: p["bit"] for p in pins}


class Changes(LiteXModule):
    """Source: one word per edge of a pin ("rising", "falling", "both"), its new level (1 bit). A
    word waits until it is taken; an edge meanwhile replaces it."""
    source_width = 1

    def __init__(self, soc, enable, pin, edge):
        self.source = stream.Endpoint([("data", 32)])
        level = soc.ehls_gpio.levels[pin]
        previous = Signal()
        fired = {"rising": level & ~previous, "falling": ~level & previous, "both": level ^ previous}[edge]
        self.sync += [
            previous.eq(level),
            If(~enable,
                self.source.valid.eq(0),
            ).Else(
                If(self.source.valid & self.source.ready, self.source.valid.eq(0)),
                If(fired, self.source.valid.eq(1), self.source.data.eq(level)),
            ),
        ]


class Sample(LiteXModule):
    """One word out per word in, the pin's level at that moment (1 bit): the word in only says
    when to read."""
    source_width = 1

    def __init__(self, soc, enable, pin):
        self.sink = stream.Endpoint([("data", 32)])
        self.source = stream.Endpoint([("data", 32)])
        self.comb += [
            self.source.valid.eq(self.sink.valid),
            self.sink.ready.eq(self.source.ready),
            self.source.data.eq(soc.ehls_gpio.levels[pin]),
        ]


class PinOut(LiteXModule):
    """Sink: the low bit of the latest word on an out pin (its polarity as declared); 0 from each
    start until the first word. Always ready."""
    def __init__(self, soc, enable, pin):
        self.sink = stream.Endpoint([("data", 32)])
        gpio = soc.ehls_gpio
        o = gpio.o[gpio.bits[pin]]
        was_enabled = Signal()
        self.comb += self.sink.ready.eq(1)
        self.sync += [
            was_enabled.eq(enable),
            If(enable & ~was_enabled, o.eq(0),
            ).Elif(self.sink.valid, o.eq(self.sink.data[0])),
        ]


def add_to_soc(soc):
    if not PINS:
        return
    ext = []
    for p in PINS:
        ext.append((f"ehls_gpio_{p['name']}", 0, Pins(p["pin"]), IOStandard("LVCMOS33"),
                    *([] if p["dir"] == "out" else _pull(soc, p["pull"]))))
    soc.platform.add_extension(ext)
    pads = {p["name"]: soc.platform.request(f"ehls_gpio_{p['name']}") for p in PINS}
    soc.ehls_gpio = GPIO(PINS, pads)


BLOCKS = {"changes": Changes, "sample": Sample, "pin_out": PinOut}
PERIPHERALS = {}
