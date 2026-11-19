"""
The LiteX backend's built-in blocks for definstance (EHLS.SoC.LiteX.Blocks on the Elixir
side): blocks that need no board I/O. Every block has `sink` and/or `source`: 32-bit LiteX
stream endpoints; `enable` is the pipeline's enable (a source produces nothing while it is
0). Board blocks and peripherals come from block packages (EHLS.Blocks).
"""
from migen import Array, Cat, Constant, If, Mux, ResetInserter, Signal
from migen.genlib.roundrobin import SP_CE, RoundRobin
from litex.gen import LiteXModule
from litex.soc.interconnect import stream
from litex.soc.interconnect.csr import CSRStatus
from litedram.common import cmd_description, wdata_description
from litedram.frontend.dma import LiteDRAMDMAReader, LiteDRAMDMAWriter


class Ticks(LiteXModule):
    """Source: one word (a running count) `rate` times per second (a phase accumulator, so
    the rate is exact on average). A word waits until it is taken; none are dropped."""
    def __init__(self, soc, enable, rate):
        self.source = stream.Endpoint([("data", 32)])
        inc = int(round(rate * 2**32 / soc.sys_clk_freq))
        acc = Signal(33)
        count = Signal(32)
        self.sync += [
            If(~enable,
                acc.eq(0), count.eq(0), self.source.valid.eq(0),
            ).Else(
                acc.eq(acc[:32] + inc),
                If(self.source.valid & self.source.ready,
                    self.source.valid.eq(0), count.eq(count + 1)),
                If(acc[32], self.source.valid.eq(1)),
            )
        ]
        self.comb += self.source.data.eq(count)


class Discard(LiteXModule):
    """Sink: takes the words and does nothing with them."""
    def __init__(self, soc, enable):
        self.sink = stream.Endpoint([("data", 32)])
        self.comb += self.sink.ready.eq(1)


class WordsToElements(LiteXModule):
    """From the CPU: 32-bit words to packed elements of n bytes, little-endian, which may lie across
    words. The last word of a transfer (`sink.last`) has `pad` bytes that are not data."""
    def __init__(self, n):
        self.sink = stream.Endpoint([("data", 32)])
        self.source = stream.Endpoint([("data", 8 * n)])
        self.pad = Signal(2)
        self.reset = Signal()
        have, held = Signal(max=n + 4), Signal(8 * (n + 3))
        pad = Signal(2)
        self.comb += [
            pad.eq(Mux(self.sink.last, self.pad, 0)),
            self.sink.ready.eq(have < n),
            self.source.valid.eq(have >= n),
            self.source.data.eq(held[:8 * n]),
        ]
        mask = Array(Constant(m, 32) for m in (0xFFFFFFFF, 0xFFFFFF, 0xFFFF, 0xFF))[pad]
        self.sync += [
            If(self.reset, have.eq(0), held.eq(0)
            ).Elif(self.sink.valid & self.sink.ready,
                held.eq(held | ((self.sink.data & mask) << Cat(Constant(0, 3), have))),
                have.eq(have + 4 - pad),
            ).Elif(self.source.valid & self.source.ready,
                held.eq(held >> (8 * n)),
                have.eq(have - n),
            ),
        ]


class ElementsToWords(LiteXModule):
    """To the CPU: packed elements of n bytes to 32-bit words, little-endian. A transfer (`start`,
    then `size` bytes) takes exactly its elements and no more, so the next one begins with the
    element after them; what its last word has left over is zeros."""
    def __init__(self, n):
        self.sink = stream.Endpoint([("data", 8 * n)])
        self.source = stream.Endpoint([("data", 32)])
        self.start = Signal()
        self.size = Signal(32)
        self.reset = Signal()
        have, held, left = Signal(max=n + 4), Signal(8 * (n + 3)), Signal(32)
        self.comb += [
            self.sink.ready.eq((have < 4) & (left != 0)),
            self.source.valid.eq((have >= 4) | ((left == 0) & (have != 0))),
            self.source.data.eq(held[:32]),
        ]
        self.sync += [
            If(self.reset, have.eq(0), held.eq(0), left.eq(0)
            ).Elif(self.start, have.eq(0), held.eq(0), left.eq(self.size)
            ).Elif(self.sink.valid & self.sink.ready,
                held.eq(held | (self.sink.data << Cat(Constant(0, 3), have))),
                have.eq(have + n),
                left.eq(left - n),
            ).Elif(self.source.valid & self.source.ready,
                held.eq(held >> 32),
                If(have >= 4, have.eq(have - 4)).Else(have.eq(0)),
            ),
        ]


class CPUIn(LiteDRAMDMAReader):
    """An instance's input: the elements of a binary, `n` bytes each, from memory (CSRs base, length,
    enable, ...). The DMA moves whole words and looks only at length's upper bits: the driver writes
    the size rounded up to words, with the bytes the last word does not use in length's low 2 bits.
    `finished` (also a CSR) rises when the last word has left: only then can the DMA be disabled,
    which flushes its FIFO."""
    def __init__(self, port, n=4):
        super().__init__(port, fifo_depth=8, with_csr=True)
        self.finished = CSRStatus(description="The last word has gone.")
        self.reset = Signal()     # what is on its way dropped
        on, on_d = self._enable.storage, Signal()
        words = self.source
        self.sync += [
            on_d.eq(on),
            If(~on, self.finished.status.eq(0),
            ).Elif(words.valid & words.ready & words.last, self.finished.status.eq(1)),
        ]
        if n != 4:
            self.submodules.elements = conv = WordsToElements(n)
            self.source = conv.source
            self.comb += [
                words.connect(conv.sink),
                conv.pad.eq(self._length.storage[:2]),
                # finished, the elements of the last word still go on; cancelled, a part of one must not stay
                conv.reset.eq(self.reset | (on_d & ~on & ~self.finished.status)),
            ]


class CPUOut(LiteDRAMDMAWriter):
    """An instance's output: elements of `n` bytes to memory when the CPU asks (CSRs base, length,
    enable, ...; length as in CPUIn). `finished` (also a CSR) rises when the last word has gone out
    to memory. Until the CPU asks, the stream waits, or with `drop` its elements are lost once there
    is no room; `buffer` (elements, in block RAM) is what gathers meanwhile."""
    def __init__(self, port, n=4, buffer=0, drop=False):
        super().__init__(port, fifo_depth=8, with_csr=True)
        dma_sink, self.sink = self.sink, stream.Endpoint([("data", 8 * n)])
        self.finished = CSRStatus(description="The last word has gone to memory.")
        # with a shared port, also once the port has handed its words to the memory (SharedPort)
        port.writing = self.writing = Signal()
        self.comb += self.finished.status.eq(self._done.status & ~self.fifo.source.valid & ~self.writing)
        self.reset = Signal()     # what is gathered dropped
        if n != 4:
            on, on_d = self._enable.storage, Signal()
            length = self._length.storage
            self.sync += on_d.eq(on)
            self.submodules.words = conv = ElementsToWords(n)
            self.comb += [
                conv.source.connect(dma_sink),
                conv.start.eq(on & ~on_d),
                conv.size.eq(Cat(Constant(0, 2), length[2:]) - length[:2]),
                conv.reset.eq(self.reset | (on_d & ~on)),
            ]
            after = conv.sink
        else:
            after = dma_sink
        if buffer:
            self.submodules.buffer = gathered = ResetInserter()(stream.SyncFIFO([("data", 8 * n)], buffer, buffered=True))
            self.comb += [gathered.reset.eq(self.reset), gathered.source.connect(after)]
            into = gathered.sink
        else:
            into = after
        if not drop:
            self.comb += self.sink.connect(into)
        else:
            # a transfer in progress is not skipped over: the stream only loses elements between
            # transfers and when the buffer is full
            running = self._enable.storage & ~self._done.status
            self.comb += [
                into.valid.eq(self.sink.valid), into.data.eq(self.sink.data),
                self.sink.ready.eq(1 if buffer else (into.ready | ~running)),
            ]


class SharedPort(LiteXModule):
    """One LiteDRAM native port (`port`, mode "read" or "write") shared by the DMA engines on `ports`
    (native ports of the same widths), so that the crossbar has one port per direction however many
    CPU ends there are. The engines take turns per command, round-robin. A DMA engine only asks for
    what it can finish (a reader has reserved room for the data, a writer already holds it), so an end
    standing still, a slow source or an output nobody reads, never holds up the others. The data of
    the commands comes back, or is asked for, in their order: a FIFO of whose they were routes it.
    `ids`: the commands on their way at most. The commands and the data read are registered. A write
    port's `writing` (CPUOut's), if it has one, says that words of its are still on their way to the memory."""
    def __init__(self, port, ports, ids=16):
        n = len(ports)
        if n == 1:
            # nothing to share: the port itself, as without SharedPort
            self.comb += ports[0].cmd.connect(port.cmd)
            if port.mode == "read":
                self.comb += port.rdata.connect(ports[0].rdata)
            else:
                self.comb += ports[0].wdata.connect(port.wdata)
            return
        self.rr = rr = RoundRobin(n, SP_CE)
        self.cmd = cmd = stream.Buffer(cmd_description(port.address_width), pipe_valid=True, pipe_ready=True)
        self.owner = owner = stream.SyncFIFO([("id", len(rr.grant))], ids)
        valid = Array(p.cmd.valid for p in ports)[rr.grant]
        taken = Signal()
        self.comb += [
            rr.request.eq(Cat(*[p.cmd.valid for p in ports])),
            cmd.sink.valid.eq(valid & owner.sink.ready),
            cmd.sink.we.eq(Array(p.cmd.we for p in ports)[rr.grant]),
            cmd.sink.addr.eq(Array(p.cmd.addr for p in ports)[rr.grant]),
            cmd.sink.last.eq(Array(p.cmd.last for p in ports)[rr.grant]),
            taken.eq(cmd.sink.valid & cmd.sink.ready),
            owner.sink.valid.eq(taken),
            owner.sink.id.eq(rr.grant),
            # on to the next engine asking after a command, or when this one asks for nothing
            rr.ce.eq(taken | ~valid),
            cmd.source.connect(port.cmd),
        ]
        for i, p in enumerate(ports):
            self.comb += p.cmd.ready.eq((rr.grant == i) & cmd.sink.ready & owner.sink.ready)
        if port.mode == "read":
            # a reader takes its data whenever it comes: it reserved the room before its command
            rvalid, rdata, rid = Signal(), Signal(port.data_width), Signal(len(rr.grant))
            self.sync += [rvalid.eq(port.rdata.valid), rdata.eq(port.rdata.data), rid.eq(owner.source.id)]
            self.comb += [port.rdata.ready.eq(1), owner.source.ready.eq(port.rdata.valid)]
            for i, p in enumerate(ports):
                self.comb += [p.rdata.valid.eq(rvalid & (rid == i)), p.rdata.data.eq(rdata)]
        else:
            # the crossbar asks for a command's data when it writes it: a writer holds it from its command on,
            # and the next word waits in a register (the mux is not on the path into the memory's clock)
            self.wdata = wdata = stream.PipeValid(wdata_description(port.data_width) + [("id", len(rr.grant))])
            head = owner.source.id
            self.comb += [
                wdata.sink.valid.eq(owner.source.valid & Array(p.wdata.valid for p in ports)[head]),
                wdata.sink.data.eq(Array(p.wdata.data for p in ports)[head]),
                wdata.sink.we.eq(Array(p.wdata.we for p in ports)[head]),
                wdata.sink.id.eq(head),
                owner.source.ready.eq(wdata.sink.valid & wdata.sink.ready),
                wdata.source.connect(port.wdata, omit={"id"}),
            ]
            gone = Signal()
            self.comb += gone.eq(port.wdata.valid & port.wdata.ready)
            for i, p in enumerate(ports):
                self.comb += p.wdata.ready.eq(owner.source.valid & (head == i) & wdata.sink.ready)
                if hasattr(p, "writing"):
                    # commands taken whose word the memory has not had yet
                    left = Signal(max=ids + 3)
                    up, down = taken & (rr.grant == i), gone & (wdata.source.id == i)
                    self.sync += If(up & ~down, left.eq(left + 1)).Elif(down & ~up, left.eq(left - 1))
                    self.comb += p.writing.eq(left != 0)


class Hold(LiteXModule):
    """Sink: the latest word as a level, for the CPU (hwstream_peek_*; numbered like the state of
    a named state, gen_manifest.py). Always ready; 0 from each start until the first word."""
    def __init__(self, soc, enable, name):
        self.sink = stream.Endpoint([("data", 32)])
        self.state = Signal(32)
        was_enabled = Signal()
        self.comb += self.sink.ready.eq(1)
        self.sync += [
            was_enabled.eq(enable),
            If(enable & ~was_enabled, self.state.eq(0),
            ).Elif(self.sink.valid, self.state.eq(self.sink.data)),
        ]


# definstance block name -> constructor(soc, enable, *args)
BLOCKS = {
    "ticks": Ticks,
    "hold": Hold,
    "run": Discard,
}

PERIPHERALS = {}
