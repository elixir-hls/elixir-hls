"""
elixir-hls' LiteX SoC backend (EHLS.SoC.LiteX): puts the circuits of an application's
build/hw (mix ehls.compile: kernels.json, pipelines.json, packages.json, peripherals.json)
into a LiteX SoC with LiteDRAM:

    import hls_litex
    hls_litex.add_hls(soc, hw_dir, package_dirs)

adds `soc.hwstream` (CSRs hwstream_*):

  * each instance its stages linked by registered streams, running from reset, stopped by a bit of
    hwstream_pipe_enable, which holds its links and buffer empty, so that a start begins on clean data; a kernel's levels
    wired to instances of levels or pins; instances of levels (hwstream_level_*); the
    state of named stages and hold stages' words read as a whole (hwstream_peek_stage / _sel / _value).
  * an instance's ends towards the CPU, a DMA engine each (no Wishbone on the data path), the
    engines of all instances sharing one LiteDRAM crossbar port to read and one to write (SharedPort):
    hwstream_end<i>_{base,length,enable,done,finished,...}, base a byte address from the start of SDRAM; an event per end (hwstream_ev_*) on one interrupt, hwstream. A CPU
    without L2 cache and with a write-through D-cache only invalidates
    its D-cache after a transfer.
  * the block packages' blocks and peripherals (their gateware/ Python modules, found in
    package_dirs), configured with the application's options first.

The kernels are CIRCT `hlstool --dynamic-hw` modules, all instantiated: stateless ones,
`fn(i32) -> i32`, behind hls_stream_adapter.v; stateful ones, `fn(x, s..) -> (y, s'..)`,
behind hls_state_adapter.v, which keeps the state in registers (elixir-hls priv/verilog).
"""
import importlib
import json
import os
import sys
from functools import reduce
from operator import and_, or_

from migen import Array, Cat, ClockSignal, Constant, If, Instance, Mux, Replicate, ResetInserter, ResetSignal, Signal
from litex.gen import LiteXModule
from litex.soc.interconnect import stream
from litex.soc.interconnect.csr import CSRStatus, CSRStorage
from litex.soc.interconnect.csr_eventmanager import EventManager, EventSourceLevel, EventSourceProcess
from migen.genlib.roundrobin import SP_CE, RoundRobin

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)                 # the built-in blocks (hls_litex_blocks)
from hls_litex_blocks import CPUIn, CPUOut, SharedPort
from litedram.common import LiteDRAMNativePort

# the stream adapters around the kernels: elixir-hls priv/verilog
VERILOG_DIR = os.path.join(HERE, "..", "..", "verilog")


def _provider(name):
    """The Python module of a block package (EHLS.Blocks gateware/0)."""
    return importlib.import_module(name)


class Kernel(LiteXModule):
    """One kernel behind its adapter: s (in) / m (out) valid-ready-data, W bits per value (the
    kernel's ports, `lane`: 32 or 64); `restart` (a pulse) resets a stateful kernel's state to its
    initial value. `args`: one 32-bit signal per argument after the first (levels: inputs offered all the time), `state`: the
    current state, a 32-bit word per value (a state is up to 32 bits)."""
    def __init__(self, platform, k):
        ni, ny = k.get("in_words", 1), k.get("out_words", 1)    # values per element (tuples)
        W = self.lane = k.get("lane", 32)
        self.s_valid, self.s_ready, self.s_data = Signal(), Signal(), Signal(W * ni)
        self.m_valid, self.m_ready, self.m_data = Signal(), Signal(), Signal(W * ny)
        self.restart = Signal()
        self.engaged = Signal()
        ns = len(k["state"])
        # an agent's (k["shared"]): the state comes in and its next value goes out (Agent)
        self.shared = bool(k.get("shared"))
        self.state_in, self.state_next, self.state_we = Signal(max(1, W * ns)), Signal(max(1, W * ns)), Signal()
        emit = int(k.get("emit", False))
        self.args = [Signal(32, name=f"arg_{a['name']}") for a in k.get("args", [])]
        self.state = Signal(max(1, 32 * ns))
        state_lanes = Signal(max(1, W * ns))
        if ns:
            # an empty Cat would be `{}` in Verilog, which Gowin refuses
            self.comb += self.state.eq(Cat(*[state_lanes[W * i:W * i + 32] for i in range(ns)]))
        na = len(self.args)

        n = ni + ns                      # data inputs (x and the state)
        no = emit + ny + ns              # data outputs ([flag,] y and the state)
        k_in_data, k_out_data = Signal(W * n), Signal(W * no)
        k_in_valid, k_in_ready = Signal(n + 1), Signal(n + 1)          # + start token
        k_out_valid, k_out_ready = Signal(no + 1), Signal(no + 1)      # + done token
        ports = dict(i_clock=ClockSignal(), i_reset=ResetSignal())
        space = k.get("space")
        for j, sig in enumerate(self.args):
            ports.update({f"i_in{n + j}": sig, f"i_in{n + j}_valid": 1, f"o_in{n + j}_ready": Signal()})
        for i in range(n + 1):
            # after x and the state: the level arguments, the memory space (argument n + na), then the
            # start token
            p = i if i < n else n + na + (1 if space else 0)
            if i < n:
                ports[f"i_in{p}"] = k_in_data[W * i:W * (i + 1)]
            ports[f"i_in{p}_valid"] = k_in_valid[i]
            ports[f"o_in{p}_ready"] = k_in_ready[i]
        if space:
            # the kernel's tables / memories (scripts/gen_space.py), restarted with the state
            a, aw = space["arg"], space["aw"]
            # the CPU's read of a memory word (the SoC's mem_addr / mem_data, for a named state)
            self.mem_addr, self.mem_req, self.mem_q, self.mem_done = Signal(aw), Signal(), Signal(32), Signal()
            sp = dict(i_clk=ClockSignal(), i_rst=ResetSignal(), i_restart=self.restart,
                      i_cpu_addr=self.mem_addr, i_cpu_req=self.mem_req, o_cpu_q=self.mem_q, o_cpu_done=self.mem_done)
            for j in range(space["nld"]):
                addr, av, ar = Signal(aw), Signal(), Signal()
                data, dv, dr = Signal(32), Signal(), Signal()
                ports.update({f"o_in{a}_ld{j}_addr": addr, f"o_in{a}_ld{j}_addr_valid": av,
                              f"i_in{a}_ld{j}_addr_ready": ar, f"i_in{a}_ld{j}_data": data,
                              f"i_in{a}_ld{j}_data_valid": dv, f"o_in{a}_ld{j}_data_ready": dr})
                sp.update({f"i_ld{j}_addr": addr, f"i_ld{j}_addr_valid": av, f"o_ld{j}_addr_ready": ar,
                           f"o_ld{j}_data": data, f"o_ld{j}_data_valid": dv, f"i_ld{j}_data_ready": dr})
            for j in range(space["nst"]):
                st, sv, sr, dv, dr = Signal(aw + 32), Signal(), Signal(), Signal(), Signal()
                ports.update({f"o_in{a}_st{j}": st, f"o_in{a}_st{j}_valid": sv, f"i_in{a}_st{j}_ready": sr,
                              f"i_in{a}_st{j}_done_valid": dv, f"o_in{a}_st{j}_done_ready": dr})
                sp.update({f"i_st{j}": st, f"i_st{j}_valid": sv, f"o_st{j}_ready": sr,
                           f"o_st{j}_done_valid": dv, f"i_st{j}_done_ready": dr})
            self.specials += Instance(space["module"], **sp)
            platform.add_source(space["file"])
        for i in range(no + 1):
            if i < no:
                ports[f"o_out{i}"] = k_out_data[W * i:W * (i + 1)]
            ports[f"o_out{i}_valid"] = k_out_valid[i]
            ports[f"i_out{i}_ready"] = k_out_ready[i]
        self.specials += Instance(k["kernel"], **ports)
        platform.add_source(k["sv"])

        stream = dict(
            i_clk=ClockSignal(), i_rst=ResetSignal(), o_engaged=self.engaged,
            i_s_valid=self.s_valid, o_s_ready=self.s_ready, i_s_data=self.s_data,
            o_m_valid=self.m_valid, i_m_ready=self.m_ready, o_m_data=self.m_data,
        )
        if ns == 0:
            self.specials += Instance("hls_stream_adapter", p_IW=W, p_OW=W, **stream,
                o_k_in0=k_in_data, o_k_in0_valid=k_in_valid[0], i_k_in0_ready=k_in_ready[0],
                o_k_in1_valid=k_in_valid[1], i_k_in1_ready=k_in_ready[1],
                i_k_out0=k_out_data, i_k_out0_valid=k_out_valid[0], o_k_out0_ready=k_out_ready[0],
                i_k_out1_valid=k_out_valid[1], o_k_out1_ready=k_out_ready[1],
            )
        else:
            init = 0
            for i, w in enumerate(k["init"]):
                init |= w << (W * i)
            self.specials += Instance("hls_state_adapter",
                p_W=W, p_NS=ns, p_INIT=Constant(init, W * ns), p_EMIT=emit, p_NI=ni, p_NY=ny,
                p_SHARED=int(self.shared),
                i_restart=self.restart, **stream,
                o_k_in_data=k_in_data, o_k_in_valid=k_in_valid, i_k_in_ready=k_in_ready,
                i_k_out_data=k_out_data, i_k_out_valid=k_out_valid, o_k_out_ready=k_out_ready,
                o_state_out=state_lanes,
                i_state_in=self.state_in, o_state_we=self.state_we, o_state_next=self.state_next,
            )


class KernelStage(LiteXModule):
    """A defhls kernel as a pipeline stage: sink / source endpoints; restarted (a stateful
    kernel's state reset) when the instance is started. While stopped it takes no new word, but
    finishes a frame it has begun, its outputs dropped: otherwise a frame left half-way would come
    out after the start, from the old state."""
    def __init__(self, platform, k, enable, agent=None):
        self.lane = W = k.get("lane", 32)        # bits per value at its ends
        self.sink = stream.Endpoint([("data", W * k.get("in_words", 1))])
        self.source = stream.Endpoint([("data", W * k.get("out_words", 1))])
        self.kernel = kernel = Kernel(platform, {**k, "shared": agent is not None})
        self.args, self.state, self.engaged = kernel.args, kernel.state, kernel.engaged
        enable_d = Signal()
        self.sync += enable_d.eq(enable)
        taking = enable | kernel.engaged
        # an agent's function takes an element only when the agent lets it (one at a time)
        turn = agent.port(kernel, self.sink.valid & taking) if agent is not None else 1
        self.comb += [
            kernel.restart.eq(enable & ~enable_d),
            kernel.s_valid.eq(self.sink.valid & taking & turn), self.sink.ready.eq(kernel.s_ready & taking & turn),
            kernel.s_data.eq(self.sink.data),
            self.source.valid.eq(kernel.m_valid & enable), kernel.m_ready.eq(self.source.ready | ~enable),
            self.source.data.eq(kernel.m_data),
        ]


class Agent(LiteXModule):
    """One state for several functions (EHLS `{:ok, n} = EHLS.Agent.start_link(init)` and `EHLS.Agent.get_and_update(n, &f/2)` in more
    than one line): the register here, each function's adapter taking it in and giving its next value (SHARED). One
    function at a time takes an element, in turn among those that have one, so the state never changes under
    an element and each update sees the one before. Restarted with the instance."""
    def __init__(self, W, ns, init):
        self.lane = W
        self.init = 0
        for i, w in enumerate(init):
            self.init |= w << (W * i)
        self.state = Signal(max(1, W * ns), reset=self.init)
        self.ports = []

    def port(self, kernel, want):
        """The turn signal of a function's kernel that wants to take an element."""
        turn = Signal()
        self.ports.append((kernel, want, turn))
        self.comb += kernel.state_in.eq(self.state)
        return turn

    def build(self):
        n = len(self.ports)
        busy, who, last = Signal(), Signal(max=max(2, n)), Signal(max=max(2, n))
        for i, (_, _, turn) in enumerate(self.ports):
            self.comb += turn.eq(busy & (who == i))
        wants = Array(want for _, want, _ in self.ports)
        # the next turn: the first that wants one after the last that had it (round robin)
        pick = Signal(max=max(2, n))
        choice = pick.eq(last)
        for j in reversed(range(1, n + 1)):
            idx = Signal(max=max(2, 2 * n))
            self.comb += If(last + j >= n, idx.eq(last + j - n)).Else(idx.eq(last + j))
            choice = If(wants[idx], pick.eq(idx)).Else(choice)
        self.comb += choice
        kernels = [k for k, _, _ in self.ports]
        we = Array(k.state_we for k in kernels)[who]
        nxt = Array(k.state_next for k in kernels)[who]
        engaged = Array(k.engaged for k in kernels)[who]
        restart = reduce(or_, [k.restart for k in kernels], 0)
        self.sync += [
            If(busy & we, self.state.eq(nxt), busy.eq(0), last.eq(who)
            # the one that had the turn has nothing any more (its instance stopped): the turn goes on
            ).Elif(busy & ~wants[who] & ~engaged, busy.eq(0), last.eq(who)
            ).Elif(~busy & reduce(or_, [w for _, w, _ in self.ports], 0), busy.eq(1), who.eq(pick)),
            If(restart & ~busy, self.state.eq(self.init)),
        ]


def _fields(t):
    """[(bits, signed)] of a defhls type ("u16", "s18"), one per value: a tuple (a list) has several."""
    if isinstance(t, list):
        return [f for e in t for f in _fields(e)]
    return [(int(t[1:]), t[0] == "s")]


def _end_fields(t):
    """The values of an element at a CPU end; a block that says nothing, or takes any type: a word."""
    return _fields(t) if t and t != "any" else [(32, False)]


def _packed(bits):
    """The bytes of a value in a binary: the smallest of 1, 2, 4, 8 that holds it."""
    return 1 if bits <= 8 else 2 if bits <= 16 else 4 if bits <= 32 else 8


def _lane(sizes):
    """Bits per value at a CPU end's side towards the stages: 64 once a value takes 8 bytes."""
    return 64 if 8 in sizes else 32


class Zip(LiteXModule):
    """The join of zip_with (elixir-hls EHLS.Join): one element of each input, together, as one element
    {x, y}; `lane` bits per value, k0 and k1 values per input. An input waits until the other has one."""
    def __init__(self, lane, k0, k1):
        self.lane = L = lane
        self.sinks = [stream.Endpoint([("data", L * k0)]), stream.Endpoint([("data", L * k1)])]
        self.sink = self.sinks[0]
        self.source = stream.Endpoint([("data", L * (k0 + k1))])
        both = self.sinks[0].valid & self.sinks[1].valid
        self.comb += [
            self.source.valid.eq(both),
            self.source.data.eq(Cat(self.sinks[0].data, self.sinks[1].data)),
            self.sinks[0].ready.eq(both & self.source.ready),
            self.sinks[1].ready.eq(both & self.source.ready),
        ]


class Fork(LiteXModule):
    """A fork (elixir-hls: a stream bound to a variable and used n times): every element to each of n
    outputs, `lane` bits per value, k values. No buffer: it moves on once every output took the element;
    an output that took it waits for the others."""
    def __init__(self, lane, k, n):
        self.lane = L = lane
        self.sink = stream.Endpoint([("data", L * k)])
        self.sources = [stream.Endpoint([("data", L * k)]) for _ in range(n)]
        self.source = self.sources[0]
        taken = Signal(n)          # the outputs that took the element offered now
        done = [taken[i] | (src.valid & src.ready) for i, src in enumerate(self.sources)]
        all_done = reduce(and_, done)
        for i, src in enumerate(self.sources):
            self.comb += [src.valid.eq(self.sink.valid & ~taken[i]), src.data.eq(self.sink.data)]
        self.comb += self.sink.ready.eq(all_done)
        self.sync += If(self.sink.valid, If(all_done, taken.eq(0)).Else(taken.eq(Cat(*done))))


class Publisher(LiteXModule):
    """EHLS.PubSub.broadcast(topic) (elixir-hls events): each element an event of the topic, with the time it came. It never
    holds back what feeds it: a small FIFO of its own, and an event that does not fit is counted in `lost`."""
    DEPTH = 8

    def __init__(self, topic, time):
        self.topic = topic
        self.sink = stream.Endpoint([("data", 32)])
        self.fifo = fifo = stream.SyncFIFO([("value", 32), ("time", 32)], self.DEPTH)
        self.lost = Signal(32)
        self.comb += [
            self.sink.ready.eq(1),
            fifo.sink.valid.eq(self.sink.valid),
            fifo.sink.value.eq(self.sink.data),
            fifo.sink.time.eq(time),
        ]
        self.sync += If(self.sink.valid & ~fifo.sink.ready, self.lost.eq(self.lost + 1))


class LevelChanges(LiteXModule):
    """changes(k_hw(:value)) (elixir-hls): the new value each time an instance of values' result changes. A
    source that cannot wait: a change not taken yet is replaced by the next one. `level` is wired by HWStream."""
    def __init__(self):
        self.level = Signal(32)
        self.source = stream.Endpoint([("data", 32)])
        prev, started = Signal(32), Signal()
        self.sync += [
            prev.eq(self.level),
            started.eq(1),
            If(self.source.valid & self.source.ready, self.source.valid.eq(0)),
            If(started & (self.level != prev), self.source.valid.eq(1), self.source.data.eq(self.level)),
        ]


def _round_robin(m, srcs, ready):
    """Streams `srcs` taken in turn into one that is `ready`: each source's ready set; gives `pick`, a
    signal of the granted source out of one per source."""
    m.rr = rr = RoundRobin(len(srcs), SP_CE)
    m.comb += [rr.request.eq(Cat(*[s.valid for s in srcs])), rr.ce.eq(ready)]
    m.comb += [s.ready.eq(ready & (rr.grant == i)) for i, s in enumerate(srcs)]
    return lambda signals: Array(signals)[rr.grant]


class Subscriber(LiteXModule):
    """EHLS.PubSub.subscribe(topic) (elixir-hls events): a source giving the events of the topic. Each publisher of the
    topic writes into a small FIFO of this subscriber's (it never waits: what does not fit is counted in
    `lost`); the FIFOs are taken round robin, so each publisher's events come in its order."""
    DEPTH = 16

    def __init__(self, topic):
        self.topic = topic
        self.source = stream.Endpoint([("data", 32)])
        self.lost = Signal(32)
        self.taps = []

    def tap(self, publisher):
        """A FIFO from one publisher; returns it, written by the publisher's events."""
        fifo = stream.SyncFIFO([("data", 32)], self.DEPTH)
        setattr(self, f"tap{len(self.taps)}", fifo)
        self.taps.append(fifo)
        self.comb += [fifo.sink.valid.eq(publisher.sink.valid), fifo.sink.data.eq(publisher.sink.data)]
        self.sync += If(publisher.sink.valid & ~fifo.sink.ready, self.lost.eq(self.lost + 1))
        return fifo

    def build(self):
        srcs = [f.source for f in self.taps]
        pick = _round_robin(self, srcs, self.source.ready)
        self.comb += [
            self.source.valid.eq(pick(s.valid for s in srcs)),
            self.source.data.eq(pick(s.data for s in srcs)),
        ]


class EventQueue(LiteXModule):
    """The events of all publishers in one queue in block RAM, in the order they came (round robin between
    publishers at once), read by the CPU from its head: topic, value and time (cycles); a write of `pop` takes the
    head away. `time` counts the system clock's cycles."""
    DEPTH = 256

    def __init__(self):
        self.time = Signal(32)
        self.sync += self.time.eq(self.time + 1)
        self.publishers = []
        self.subscribers = []

    def subscriber(self, topic):
        s = Subscriber(topic)
        setattr(self, f"subscriber{len(self.subscribers)}", s)
        self.subscribers.append(s)
        return s

    def publisher(self, topic):
        p = Publisher(topic, self.time)
        setattr(self, f"publisher{len(self.publishers)}", p)
        self.publishers.append(p)
        return p

    def build(self):
        """After every publisher and subscriber: each subscriber fed by its topic's publishers, the round robin
        into the queue, the CSRs."""
        for s in self.subscribers:
            for p in self.publishers:
                if p.topic == s.topic:
                    s.tap(p)
            s.build()
        n = len(self.publishers)
        self.queue = q = stream.SyncFIFO([("topic", 8), ("value", 32), ("time", 32)], self.DEPTH, buffered=True)
        srcs = [p.fifo.source for p in self.publishers]
        pick = _round_robin(self, srcs, q.sink.ready)
        self.comb += [
            q.sink.valid.eq(pick(s.valid for s in srcs)),
            q.sink.topic.eq(pick(Constant(p.topic, 8) for p in self.publishers)),
            q.sink.value.eq(pick(s.value for s in srcs)),
            q.sink.time.eq(pick(s.time for s in srcs)),
        ]
        self._level = CSRStatus(16, name="level", description="Events in the queue, 0 while its head is not ready.")
        self._topic = CSRStatus(8, name="topic", description="The oldest event's topic.")
        self._value = CSRStatus(32, name="value", description="Its value.")
        self._time = CSRStatus(32, name="time", description="When it came, in system clock cycles.")
        self._now = CSRStatus(32, name="now", description="The time now, in system clock cycles: how long ago an event came.")
        self._pop = CSRStorage(1, name="pop", description="Write: the oldest event taken away.")
        self._lost = CSRStatus(32, name="lost", description="Events no publisher's FIFO had room for, all publishers.")
        self.comb += [
            # 0 until the head is there (the queue's output is registered: a clock after a pop)
            self._level.status.eq(Mux(q.source.valid, q.level, 0)),
            self._topic.status.eq(q.source.topic),
            self._value.status.eq(q.source.value),
            self._now.status.eq(self.time),
            self._time.status.eq(q.source.time),
            q.source.ready.eq(self._pop.re),
        ]
        self.sync += self._lost.status.eq(reduce(lambda a, b: a + b, [p.lost for p in self.publishers]))
        self.nonempty = q.source.valid


class _Wire:
    """Two instances wired (one called in the other): one endpoint, written by one instance's link and
    read by the other's, `lane` bits per value, k values."""
    def __init__(self, t):
        fields = _end_fields(t)
        self.lane = L = 64 if any(bits > 32 for bits, _ in fields) else 32
        self.fields = fields
        self.sink = self.source = stream.Endpoint([("data", L * len(fields))])


class _CallStage:
    """An instance called in this one: what goes in is written to the wire into its input, what comes
    out is read from the wire from its output."""
    def __init__(self, into, out_of):
        self.engaged = 0
        if into:
            self.sink, self.in_lane = into.sink, into.lane
        if out_of:
            self.source, self.out_lane = out_of.source, out_of.lane


class _Push(LiteXModule):
    """One element given by the CPU without DMA (f(:send, :x, value)): its packed words written (wr, index,
    data), then a push puts them into a small FIFO as one element; `room` is how many more fit."""
    DEPTH = 8

    def __init__(self, n, wr, index, data, push):
        nw = (n + 3) // 4
        words = Signal(32 * nw)
        self.fifo = fifo = stream.SyncFIFO([("data", 8 * n)], self.DEPTH)
        self.source = fifo.source
        self.room = Signal(8)
        for i in range(nw):
            self.sync += If(wr & (index == i), words[32 * i:32 * (i + 1)].eq(data))
        self.comb += [
            fifo.sink.valid.eq(push),
            fifo.sink.data.eq(words[:8 * n]),
            self.room.eq(self.DEPTH - fifo.level),
        ]


class _FromCPU(LiteXModule):
    """Packed elements from an input to `lane` bits per value; `_link` extends them. With `push`, the elements the
    CPU gives one by one (_Push) too, taken in turn with the DMA's, a whole element each."""
    def __init__(self, end, sizes, push=None):
        self.lane = L = _lane(sizes)
        self.source = stream.Endpoint([("data", L * len(sizes))])
        src = end.source
        if push is not None:
            n = sum(sizes)
            # emptied when the instance stops, as the DMA's side
            self.push = p = ResetInserter()(_Push(n, *push))
            self.comb += p.reset.eq(end.reset)
            self.room = p.room
            merged = stream.Endpoint([("data", 8 * n)])
            srcs = [end.source, p.source]
            pick = _round_robin(self, srcs, merged.ready)
            self.comb += [merged.valid.eq(pick(s.valid for s in srcs)), merged.data.eq(pick(s.data for s in srcs))]
            src = merged
        self.comb += src.connect(self.source, omit={"data"})
        at = 0
        for i, size in enumerate(sizes):
            self.comb += self.source.data[L * i:L * i + 8 * size].eq(src.data[at:at + 8 * size])
            at += 8 * size


class _ToCPU(LiteXModule):
    """`lane` bits per value at a link's end, packed for an output."""
    def __init__(self, end, sizes):
        self.lane = L = _lane(sizes)
        self.sink = stream.Endpoint([("data", L * len(sizes))])
        self.comb += [
            self.sink.connect(end.sink, omit={"data"}),
            end.sink.data.eq(Cat(*[self.sink.data[L * i:L * i + 8 * size] for i, size in enumerate(sizes)])),
        ]


class Pipeline(LiteXModule):
    """A definstance: its stages (blocks / kernels) linked by registered streams. A link carries
    one element per clock, as wide as the values of its producer's type (a kernel's result from
    its .sig; a block's `source_width` / `source_signed`, else 32 bits), and hands the consumer each
    value in 32 bits, sign- or zero-extended as the producer's type is. `ends` are the DMA engines of
    its input and output, by the CPU end's description, on the native ports `port(mode)` gives; the CPU sees elements packed (CPUIn, CPUOut): each
    value in 1, 2 or 4 bytes, a tuple left to right."""
    FIFO_DEPTH = 4

    def __init__(self, soc, p, kernels, enable, port, wires=None, events=None, pushes=None):
        wires = wires or {}
        self.rooms = []            # (end, room) of the inputs' FIFOs of elements given one by one
        self.ends = []
        self.level_inputs = []     # (signal, instance of values) the HWStream wires
        self._kernels = kernels
        self._reset = Signal()     # what the links and the buffer hold dropped
        stages = []
        agents = {}            # name -> Agent: one state shared by the stages that name it
        widths = []
        for i, st in enumerate(p["stages"]):
            if "call" in st:
                stage = _CallStage(wires.get((st["call"], "in")), wires.get((st["call"], "out")))
            elif st.get("block") == "broadcast":
                stage = events.publisher(st["topic_id"])
            elif st.get("block") == "subscribe":
                stage = events.subscriber(st["topic_id"])
            elif st.get("block") == "hw__changes":
                stage = LevelChanges()
                self.level_inputs.append((stage.level, st["from"]))
            elif st.get("block") == "hw__zip":
                stage = Zip(*st["args"])
            elif st.get("block") == "hw__fork":
                # what the outputs took is forgotten when the instance stops, as the links' contents
                stage = ResetInserter()(Fork(*st["args"]))
                self.comb += stage.reset.eq(self._reset)
            elif "block" in st:
                stage = _provider(st["gateware"]).BLOCKS[st["block"]](soc, enable, *st["args"])
            else:
                k = kernels[st["kernel"]]
                # the initial state is the stage's: transform(init, &f/2); an agent's, the agent's (its first stage)
                init = st.get("init", k["init"])
                agent = None
                if st.get("agent"):
                    if st["agent"] not in agents:
                        agents[st["agent"]] = Agent(k.get("lane", 32), len(k["state"]), init)
                    agent = agents[st["agent"]]
                stage = KernelStage(soc.platform, {**k, "init": init}, enable, agent)
            if not isinstance(stage, _CallStage):
                setattr(self, f"stage{i}", stage)
            stages.append(stage)
            if "kernel" in st:
                widths.append(_fields(kernels[st["kernel"]]["ret"]))
            elif "call" in st:
                widths.append(_end_fields(st.get("out_type")))
            elif "fields" in st:
                widths.append([(bits, signed) for bits, signed in st["fields"]])
            elif st.get("block") in ("subscribe", "hw__changes"):
                widths.append(_end_fields(st["type"]))
            else:
                widths.append([(getattr(stage, "source_width", 32), getattr(stage, "source_signed", False))])
        self.stages = stages
        # each agent once all its functions are there: its turns
        for name, a in agents.items():
            a.build()
            setattr(self, f"agent_{name}", a)
        # stopped, once no kernel still needs the word before it
        engaged = [st.engaged for st in stages if isinstance(st, KernelStage)]
        self.sync += self._reset.eq(~enable & ~reduce(or_, engaged, 0))
        for link in p["links"]:
            i = link["from"]
            fp, to, tp = link.get("from_port", 0), link["to"], link.get("port", 0)
            self._link(f"link{i}_{fp}_{to}_{tp}", stages[i], stages[to], p["stages"][to], widths[i], tp, fp)
        inputs = {inp["name"]: inp for inp in p.get("inputs", [])}
        # this instance called in another: its input / output wired there instead of a DMA engine
        wired = p.get("wired", {})
        me = f"{p['module']}.{p['name']}" if wired else None
        if "in" in wired:
            inp, w = inputs[wired["in"]], wires[(me, "in")]
            self._link("link_wired_in", w, stages[inp["to"]], p["stages"][inp["to"]], w.fields, inp.get("port", 0))
        if wired.get("out"):
            last = p.get("output_from", len(stages) - 1)
            self._link("link_wired_out", stages[last], wires[(me, "out")], {}, widths[last], 0, p.get("output_port") or 0)
        for e in p["ends"]:
            if e["dir"] == "in":
                # an input: into the stage and the input of it the description says (a join's second)
                inp = inputs[e["name"]]
                fields = _end_fields(inp["type"])
                sizes = [_packed(bits) for bits, _ in fields]
                end = CPUIn(port("read"), n=sum(sizes))
                self.comb += end.reset.eq(self._reset)
                push = None
                if pushes is not None:
                    wr, index, data, strobe, sel = pushes
                    push = (wr & (sel == e["index"]), index, data, strobe & (sel == e["index"]))
                from_cpu = _FromCPU(end, sizes, push)
                if push is not None:
                    self.rooms.append((e["index"], from_cpu.room))
                setattr(self, f"from_cpu_{e['name']}", from_cpu)
                self._link(f"link_in_{e['name']}", from_cpu, stages[inp["to"]], p["stages"][inp["to"]],
                           [(8 * size, signed) for size, (_, signed) in zip(sizes, fields)], inp.get("port", 0))
            else:
                out = p["output"]
                fields = _end_fields(p.get("output_type"))
                sizes = [_packed(bits) for bits, _ in fields]
                end = CPUOut(port("write"), n=sum(sizes),
                             buffer=out["buffer"], drop=out["overflow"] == "drop")
                self.comb += end.reset.eq(self._reset)
                self.to_cpu = _ToCPU(end, sizes)
                last = p.get("output_from", len(stages) - 1)
                self._link("link_out", stages[last], self.to_cpu, {}, widths[last], 0, p.get("output_port") or 0)
            self.ends.append((e["index"], end))

    def _link(self, name, a, b, to, fields, port=0, from_port=0):
        w = sum(bits for bits, _ in fields)
        if "kernel" in to and self._kernels[to["kernel"]].get("space"):
            # before a time-multiplexed kernel (a loop over its memory): a FIFO, so that
            # the stage before it keeps working while it computes (with a single register
            # two such kernels in a row add up their compute times). A few words cover
            # what arrives during one computation; the sources upstream buffer the rest
            # (16 deep cost ~2500 flip-flops for the FM radio's five, for nothing).
            buf = stream.SyncFIFO([("data", w)], self.FIFO_DEPTH, buffered=True)
        else:
            # registers on every link, valid / data forward and ready backward: otherwise
            # ready runs through every stage in one clock (back from the sink)
            buf = stream.Buffer([("data", w)], pipe_valid=True, pipe_ready=True)
        buf = ResetInserter()(buf)
        self.comb += buf.reset.eq(self._reset)
        setattr(self, name, buf)
        # from `lane` bits per value at a (blocks: 32) to `lane` bits per value at b
        la = getattr(a, "out_lane", getattr(a, "lane", 32))
        lb = getattr(b, "in_lane", getattr(b, "lane", 32))
        source = a.sources[from_port] if from_port else a.source      # which output of a (a fork's)
        packed, wide, at = [], [], 0
        for i, (bits, signed) in enumerate(fields):
            d = buf.source.data[at:at + bits]
            packed.append(source.data[la * i:la * i + bits])
            wide.append(d[:lb] if bits >= lb else Cat(d, Replicate(d[bits - 1] if signed else 0, lb - bits)))
            at += bits
        sink = b.sinks[port] if port else b.sink      # `port`: which input of b (a join's)
        self.comb += [
            source.connect(buf.sink, omit={"data"}), buf.sink.data.eq(Cat(*packed)),
            buf.source.connect(sink, omit={"data"}), sink.data.eq(Cat(*wide)),
        ]


class LevelInstance(LiteXModule):
    """A definstance of levels (elixir-hls EHLS.Level): its kernel behind hls_level_adapter.v, which
    takes the words the CPU wrote at the start write, fires the kernel and holds its result with the
    count of that start. `wr` / `start`: this instance's strobes of the shared CSRs; `peek`: the count
    and the result, as the words the CPU reads at one clock."""
    def __init__(self, platform, p, k, enable, wr, wr_index, wr_data, start):
        self.ends = []
        self.kernel = kernel = Kernel(platform, k)
        self.stages = [kernel]
        W, ni, ny = kernel.lane, k.get("in_words", 1), k.get("out_words", 1)
        init = 0
        for i, v in enumerate(p["level"]["initial"]):
            init |= (v & ((1 << W) - 1)) << (W * i)
        self.issued, self.done, self.result = Signal(32), Signal(32), Signal(W * ny)
        enable_d = Signal()
        self.sync += enable_d.eq(enable)
        self.comb += kernel.restart.eq(enable & ~enable_d)
        self.specials += Instance("hls_level_adapter", p_W=W, p_NI=ni, p_NY=ny, p_INIT=Constant(init, W * ny),
            i_clk=ClockSignal(), i_rst=ResetSignal(), i_enable=enable,
            i_wr=wr, i_wr_index=wr_index, i_wr_data=wr_data, i_start=start,
            o_issued=self.issued, o_result=self.result, o_done=self.done,
            o_s_valid=kernel.s_valid, i_s_ready=kernel.s_ready, o_s_data=kernel.s_data,
            i_m_valid=kernel.m_valid, o_m_ready=kernel.m_ready, i_m_data=kernel.m_data)
        self.peek = Cat(self.done, self.result)
        self.peek_words = 1 + W * ny // 32


class HWStream(LiteXModule):
    def __init__(self, platform, soc, kernels, pipelines):
        self.pipe_enable = CSRStorage(32, reset=(1 << len(pipelines)) - 1,
                                      description="Instances running (bit i: instance i), from reset.")
        by_name = {k["kernel"]: k for k in kernels}
        # the DMA engines of the CPU ends: one crossbar port to read and one to write, shared
        shared, wanted = {}, {"read": [], "write": []}

        def port(mode):
            if mode not in shared:
                shared[mode] = soc.sdram.crossbar.get_port(mode=mode, data_width=32)
            p = LiteDRAMNativePort(mode, shared[mode].address_width, 32)
            wanted[mode].append(p)
            return p

        # the instances of levels (EHLS.Level): the CPU selects one (level_sel), writes the words of its
        # arguments (level_word_sel, then level_word), then level_start, which takes them all at once and
        # fires it; level_issued is the count of its starts, the one a call then waits for (peek)
        levels = [p for p in pipelines if "level" in p]
        if levels:
            self.level_sel = CSRStorage(8, description="Instance of levels.")
            self.level_word_sel = CSRStorage(8, description="Word of its arguments.")
            self.level_word = CSRStorage(32, description="Write: the selected word.")
            self.level_start = CSRStorage(1, description="Write: take the words written and compute.")
            self.level_issued = CSRStatus(32, description="Starts of the selected instance so far.")
            # registered: the CSR decode and the compare in separate clocks
            lwr, lstart, lsel, lws, lwd = Signal(), Signal(), Signal(8), Signal(8), Signal(32)
            self.sync += [lwr.eq(self.level_word.re), lstart.eq(self.level_start.re), lsel.eq(self.level_sel.storage),
                          lws.eq(self.level_word_sel.storage), lwd.eq(self.level_word.storage)]
        # the events (EHLS.PubSub.broadcast(topic) stages, gen_manifest.py numbers the topics): one queue for the CPU
        publishes = any(st.get("block") in ("broadcast", "subscribe") for p in pipelines for st in p["stages"])
        events = EventQueue() if publishes else None
        if events:
            self.events = events
        # elements given one by one, without DMA (f(:send, :x, value)): the CPU selects the input end
        # (push_sel), writes the element's packed words (push_word_sel, push_word), then push; push_room
        # says how many more fit in that input's FIFO
        pushes = None
        if any(e for p in pipelines for e in p.get("ends", []) if e["dir"] == "in"):
            self.push_sel = CSRStorage(8, description="Input end.")
            self.push_word_sel = CSRStorage(8, description="Word of the packed element.")
            self.push_word = CSRStorage(32, description="Write: the selected word.")
            self.push = CSRStorage(1, description="Write: the words written as one element into the end's FIFO.")
            self.push_room = CSRStatus(8, description="Elements the selected end's FIFO has room for.")
            pwr, pstrobe, psel, pws, pwd = Signal(), Signal(), Signal(8), Signal(8), Signal(32)
            self.sync += [pwr.eq(self.push_word.re), pstrobe.eq(self.push.re), psel.eq(self.push_sel.storage),
                          pws.eq(self.push_word_sel.storage), pwd.eq(self.push_word.storage)]
            pushes = (pwr, pws, pwd, pstrobe, psel)
        # the wires between instances, one called in another (gen_manifest.py "wired")
        wires = {}
        for p in pipelines:
            me, wired = f"{p['module']}.{p['name']}", p.get("wired", {})
            if "in" in wired:
                wires[(me, "in")] = _Wire(next(i["type"] for i in p["inputs"] if i["name"] == wired["in"]))
            if wired.get("out"):
                wires[(me, "out")] = _Wire(p.get("output_type"))
        for i, p in enumerate(pipelines):
            if "level" in p:
                n = p["level"]["index"]
                setattr(self, f"pipe{i}", LevelInstance(platform, p, by_name[p["stages"][0]["kernel"]],
                        self.pipe_enable.storage[i], lwr & (lsel == n), lws, lwd, lstart & (lsel == n)))
            else:
                setattr(self, f"pipe{i}", Pipeline(soc, p, by_name, self.pipe_enable.storage[i], port, wires, events, pushes))
        if pushes is not None:
            rooms = dict(r for i in range(len(pipelines)) for r in getattr(getattr(self, f"pipe{i}"), "rooms", []))
            # no room at an end that is no input of an instance of streams, also past the last end
            room = Array(rooms.get(k, Constant(0, 8)) for k in range(256))
            self.sync += self.push_room.status.eq(room[self.push_sel.storage])
        if levels:
            issued = Array(getattr(self, f"pipe{i}").issued for i, p in enumerate(pipelines) if "level" in p)
            self.sync += self.level_issued.status.eq(issued[self.level_sel.storage])
        for mode, ports in wanted.items():
            if ports:
                setattr(self, f"dma_{mode}", SharedPort(shared[mode], ports))
        # the CPU ends: a CSR prefix end<i> each, an event when each finishes
        ends = sorted(e for i in range(len(pipelines)) for e in getattr(self, f"pipe{i}").ends)
        if events:
            events.build()
        if ends or events:
            self.ev = EventManager()
            for n, end in ends:
                src = EventSourceProcess(name=f"end{n}", edge="rising")
                setattr(self.ev, f"end{n}", src)
                self.comb += src.trigger.eq(end.finished.status)
                setattr(self, f"end{n}", end)
            if events:
                # sources are taken by name, so "events" after the ends' "end<n>": its bit is the number of
                # ends; pending while the queue holds an event
                self.ev.events = EventSourceLevel()
                self.comb += self.ev.events.trigger.eq(self.events.nonempty)
            self.ev.finalize()
        instances = [(getattr(self, f"pipe{i}").stages[j], st["args"]) for i, p in enumerate(pipelines)
                      for j, st in enumerate(p["stages"]) if "kernel" in st and "level" not in p]
        # a kernel's level arguments, wired where it is placed: an instance of levels' result or a pin's
        # level, through a register (instances may be far apart); an integer stays as the reset value
        level_of = {f"{p['module']}.{p['name']}": getattr(self, f"pipe{i}") for i, p in enumerate(pipelines) if "level" in p}
        # changes(k_hw(:value)): the instance of values' result, through a register
        for i, p in enumerate(pipelines):
            for sig, src in getattr(getattr(self, f"pipe{i}"), "level_inputs", []):
                self.sync += sig.eq(level_of[src].result[:32])
        for m, args in instances:
            for j, prm in enumerate(args):
                reg = Signal(32, reset=prm["default"] & 0xFFFFFFFF)
                if "from" in prm:
                    self.sync += reg.eq(level_of[prm["from"]].result[:32])
                elif "pin" in prm:
                    # the pin's level, synchronised by the GPIO block (an out pin: what is written to it)
                    self.sync += reg.eq(soc.ehls_gpio.levels[prm["pin"]])
                self.comb += m.args[j].eq(reg)
        # the state of the pipelines' stages for the CPU (gen_manifest: peek): a stage's words copied
        # at one clock into one register, read from there, so that they cannot tear
        self.peek_stage = CSRStorage(8, description="Write: take the state of this stage.")
        self.peek_sel = CSRStorage(8, description="Word of the state taken.")
        self.peek_value = CSRStatus(32, description="The selected word.")
        # by their numbers (gen_manifest: peek): the named states and holds, the levels' count and result
        states = sorted([(st["peek"], getattr(self, f"pipe{i}").stages[j].state, st["state_words"])
                         for i, p in enumerate(pipelines) if "level" not in p
                         for j, st in enumerate(p["stages"]) if "peek" in st] +
                        [(p["level"]["peek"], getattr(self, f"pipe{i}").peek, p["level"]["peek_words"])
                         for i, p in enumerate(pipelines) if "level" in p], key=lambda e: e[0])
        states = [(s, w) for _, s, w in states]
        if states:
            n = max(w for _, w in states)
            taken = Signal(32 * n)
            take, stage = Signal(), Signal(8)
            self.sync += [take.eq(self.peek_stage.re), stage.eq(self.peek_stage.storage)]
            self.sync += If(take, taken.eq(Array(s[:32 * w] for s, w in states)[stage]))
            self.sync += self.peek_value.status.eq(Array(taken[32 * w:32 * (w + 1)] for w in range(n))[self.peek_sel.storage])

        # a named state's memories (EHLS.TupleState): a word read by its address in the stage's memory space,
        # the stage chosen by peek_stage; mem_done 1 once the word is in mem_data
        mems = [(st["peek"], getattr(self, f"pipe{i}").stages[j].kernel)
                for i, p in enumerate(pipelines) if "level" not in p
                for j, st in enumerate(p["stages"]) if "peek" in st and "kernel" in st]
        mems = [(pk, k) for pk, k in mems if hasattr(k, "mem_addr")]
        if mems:
            self.mem_addr = CSRStorage(16, description="Write: read the word at this address of the chosen stage's memory space.")
            self.mem_data = CSRStatus(32, description="The word read.")
            self.mem_done = CSRStatus(1, description="1 once mem_data holds the word.")
            sel = Signal(8)
            self.comb += sel.eq(self.peek_stage.storage)
            self.comb += [self.mem_data.status.eq(0), self.mem_done.status.eq(0)]
            for pk, k in mems:
                self.comb += [k.mem_addr.eq(self.mem_addr.storage), k.mem_req.eq(self.mem_addr.re & (sel == pk)),
                              If(sel == pk, self.mem_data.status.eq(k.mem_q), self.mem_done.status.eq(k.mem_done))]

        platform.add_source(os.path.join(VERILOG_DIR, "hls_stream_adapter.v"))
        platform.add_source(os.path.join(VERILOG_DIR, "hls_state_adapter.v"))
        platform.add_source(os.path.join(VERILOG_DIR, "hls_level_adapter.v"))
        platform.toolchain.options["verilog_std"] = "sysv2017"


def add_hls(soc, hw_dir, package_dirs=(), pin_pull=None):
    """Adds the circuits of hw_dir (an application's build/hw) to soc as soc.hwstream, with
    the blocks and peripherals of the block packages in package_dirs (their roots). pin_pull:
    the device backend's pin constraints for a pull (e.g. gowin_litex.pin_pull)."""
    soc.ehls_pin_pull = pin_pull
    for pkg in package_dirs:
        sys.path.insert(0, os.path.join(os.path.abspath(pkg), "gateware"))
    load = lambda name: json.load(open(os.path.join(hw_dir, name)))
    has = lambda name: os.path.exists(os.path.join(hw_dir, name))
    kernels, pipelines = load("kernels.json"), load("pipelines.json")
    packages = load("packages.json") if has("packages.json") else []
    if not kernels and not pipelines and not packages:
        raise SystemExit(f"nothing in {hw_dir} (mix ehls.compile)")
    # the application's options to its block packages (use EHLS, blocks: [{Pkg, opts}]),
    # before any of their blocks / peripherals is built
    for p in packages:
        mod = _provider(p["gateware"])
        if hasattr(mod, "configure"):
            mod.configure(p["options"] or {})
        elif p["options"]:
            raise SystemExit(f"{p['gateware']}: takes no options ({p['options']})")
    # the packages' circuits that are no pipeline stage and no peripheral asked for by name
    # (first: a pipeline's stages may use them)
    for p in packages:
        mod = _provider(p["gateware"])
        if hasattr(mod, "add_to_soc"):
            mod.add_to_soc(soc)
    soc.hwstream = HWStream(soc.platform, soc, kernels, pipelines)
    if hasattr(soc.hwstream, "ev"):
        soc.irq.add("hwstream", use_loc_if_exists=True)
    # the peripherals the application asked for (use EHLS, peripherals: [...])
    for p in load("peripherals.json") if has("peripherals.json") else []:
        _provider(p["gateware"]).PERIPHERALS[p["name"]](soc)
    return soc.hwstream
