#!/usr/bin/env python3
"""The events' queue in simulation (Migen), no FPGA: three publishers (hls_litex.py Publisher) given values at
random, the queue (EventQueue) read and popped at random as the CPU does. Every event must come out once, each
publisher's in its order, with its topic; a publisher never holds back what feeds it, and what its FIFO has no
room for is counted, not stalled. A queue that loses an event is caught. Then a subscriber (an instance's
EHLS.PubSub.subscribe(topic)) of a topic two publishers share, taken at random: every event of each publisher once, in its
order, and a subscriber too slow loses events without holding the publishers back.
usage: test/sim_events.py  (with LiteX importable; EHLS_DEVICE unset)"""
import os
import random
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "priv", "backend", "litex"))

from migen import passive, run_simulation

from hls_litex import EventQueue


def check(what, cond, info=""):
    print(("ok  " if cond else "FAIL") + f" {what} {info}")
    if not cond:
        sys.exit(1)


def bench(gap, n=200, seed=3, broken=False):
    """n values per publisher, a gap of about `gap` clocks between them; the CPU pops one event every few clocks."""
    q = EventQueue()
    pubs = [q.publisher(t) for t in (7, 2, 5)]
    q.build()
    if broken:
        q.comb += q.queue.source.ready.eq(1)          # takes the head away every clock, read or not
    rnd = random.Random(seed)
    got = []
    sent = {p.topic: [] for p in pubs}

    def feed(p):
        @passive
        def gen():
            for i in range(n):
                for _ in range(rnd.randrange(gap + 1)):
                    yield p.sink.valid.eq(0)
                    yield
                yield p.sink.valid.eq(1)
                yield p.sink.data.eq(1000 * p.topic + i)
                yield
                check_ready = yield p.sink.ready
                if not check_ready:
                    raise AssertionError("a publisher held back what feeds it")
                sent[p.topic].append(1000 * p.topic + i)
            yield p.sink.valid.eq(0)
        return gen()

    def cpu():
        idle = 0
        while idle < 400:
            yield q._pop.re.eq(0)
            yield
            if (yield q._level.status):
                idle = 0
                topic, value = (yield q._topic.status), (yield q._value.status)
                got.append((topic, value))
                yield q._pop.re.eq(1)
                yield
                yield q._pop.re.eq(0)
                for _ in range(rnd.randrange(4)):
                    yield
            else:
                idle += 1

    run_simulation(q, [feed(p) for p in pubs] + [cpu()])
    return q, pubs, got, sent


q, pubs, got, sent = bench(gap=20)
per = {t: [v for tt, v in got if tt == t] for t in sent}
check("events: each once, each publisher's in order, with its topic", per == sent, f"({len(got)} events)")
check("events: topics as given", all(v // 1000 == t for t, v in got))

# a flood: the publishers faster than the CPU reads; nothing held back, the rest counted
q, pubs, got, sent = bench(gap=0, n=600)
per = {t: [v for tt, v in got if tt == t] for t in sent}
in_order = all(vals == [v for v in sent[t] if v in set(vals)] for t, vals in per.items())
check("flood: what comes out is in each publisher's order", in_order, f"({len(got)} of {3 * 600})")
check("flood: some events had no room", len(got) < 3 * 600)

q, pubs, got, sent = bench(gap=20, broken=True)
per = {t: [v for tt, v in got if tt == t] for t in sent}
check("a queue losing events is caught", per != sent)


def sub_bench(take, n=200, seed=5):
    """Two publishers of topic 4 and one of topic 9; a subscriber of topic 4 taking with probability `take`."""
    q = EventQueue()
    pubs = [q.publisher(t) for t in (4, 4, 9)]
    sub = q.subscriber(4)
    q.build()
    rnd = random.Random(seed)
    got = []

    def feed(p, base):
        @passive
        def gen():
            for i in range(n):
                for _ in range(rnd.randrange(6)):
                    yield p.sink.valid.eq(0)
                    yield
                yield p.sink.valid.eq(1)
                yield p.sink.data.eq(base + i)
                yield
            yield p.sink.valid.eq(0)
        return gen()

    def taker():
        @passive
        def gen():
            while True:
                yield q._pop.re.eq(1)        # the CPU's queue kept empty: not what is checked here
                yield sub.source.ready.eq(rnd.random() < take)
                yield
                if (yield sub.source.valid) and (yield sub.source.ready):
                    got.append((yield sub.source.data))
        return gen()

    def wait():
        for _ in range(n * 12):
            yield

    run_simulation(q, [feed(pubs[0], 1000), feed(pubs[1], 2000), feed(pubs[2], 3000), taker(), wait()])
    return got


got = sub_bench(take=0.9)
a, b = [v for v in got if 1000 <= v < 2000], [v for v in got if 2000 <= v < 3000]
check("subscriber: every event of both publishers once, each in its order", a == list(range(1000, 1200)) and b == list(range(2000, 2200)),
      f"({len(a)} + {len(b)})")
check("subscriber: nothing of another topic", all(v < 3000 for v in got))
got = sub_bench(take=0.05)
a = [v for v in got if 1000 <= v < 2000]
check("subscriber too slow: fewer events, still in order, publishers never held back", len(got) < 400 and a == sorted(a), f"({len(got)} of 400)")
