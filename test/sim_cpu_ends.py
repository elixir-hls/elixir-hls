#!/usr/bin/env python3
"""An instance's CPU ends in simulation (Migen), no FPGA: words to and from a memory model, what
gathers before a read, waiting and dropping, what a transfer's end does to the words around it.
usage: test/sim_cpu_ends.py  (with LiteX importable; EHLS_DEVICE unset)"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "priv", "backend", "litex"))

from litedram.common import LiteDRAMNativePort
from migen import Module, Signal, passive, run_simulation

from hls_litex_blocks import CPUIn, CPUOut, ElementsToWords, WordsToElements


class Memory:
    """A native port's other side: every command taken, some clocks of delay on the read data."""
    def __init__(self, port, words=None):
        self.port, self.words = port, words or {}

    @passive
    def serve(self):
        port = self.port
        reads, writes = [], []
        yield port.cmd.ready.eq(1)
        yield port.wdata.ready.eq(1)
        while True:
            if (yield port.cmd.valid):
                addr = yield port.cmd.addr
                (writes if (yield port.cmd.we) else reads).append(addr)
            if writes and (yield port.wdata.valid):
                self.words[writes.pop(0)] = yield port.wdata.data
            valid = len(reads) > 0
            yield port.rdata.valid.eq(valid)
            if valid:
                yield port.rdata.data.eq(self.words.get(reads[0], 0))
            yield
            if valid and (yield port.rdata.ready):
                reads.pop(0)


def transfer(end, base, words):
    yield end._enable.storage.eq(0)
    yield
    yield end._base.storage.eq(base * 4)
    yield end._length.storage.eq(words * 4)
    yield end._enable.storage.eq(1)
    yield


def wait_finished(end, limit=2000):
    for _ in range(limit):
        if (yield end.finished.status):
            return True
        yield
    return False


@passive
def feeder(sink, values, count_taken):
    """Offers values[i] until taken."""
    for v in values:
        yield sink.valid.eq(1)
        yield sink.data.eq(v)
        yield
        while not (yield sink.ready):
            yield
        count_taken.append(v)
    yield sink.valid.eq(0)


def run(dut, *gens):
    run_simulation(dut, list(gens))


def check(what, cond, info=""):
    print(("ok  " if cond else "FAIL") + f" {what} {info}")
    if not cond:
        sys.exit(1)


# ---- out, no buffer, overflow: :wait: nothing lost between requests, nothing written past the length
port = LiteDRAMNativePort("both", 24, 32)
dut = CPUOut(port)
mem = Memory(port)
taken = []


def wait_bench():
    yield from transfer(dut, 100, 4)
    check("the first transfer ends", (yield from wait_finished(dut)))
    for _ in range(40):
        yield
    first = len(taken)
    yield from transfer(dut, 200, 4)
    check("the second transfer ends", (yield from wait_finished(dut)))
    for _ in range(40):
        yield
    got = [mem.words.get(100 + i) for i in range(4)] + [mem.words.get(200 + i) for i in range(4)]
    check("wait: the words go on across requests", got == list(range(1, 9)), got)
    check("wait: the stream stands still after a request", len(taken) <= 9 and first <= 5, (first, len(taken)))
    check("wait: nothing past the length", 104 not in mem.words and 204 not in mem.words)


run(dut, mem.serve(), feeder(dut.sink, range(1, 100), taken), wait_bench())

# ---- out, overflow: :drop: words go on being taken, lost between requests, none lost in one
port = LiteDRAMNativePort("both", 24, 32)
dut = CPUOut(port, drop=True)
mem = Memory(port)
taken = []


def drop_bench():
    for _ in range(50):
        yield
    check("drop: the stream goes on with nobody reading", len(taken) >= 49, len(taken))
    yield from transfer(dut, 0, 8)
    check("drop: the transfer ends", (yield from wait_finished(dut)))
    for _ in range(10):
        yield
    got = [mem.words.get(i) for i in range(8)]
    check("drop: a transfer has consecutive words", got == list(range(got[0], got[0] + 8)), got)
    check("drop: the stream goes on after it", len(taken) > got[7] + 5, (got[7], len(taken)))


run(dut, mem.serve(), feeder(dut.sink, range(0, 1000), taken), drop_bench())

# ---- buffer, :wait: words gather from reset up to its size, oldest first, then the stream waits
port = LiteDRAMNativePort("both", 24, 32)
dut = CPUOut(port, buffer=16)
mem = Memory(port)
taken = []


def buffer_bench():
    for _ in range(100):
        yield
    check("buffer: gathers its size, then the stream waits", 16 <= len(taken) <= 18, len(taken))
    yield from transfer(dut, 0, 24)
    check("buffer: the transfer ends", (yield from wait_finished(dut)))
    got = [mem.words.get(i) for i in range(24)]
    check("buffer: the oldest first, nothing lost", got == list(range(24)), got)


run(dut, mem.serve(), feeder(dut.sink, range(0, 1000), taken), buffer_bench())

# ---- buffer, :drop: when full new words are lost, the oldest stay; a reset empties it
port = LiteDRAMNativePort("both", 24, 32)
dut = CPUOut(port, buffer=8, drop=True)
mem = Memory(port)
taken = []


def buffer_drop_bench():
    for _ in range(40):
        yield
    check("buffer + drop: the stream goes on", len(taken) >= 39, len(taken))
    yield from transfer(dut, 0, 4)
    check("buffer + drop: the transfer ends", (yield from wait_finished(dut)))
    got = [mem.words.get(i) for i in range(4)]
    check("buffer + drop: the oldest stay", got == [0, 1, 2, 3], got)
    yield dut.reset.eq(1)
    yield
    yield
    check("a reset empties the buffer", not (yield dut.buffer.source.valid))
    yield dut.reset.eq(0)


run(dut, mem.serve(), feeder(dut.sink, range(0, 1000), taken), buffer_drop_bench())

# ---- in: all words in order; finished only when the last has left, however slowly it is taken
port = LiteDRAMNativePort("both", 24, 32)
dut = CPUIn(port)
mem = Memory(port, {50 + i: 1000 + i for i in range(20)})
got = []
length = [20]


@passive
def slow_reader():
    while True:
        yield dut.source.ready.eq(1)
        yield
        if (yield dut.source.valid):
            got.append((yield dut.source.data))
        yield dut.source.ready.eq(0)
        for _ in range(3):
            if (yield dut.finished.status) and len(got) < length[0]:
                check("in: finished before the last word left", False, len(got))
            yield


def in_bench():
    check("in: nothing before it is asked", not (yield dut.source.valid))
    yield from transfer(dut, 50, 20)
    check("in: finished", (yield from wait_finished(dut, 3000)))
    check("in: every word, in order", got == [1000 + i for i in range(20)], got)
    # disabled and asked again: from clean
    yield from transfer(dut, 55, 2)
    length[0] = 2
    got.clear()
    check("in: finished is cleared by the next transfer", not (yield dut.finished.status))
    check("in: finished again", (yield from wait_finished(dut, 3000)))
    for _ in range(8):
        yield
    check("in: the next transfer's words", got == [1005, 1006], got)


run(dut, mem.serve(), slow_reader(), in_bench())
# ---- packed elements at the CPU
def transfer_bytes(end, base, size):
    """As the driver: the size rounded up to words, and the bytes the last word does not use."""
    yield end._enable.storage.eq(0)
    yield
    yield end._base.storage.eq(base * 4)
    yield end._length.storage.eq(((size + 3) & ~3) | (-size & 3))
    yield end._enable.storage.eq(1)
    yield


def feed(sink, values):
    for v in values:
        yield sink.valid.eq(1)
        yield sink.data.eq(v)
        yield
        while not (yield sink.ready):
            yield
    yield sink.valid.eq(0)


def le(words):
    return b"".join(w.to_bytes(4, "little") for w in words)


def words_of(data):
    data += bytes(-len(data) % 4)
    return [int.from_bytes(data[i:i + 4], "little") for i in range(0, len(data), 4)]


@passive
def collect(source, got, every=1):
    n = 0
    while True:
        yield source.ready.eq(n % every == 0)
        yield
        if (yield source.valid) and (yield source.ready):
            got.append((yield source.data))
        n += 1


for n, every in [(1, 1), (2, 2), (3, 1), (5, 3), (8, 1), (11, 2)]:
    elements = [int.from_bytes(bytes((10 * i + j) & 255 for j in range(n)), "little") for i in range(1, 8)]
    packed = b"".join(e.to_bytes(n, "little") for e in elements)
    expected = words_of(packed)

    # words to elements: one transfer, the bytes after its last element not data
    dut = WordsToElements(n)
    got = []

    def give(dut=dut, packed=packed, elements=elements, got=got, n=n):
        pad = -len(packed) % 4
        yield dut.pad.eq(pad)
        words = words_of(packed)
        # bytes that are not data must not reach an element
        words[-1] |= int.from_bytes(b"\xff" * pad, "little") << (8 * (4 - pad)) if pad else 0
        for i, w in enumerate(words):
            yield dut.sink.valid.eq(1)
            yield dut.sink.data.eq(w)
            yield dut.sink.last.eq(i == len(words) - 1)
            yield
            while not (yield dut.sink.ready):
                yield
        yield dut.sink.valid.eq(0)
        yield dut.sink.last.eq(0)
        for _ in range(4 * len(elements) * max(n, 4)):
            yield
        check(f"words to elements of {n} bytes", got == elements, got)

    run(dut, collect(dut.source, got, every), give())

    # elements to words: a transfer takes exactly its elements
    dut = ElementsToWords(n)
    got = []

    def take(dut=dut, elements=elements, got=got, n=n, expected=expected):
        yield dut.size.eq(len(elements[:3]) * n)
        yield dut.start.eq(1)
        yield
        yield dut.start.eq(0)
        # more offered than asked for
        yield dut.sink.data.eq(elements[0])
        yield dut.sink.valid.eq(1)
        i = 0
        for _ in range(40 * max(n, 4)):
            yield
            if (yield dut.sink.valid) and (yield dut.sink.ready):
                i += 1
            yield dut.sink.data.eq(elements[min(i, len(elements) - 1)])
        yield dut.sink.valid.eq(0)
        first = words_of(b"".join(e.to_bytes(n, "little") for e in elements[:3]))
        check(f"elements of {n} bytes to words, a part of the last word zeros", got == first, [hex(g) for g in got])
        check(f"  no more elements taken than asked for ({n} bytes)", i == 3, i)
        # the next transfer begins with the element after them
        del got[:]
        yield dut.size.eq(len(elements[3:]) * n)
        yield dut.start.eq(1)
        yield
        yield dut.start.eq(0)
        yield from feed(dut.sink, elements[3:])
        for _ in range(20):
            yield
        rest = words_of(b"".join(e.to_bytes(n, "little") for e in elements[3:]))
        check(f"  the next transfer goes on ({n} bytes)", got == rest, [hex(g) for g in got])

    run(dut, collect(dut.source, got, every), take())


# ---- u8 and tuples through the DMA ends, sizes not whole words
def out_end(n, buffer=0, drop=False):
    port = LiteDRAMNativePort("both", 24, 32)
    return CPUOut(port, n=n, buffer=buffer, drop=drop), port


dut, port = out_end(1)
mem = Memory(port)


@passive
def u8_stream():
    # more than the first transfer asks for: the rest waits for the next
    yield from feed(dut.sink, [1, 2, 3, 4, 5, 6, 7])


def u8_out():
    yield from transfer_bytes(dut, 0x10, 5)
    ok = yield from wait_finished(dut)
    check("out, u8: 5 of them", ok)
    check("  the words", [mem.words.get(0x10), mem.words.get(0x11), mem.words.get(0x12, "none")] ==
          [0x04030201, 0x05, "none"], mem.words)
    yield from transfer_bytes(dut, 0x20, 2)
    ok = yield from wait_finished(dut)
    check("  the next ones", ok and mem.words.get(0x20) == 0x0706, mem.words)
    # cancelled with a part of a word gathered: the next transfer starts on a whole element
    yield from transfer_bytes(dut, 0x30, 8)
    yield from feed(dut.sink, [8])
    yield dut._enable.storage.eq(0)
    for _ in range(8):
        yield
    yield from transfer_bytes(dut, 0x40, 1)
    yield from feed(dut.sink, [9])
    ok = yield from wait_finished(dut)
    check("out, u8: nothing of a cancelled word stays", ok and mem.words.get(0x40) == 9, mem.words)


run(dut, mem.serve(), u8_stream(), u8_out())

dut, port = out_end(4 + 2, buffer=4)
mem = Memory(port)


def tuple_buffer():
    # four elements of 6 bytes gather before the CPU asks
    values = [(i + 1) * 0x010101010101 for i in range(4)]
    yield from feed(dut.sink, values)
    for _ in range(4):
        yield
    yield from transfer_bytes(dut, 0, 24)
    ok = yield from wait_finished(dut)
    data = le([mem.words.get(i, 0) for i in range(6)])
    check("buffer: counts elements, gathered", ok and data == b"".join(v.to_bytes(6, "little") for v in values), data.hex())


run(dut, mem.serve(), tuple_buffer())

# the input: 5 bytes of u8, then 3 elements of 3 bytes, across words
port = LiteDRAMNativePort("both", 24, 32)
mem = Memory(port, {0: 0x04030201, 1: 0xAABBCC05})
dut = CPUIn(port, n=1)
got = []


def u8_in():
    yield from transfer_bytes(dut, 0, 5)
    ok = yield from wait_finished(dut)
    for _ in range(16):
        yield
    yield dut._enable.storage.eq(0)
    yield
    check("in, u8: the elements, not the rest of the word", ok and got == [1, 2, 3, 4, 5], got)
    # the next transfer starts on a whole element
    del got[:]
    yield from transfer_bytes(dut, 0, 3)
    ok = yield from wait_finished(dut)
    for _ in range(16):
        yield
    check("in, u8: the next transfer", ok and got == [1, 2, 3], got)


run(dut, mem.serve(), collect(dut.source, got), u8_in())

port = LiteDRAMNativePort("both", 24, 32)
packed = bytes(range(1, 10))
mem = Memory(port, dict(enumerate(words_of(packed))))
dut = CPUIn(port, n=3)
got = []


def tuple_in():
    yield from transfer_bytes(dut, 0, 9)
    ok = yield from wait_finished(dut)
    for _ in range(16):
        yield
    # the elements of the last word go on after finished and the DMA's disable
    yield dut._enable.storage.eq(0)
    for _ in range(4):
        yield
    check("in, 3 bytes: across words", ok and got == [0x030201, 0x060504, 0x090807], [hex(g) for g in got])


run(dut, mem.serve(), collect(dut.source, got), tuple_in())

# a whole instance's ends: only the kernel a stand-in, the same values out as in
import hls_litex  # noqa: E402


class StandIn:
    pass


def instance_bench(type_in, type_out, packed):
    from litex.gen import LiteXModule
    from litex.soc.interconnect import stream

    class Kernel(LiteXModule):
        def __init__(self, platform, k, enable, agent=None):
            self.lane = W = k.get("lane", 32)
            self.sink = stream.Endpoint([("data", W * k["in_words"])])
            self.source = stream.Endpoint([("data", W * k["out_words"])])
            self.engaged = Signal()
            self.comb += self.sink.connect(self.source)

    real, hls_litex.KernelStage = hls_litex.KernelStage, Kernel
    ports = []
    soc = StandIn()
    soc.platform = None
    soc.sdram = StandIn()
    soc.sdram.crossbar = StandIn()

    def port(mode):
        ports.append(LiteDRAMNativePort("both", 24, 32))
        return ports[-1]

    wide = any(bits > 32 for bits, _ in hls_litex._fields(type_in) + hls_litex._fields(type_out))
    k = {"kernel": "k", "arg": type_in, "ret": type_out, "init": [], "lane": 64 if wide else 32,
         "in_words": len(hls_litex._fields(type_in)), "out_words": len(hls_litex._fields(type_out))}
    p = {"stages": [{"kernel": "k"}], "links": [], "inputs": [{"name": "x", "type": type_in, "to": 0, "port": 0}],
         "output_type": type_out, "output": {"buffer": 0, "overflow": "wait"},
         "ends": [{"name": "x", "dir": "in", "index": 0}, {"name": "out", "dir": "out", "index": 1}]}
    pipe = hls_litex.Pipeline(soc, p, {"k": k}, Signal(reset=1), port)
    hls_litex.KernelStage = real
    # the ends are HWStream's submodules in a SoC
    ein, eout = pipe.ends[0][1], pipe.ends[1][1]
    pipe.submodules += [ein, eout]
    mem_in, mem_out = Memory(ports[0], dict(enumerate(words_of(packed)))), Memory(ports[1])

    def bench():
        yield from transfer_bytes(eout, 0, len(packed))
        yield from transfer_bytes(ein, 0, len(packed))
        ok = yield from wait_finished(eout, 4000)
        data = le([mem_out.words.get(i, 0) for i in range(len(words_of(packed)))])[:len(packed)]
        check(f"instance {type_in}: the same bytes out", ok and data == packed, data.hex())

    run(pipe, mem_in.serve(), mem_out.serve(), bench())


instance_bench("u8", "u8", bytes([1, 2, 255, 4, 5]))
instance_bench("s16", "s16", b"\x01\x00\xff\xff\x03\x80")
instance_bench(["u8", "s16"], ["u8", "s16"], b"\x01\x02\x00\xff\xfe\xff\x07\x00\x80")
s32s = [-2, 5, 131071, -524288]
instance_bench(["s18", "s20"], ["s18", "s20"], b"".join(v.to_bytes(4, "little", signed=True) for v in s32s))
instance_bench("u32", "u32", bytes(range(12)))


# ---- several ends on one port to the memory (SharedPort)
import random  # noqa: E402

from hls_litex_blocks import SharedPort  # noqa: E402


class Crossbar:
    """A shared port's other side, as LiteDRAM's crossbar: a command is taken when ready (not always),
    the data read comes some clocks later in the commands' order, and the data to write is asked for
    by a strobe of wdata.ready, some clocks after its command, and must be there."""
    def __init__(self, port, words=None, seed=1, read=(3, 8), write=(1, 6), ready=0.7):
        self.port, self.words = port, words if words is not None else {}
        self.rand = random.Random(seed)
        self.read, self.write, self.ready = read, write, ready
        self.missing = 0

    @passive
    def serve(self):
        port, rand = self.port, self.rand
        reads, writes, t = [], [], 0
        while True:
            ready = rand.random() < self.ready
            yield port.cmd.ready.eq(ready)
            strobe = bool(writes) and writes[0][0] <= t
            yield port.wdata.ready.eq(strobe)
            due = bool(reads) and reads[0][0] <= t
            yield port.rdata.valid.eq(due)
            if due:
                yield port.rdata.data.eq(self.words.get(reads[0][1], 0))
            yield
            if ready and (yield port.cmd.valid):
                addr = yield port.cmd.addr
                if (yield port.cmd.we):
                    writes.append((t + rand.randint(*self.write), addr))
                else:
                    reads.append((max([t + rand.randint(*self.read)] + [r for r, _ in reads[-1:]]), addr))
            if strobe:
                if (yield port.wdata.valid):
                    self.words[writes[0][1]] = yield port.wdata.data
                else:
                    self.missing += 1
                writes.pop(0)
            if due:
                reads.pop(0)
            t += 1


def shared(mode, n, end):
    """n ends on one shared port, built first as in HWStream: the port asks them whether words are on their way."""
    port = LiteDRAMNativePort(mode, 24, 32)
    ports = [LiteDRAMNativePort(mode, 24, 32) for _ in range(n)]
    ends = [end(p) for p in ports]
    return port, ends, SharedPort(port, ports)


# inputs: one end's words are not taken; the others still get all of theirs, then it gets its own
port, ins, arb = shared("read", 3, CPUIn)
dut = Module()
dut.submodules += [arb] + ins
mem = Crossbar(port, {i: 0x1000 + i for i in range(300)})
gots = [[], [], []]
held = [True]


@passive
def take(i):
    while True:
        yield ins[i].source.ready.eq(not (i == 0 and held[0]))
        yield
        if (yield ins[i].source.valid) and (yield ins[i].source.ready):
            gots[i].append((yield ins[i].source.data))


def shared_in():
    for i in (0, 1, 2):
        yield from transfer(ins[i], 100 * i, 40)
    ok = []
    for i in (1, 2):
        ok.append((yield from wait_finished(ins[i], 3000)))
    check("shared, in: an end not taken holds up no other", all(ok) and not (yield ins[0].finished.status))
    check("  their words, in order", gots[1] == [0x1000 + 100 + j for j in range(40)] and
          gots[2] == [0x1000 + 200 + j for j in range(40)], (gots[1][:4], gots[2][:4]))
    held[0] = False
    check("  the one held finishes once taken", (yield from wait_finished(ins[0], 3000)))
    check("  with its words", gots[0] == [0x1000 + j for j in range(40)], gots[0][:8])


run(dut, mem.serve(), take(0), take(1), take(2), shared_in())

# outputs: one end's stream gives nothing; the others still write all theirs, then it does
port, outs, arb = shared("write", 3, CPUOut)
dut = Module()
dut.submodules += [arb] + outs
mem = Crossbar(port, seed=2)
late = [False]


@passive
def give(i):
    v = 0
    while True:
        on = i != 0 or late[0]
        yield outs[i].sink.valid.eq(on)
        yield outs[i].sink.data.eq(0x100 * (i + 1) + v)
        yield
        if on and (yield outs[i].sink.ready):
            v += 1


def shared_out():
    for i in (0, 1, 2):
        yield from transfer(outs[i], 64 * i, 48)
    ok = []
    for i in (1, 2):
        ok.append((yield from wait_finished(outs[i], 4000)))
    check("shared, out: an end with nothing holds up no other", all(ok) and not (yield outs[0].finished.status))
    late[0] = True
    check("  the one with nothing finishes once it has", (yield from wait_finished(outs[0], 4000)))
    for _ in range(20):
        yield
    got = [[mem.words.get(64 * i + j) for j in range(48)] for i in range(3)]
    check("  every word where it belongs", got == [[0x100 * (i + 1) + j for j in range(48)] for i in range(3)],
          [g[:4] for g in got])
    check("  the data there each time the memory asked", mem.missing == 0, mem.missing)


run(dut, mem.serve(), give(0), give(1), give(2), shared_out())


# taking turns: two long inputs move together, neither waits for the other to finish
port, ins, arb = shared("read", 2, CPUIn)
dut = Module()
dut.submodules += [arb] + ins
mem = Crossbar(port, seed=3)
gots = [[], []]


def turns():
    for i in (0, 1):
        yield from transfer(ins[i], 0, 200)
    for _ in range(300):
        yield
    a, b = len(gots[0]), len(gots[1])
    check("shared: two ends take turns", 40 < a < 160 and abs(a - b) <= 10, (a, b))


run(dut, mem.serve(), take(0), take(1), turns())


def shared_instances(what, plans, read=(3, 8), write=(1, 6), ready=0.7, full=False):
    """Instances with both ends (the kernel a stand-in: the same values out as in), all on one port to
    read and one to write, each doing its plan of transfers (sizes in elements) at the same time as the
    others. With `full`, the owner FIFOs must have been full at some point."""
    from litex.gen import LiteXModule
    from litex.soc.interconnect import stream

    class Kernel(LiteXModule):
        def __init__(self, platform, k, enable, agent=None):
            self.lane = W = k["lane"]
            self.sink = stream.Endpoint([("data", W * k["in_words"])])
            self.source = stream.Endpoint([("data", W * k["out_words"])])
            self.engaged = Signal()
            self.comb += self.sink.connect(self.source)

    real, hls_litex.KernelStage = hls_litex.KernelStage, Kernel
    wanted = {"read": [], "write": []}

    def port(mode):
        wanted[mode].append(LiteDRAMNativePort(mode, 24, 32))
        return wanted[mode][-1]

    soc = StandIn()
    soc.platform = None
    dut = Module()
    pipes = []
    for i, (t, _) in enumerate(plans):
        wide = any(bits > 32 for bits, _ in hls_litex._fields(t))
        k = {"kernel": "k", "arg": t, "ret": t, "init": [], "lane": 64 if wide else 32,
             "in_words": len(hls_litex._fields(t)), "out_words": len(hls_litex._fields(t))}
        p = {"stages": [{"kernel": "k"}], "links": [], "inputs": [{"name": "x", "type": t, "to": 0, "port": 0}],
             "output_type": t, "output": {"buffer": 0, "overflow": "wait"},
             "ends": [{"name": "x", "dir": "in", "index": 2 * i}, {"name": "out", "dir": "out", "index": 2 * i + 1}]}
        pipe = hls_litex.Pipeline(soc, p, {"k": k}, Signal(reset=1), port)
        pipe.submodules += [e for _, e in pipe.ends]
        dut.submodules += pipe
        pipes.append(pipe)
    hls_litex.KernelStage = real
    rport, wport = LiteDRAMNativePort("read", 24, 32), LiteDRAMNativePort("write", 24, 32)
    arbs = [SharedPort(rport, wanted["read"]), SharedPort(wport, wanted["write"])]
    dut.submodules += arbs
    words = {}
    mems = [Crossbar(rport, words, 11, read, write, ready), Crossbar(wport, words, 12, read, write, ready)]
    rand = random.Random(5)
    done, top, clock = {}, [0, 0], [0]

    def size(t):
        return sum(hls_litex._packed(bits) for bits, _ in hls_litex._fields(t))

    def element(t):
        """An element's bytes as the CPU has them: each value in its type's bits, extended to its size."""
        out = b""
        for bits, signed in hls_litex._fields(t):
            n = hls_litex._packed(bits)
            v = rand.randrange(1 << bits)
            if signed and v >> (bits - 1):
                v -= 1 << bits
            out += v.to_bytes(n, "little", signed=signed)
        return out

    def plan(i, t, counts):
        ein, eout = pipes[i].ends[0][1], pipes[i].ends[1][1]
        base_in, base_out = 0x10000 * (2 * i + 1), 0x10000 * (2 * i + 2)
        for j, count in enumerate(counts):
            data = b"".join(element(t) for _ in range(count))
            for w, v in enumerate(words_of(data)):
                words[base_in + w] = v
            yield from transfer_bytes(eout, base_out, len(data))
            yield from transfer_bytes(ein, base_in, len(data))
            ok = yield from wait_finished(eout, 40 * len(data) + 2000)
            # read when finished rises, as the CPU does
            out = le([words.get(base_out + w, 0) for w in range(len(words_of(data)))])[:len(data)]
            check(f"{what}: {t}, {count} elements, transfer {j}", ok and out == data, out[:12].hex())
        done[i] = clock[0]

    @passive
    def watch():
        while True:
            for n, a in enumerate(arbs):
                top[n] = max(top[n], (yield a.owner.level))
            clock[0] += 1
            yield

    return dut, mems, watch, done, top, plan


def run_plans(what, plans, **kw):
    dut, mems, watch, done, top, plan = shared_instances(what, plans, **kw)
    gens = [plan(i, t, counts) for i, (t, counts) in enumerate(plans)]
    run(dut, mems[0].serve(), mems[1].serve(), watch(), *gens)
    check(f"{what}: the data there each time the memory asked", mems[1].missing == 0, mems[1].missing)
    return done, top


# elements of 1, 2, 3, 4, 8 and 9 bytes, sizes not whole words; one long transfer while the others are short
plans = [("u8", [1, 3, 5, 9, 2, 7]), ("s16", [1, 3, 2, 5]), (["u8", "s16"], [1, 2, 3, 5, 7]), ("u32", [300]),
         ("s48", [1, 3, 2]), (["u8", "s48"], [1, 2])]
done, top = run_plans("shared, packed", plans)
check("  the short ones finish while the long one runs", all(done[i] < done[3] for i in (0, 1, 2, 4, 5)), done)

# the memory slow to answer: the owner FIFOs fill up, and the commands wait until there is room
plans = [("u32", [200]), ("u8", [301]), (["u8", "s16"], [101]), ("s16", [151])]
done, top = run_plans("shared, slow memory", plans, read=(20, 40), write=(20, 40), ready=0.95)
check("  the owner FIFOs were full", top == [16, 16], top)

# values over 32 bits: 8 bytes each, through 64-bit ports
s64s = [-2, 0x7FFF_FFFF_FFFF, -0x8000_0000_0000, 5]
instance_bench("s48", "s48", b"".join(v.to_bytes(8, "little", signed=True) for v in s64s))
instance_bench(["u8", "s48"], ["u8", "s48"],
               b"".join(bytes([i]) + v.to_bytes(8, "little", signed=True) for i, v in enumerate(s64s)))
# the Verilog of a kernel stage as the SoC writes it: nothing Gowin refuses (an empty concatenation)
from migen.fhdl import verilog  # noqa: E402


class NoSources:
    def add_source(self, f):
        pass


for k in [{"kernel": "k", "sv": "k.sv", "state": [], "init": []},
          {"kernel": "k", "sv": "k.sv", "state": ["u32"], "init": [0], "lane": 64}]:
    m = hls_litex.Kernel(NoSources(), k)
    text = str(verilog.convert(m, ios={m.s_valid, m.s_ready, m.s_data, m.m_valid, m.m_ready, m.m_data}))
    check(f"Verilog of a kernel with {len(k['state'])} state value(s), {k.get('lane', 32)}-bit ports: no empty {{}}",
          "= {};" not in text)


# elements given one by one without DMA (f(:send, :x, value)): the DMA's elements and the pushed ones taken in
# turn, a whole element each, every one of each in its order; a full FIFO says no room
def push_bench():
    from litex.soc.interconnect import stream
    from migen import Module as M

    class End:
        def __init__(self):
            self.source = stream.Endpoint([("data", 16)])
            self.reset = Signal()

    dut = M()
    end = End()
    wr, index, data, push = Signal(), Signal(8), Signal(32), Signal()
    dut.submodules.f = f = hls_litex._FromCPU(end, [2], (wr, index, data, push))
    rnd = __import__("random").Random(9)
    dma = [0x1000 + i for i in range(60)]
    pushed = [0x2000 + i for i in range(20)]
    got, rooms = [], []

    @passive
    def feed_dma():
        for v in dma:
            yield end.source.valid.eq(1)
            yield end.source.data.eq(v)
            yield
            while not (yield end.source.ready):
                yield
        yield end.source.valid.eq(0)

    @passive
    def cpu():
        for v in pushed:
            while (yield f.room) == 0:
                rooms.append(0)
                yield
            yield wr.eq(1)
            yield index.eq(0)
            yield data.eq(v)
            yield
            yield wr.eq(0)
            yield push.eq(1)
            yield
            yield push.eq(0)
            # the push lands at this clock; the CPU reads room by CSR only after it
            yield
            for _ in range(rnd.randrange(3)):
                yield

    def take():
        for _ in range(3000):
            yield f.source.ready.eq(rnd.random() < 0.3)
            yield
            if (yield f.source.valid) and (yield f.source.ready):
                got.append((yield f.source.data) & 0xFFFF)

    run_simulation(dut, [feed_dma(), cpu(), take()])
    return got, dma, pushed, rooms


got, dma, pushed, rooms = push_bench()
check("one by one: the DMA's elements all, in order", [v for v in got if v < 0x2000] == dma)
check("one by one: the pushed elements all, in order", [v for v in got if v >= 0x2000] == pushed)
check("one by one: the FIFO said when it had no room", len(rooms) > 0, len(rooms))
print("OK")
