#!/usr/bin/env python3
"""Collect the kernels (*.sig), pipelines (*.pipeline), block packages (*.packages) and
peripherals (*.peripherals) written by defhls / definstance / use EHLS into build/hw/
kernels.json, pipelines.json, packages.json and peripherals.json: the description the SoC
backend builds from and the runtime backend numbers its calls by.

usage: gen_manifest.py <build/hw>

A kernel used in no pipeline makes no circuit. Every argument after the first a stage's kernel takes
(a level today) is wired where it is placed: a kernel in two stages has two wires. Every named state of a pipeline, every
hold stage and every instance of levels gets an index for reading its words as a whole (peek/2), a hold stage typed as the result
of the stage before it. Every CPU end (an instance's input and output not wired to another instance it
is called in) gets an index (a DMA engine).
"""
import glob
import json
import os
import sys

hw = sys.argv[1]
pipelines = [json.load(open(p)) for p in sorted(glob.glob(os.path.join(hw, "*.pipeline")))]
in_pipes = {st["kernel"] for p in pipelines for st in p["stages"] if "kernel" in st}
kernels = []
for sig in sorted(glob.glob(os.path.join(hw, "*.sig"))):
    k = json.load(open(sig))
    k.update(sv=os.path.join(hw, k["kernel"] + ".sv"), pipeline=k["kernel"] in in_pipes)
    kernels.append(k)


def widens_t(a, b):
    """Every value of type a the same in type b; a tuple (a list) value by value."""
    if isinstance(a, list) or isinstance(b, list):
        return isinstance(a, list) and isinstance(b, list) and len(a) == len(b) and all(map(widens_t, a, b))
    (wa, sa), (wb, sb) = (int(a[1:]), a[0] == "s"), (int(b[1:]), b[0] == "s")
    return wb >= wa if sa == sb else (sb and wb > wa)


# Instances called inside instances (EHLS: `x |> fir_hw()`): the caller's stream goes into the callee's
# input and the callee's output comes back, wired, so neither is a CPU end. The callee must be an
# instance of streams of this build, called once, taking a stream if given one and giving one if
# something takes it, the types keeping their values; calls make no loop.
full = {f"{p['module']}.{p['name']}": p for p in pipelines}
called_by = {}
calls = {}
for p in pipelines:
    me = f"{p['module']}.{p['name']}"
    for j, st in enumerate(p["stages"]):
        if "call" not in st:
            continue
        where = f"gen_manifest: {me}"
        q = full.get(st["call"])
        if not q:
            sys.exit(f"{where}: {st['call']} is no instance of this build")
        if "level" in q:
            sys.exit(f"{where}: {st['call']} is an instance of levels: read it as {st['call']}(:value)")
        if st["call"] in called_by:
            sys.exit(f"{where}: {st['call']} is called in {called_by[st['call']]} too: an instance exists once")
        called_by[st["call"]] = me
        calls.setdefault(me, []).append(st["call"])
        wired = q.setdefault("wired", {})
        feeds = [l for l in p["links"] if l["to"] == j]
        if feeds:
            if len(q.get("inputs", [])) != 1:
                sys.exit(f"{where}: {st['call']} takes {len(q.get('inputs', []))} streams, and one goes in")
            inp = q["inputs"][0]
            t = feeds[0].get("type")
            if t and not widens_t(t, inp["type"]):
                sys.exit(f"{where}: {t} goes into {st['call']}, which takes {inp['type']}: that would change the value")
            wired["in"] = inp["name"]
            st["in_type"] = inp["type"]
        elif q.get("inputs"):
            sys.exit(f"{where}: {st['call']} takes a stream, and none goes in")
        if any(l["from"] == j for l in p["links"]):
            if not q.get("output"):
                sys.exit(f"{where}: {st['call']} gives no stream back (it ends in a sink)")
            if st.get("gives_to") and not widens_t(q["output_type"], st["gives_to"]):
                sys.exit(f"{where}: {st['call']} gives {q['output_type']}, taken as {st['gives_to']}: that would change the value")
            wired["out"] = True
            st["out_type"] = q["output_type"]


def loop_from(n, path):
    if n in path:
        sys.exit(f"gen_manifest: instances calling each other in a loop: {' -> '.join(path + [n])}")
    for m in calls.get(n, []):
        loop_from(m, path + [n])


for n in calls:
    loop_from(n, [])

# the CPU ends: every input and output not wired to another instance
ei = 0
for i, p in enumerate(pipelines):
    p["index"] = i
    p["ends"] = []
    wired = p.get("wired", {})
    for inp in p.get("inputs", []):
        if inp["name"] != wired.get("in"):
            p["ends"].append({"name": inp["name"], "dir": "in", "index": ei})
            ei += 1
    if p.get("output") and not wired.get("out"):
        p["ends"].append({"name": "out", "dir": "out", "index": ei})
        ei += 1
by_name = {k["kernel"]: k for k in kernels}
levels = {f"{p['module']}.{p['name']}": p for p in pipelines if "level" in p}


def widens(a, b):
    """Every value of type a ("u8", "s16") the same in type b (EHLS.Pipeline.widens?/2)."""
    (wa, sa), (wb, sb) = (int(a[1:]), a[0] == "s"), (int(b[1:]), b[0] == "s")
    return wb >= wa if sa == sb else (sb and wb > wa)


# the pins of EHLS.GPIO (its package's table: name -> [bit, direction])
gpio_pins = {}
for f in sorted(glob.glob(os.path.join(hw, "*.packages"))):
    for pkg in json.load(open(f)):
        if pkg["gateware"] == "ehls_gpio":
            gpio_pins.update(pkg.get("table") or {})


# a kernel's arguments after the first (levels today) are wired where it is placed (EHLS.Level.place): to an
# instance of levels, which must be in this build, give one value and keep it in the argument's type, its initial value the one
# the simulation uses; to a pin (EHLS.GPIO.read(:pin)), declared in this build; or to an integer
for p in pipelines:
    for st in p["stages"]:
        if "kernel" in st:
            wires = {w["arg"]: w for w in st.get("wires", [])}
            st["args"] = []
            for prm in by_name[st["kernel"]].get("args", []):
                w = wires.get(prm["name"])
                where = f"gen_manifest: {p['module']}.{p['name']}"
                if not w:
                    sys.exit(f"{where}: {by_name[st['kernel']]['function']}'s {prm['name']} is given no level")
                if "pin" in w:
                    if w["pin"] not in gpio_pins:
                        sys.exit(f"{where}: no pin {w['pin']} (EHLS.GPIO) in this build")
                    st["args"].append({**prm, "pin": w["pin"]})
                elif "const" in w:
                    st["args"].append({**prm, "const": w["const"], "default": w["const"]})
                else:
                    src = levels.get(w["from"])
                    if not src:
                        sys.exit(f"{where}: {w['from']} is no instance of levels of this build")
                    ret = src["level"]["ret"]
                    if isinstance(ret, list):
                        sys.exit(f"{where}: {w['from']} gives a tuple, wired to one value")
                    if not widens(ret, w["type"]):
                        sys.exit(f"{where}: {w['from']} gives {ret}, wired to {w['type']}, which would change the value")
                    initial = src["level"]["initial"][0]
                    if ret[0] == "s" and initial >= 1 << (int(ret[1:]) - 1):
                        initial -= 1 << int(ret[1:])
                    st["args"].append({**prm, "from": w["from"], "default": initial})
si = 0
for p in pipelines:
    holds = set()
    before_stage = {l["to"]: p["stages"][l["from"]] for l in p["links"]}  # none: from the CPU
    for i, st in enumerate(p["stages"]):
        k = by_name.get(st.get("kernel"))
        if st.get("state_name") and k and k["state"] and not k.get("pure"):
            st.update(peek=si, state_words=len(k["state"]))
            si += 1
        if st.get("block") == "hold":
            name = st["args"][0]
            if name in holds:
                sys.exit(f"gen_manifest: {p['name']}: two hold({name}) stages")
            holds.add(name)
            before = by_name.get(before_stage.get(i, {}).get("kernel"))
            if before and before.get("out_words", 1) > 1:
                sys.exit(f"gen_manifest: {p['name']}: hold({name}) after {before['function']}, which gives several words")
            if before and before.get("lane", 32) > 32:
                sys.exit(f"gen_manifest: {p['name']}: hold({name}) after {before['function']}, which gives more than 32 bits")
            st.update(peek=si, state_words=1, hold_type=before["ret"] if before else "u32")
            si += 1
# the instances of levels (EHLS.Level): a number each for the CPU's writes (level_start/3), and one
# for reading the count and the result as a whole (peek/2)
li = 0
for p in pipelines:
    if "level" in p:
        k = by_name[p["stages"][0]["kernel"]]
        p["level"].update(index=li, peek=si, peek_words=1 + k.get("lane", 32) // 32 * k.get("out_words", 1))
        li += 1
        si += 1
# the topics of events (EHLS.PubSub.broadcast(topic) stages): a number each, in name order; every publisher of a topic gives
# the same type, one value up to 32 bits (what EHLS.PubSub.subscribe delivers)
topics = {}
for p in pipelines:
    for j, st in enumerate(p["stages"]):
        if st.get("block") != "broadcast":
            continue
        where = f"gen_manifest: {p['module']}.{p['name']}"
        feeds = [l for l in p["links"] if l["to"] == j]
        t = feeds[0].get("type") if feeds else next((i["type"] for i in p.get("inputs", []) if i["to"] == j), None)
        if t is None:
            sys.exit(f"{where}: EHLS.PubSub.broadcast({st['args'][0]}): what goes in has no type known here")
        if isinstance(t, list) or int(t[1:]) > 32:
            sys.exit(f"{where}: EHLS.PubSub.broadcast({st['args'][0]}) of {t}: an event is one value up to 32 bits")
        old = topics.setdefault(st["args"][0], t)
        if old != t:
            sys.exit(f"{where}: EHLS.PubSub.broadcast({st['args'][0]}) of {t}, and of {old} elsewhere: one type per topic")
topic_ids = {name: i for i, name in enumerate(sorted(topics))}
for p in pipelines:
    for st in p["stages"]:
        if st.get("block") == "broadcast":
            st["topic_id"] = topic_ids[st["args"][0]]
        elif st.get("block") == "subscribe":
            # an instance receiving a topic: someone in this build publishes it, and what takes the events
            # keeps their values
            where = f"gen_manifest: {p['module']}.{p['name']}"
            name = st["args"][0]
            if name not in topics:
                sys.exit(f"{where}: EHLS.PubSub.subscribe({name}): nothing in this build publishes {name} (EHLS.PubSub.broadcast({name}))")
            if st.get("gives_to") and not widens_t(topics[name], st["gives_to"]):
                sys.exit(f"{where}: EHLS.PubSub.subscribe({name}) gives {topics[name]}, taken as {st['gives_to']}: that would change the value")
            st.update(topic_id=topic_ids[name], type=topics[name])
# changes(k_hw(:value)): wired to that instance of values, in this build, one value, its type what the block gives
for p in pipelines:
    for st in p["stages"]:
        if st.get("block") != "hw__changes":
            continue
        where = f"gen_manifest: {p['module']}.{p['name']}"
        src = levels.get(st["from"])
        if not src:
            sys.exit(f"{where}: changes({st['from']}(:value)): {st['from']} is no instance of values of this build")
        ret = src["level"]["ret"]
        if isinstance(ret, list) or int(ret[1:]) > 32:
            sys.exit(f"{where}: changes({st['from']}(:value)) of {ret}: one value up to 32 bits")
        if st.get("gives_to") and not widens_t(ret, st["gives_to"]):
            sys.exit(f"{where}: changes({st['from']}(:value)) gives {ret}, taken as {st['gives_to']}: that would change the value")
        st["type"] = ret
json.dump(kernels, open(os.path.join(hw, "kernels.json"), "w"), indent=2)
json.dump([{"name": n, "id": topic_ids[n], "type": topics[n]} for n in sorted(topics)],
          open(os.path.join(hw, "topics.json"), "w"), indent=2)
json.dump(pipelines, open(os.path.join(hw, "pipelines.json"), "w"), indent=2)
# the block packages and their options (use EHLS, blocks: [...]); one set of options each
packages = {}
for f in sorted(glob.glob(os.path.join(hw, "*.packages"))):
    for p in json.load(open(f)):
        old = packages.get(p["gateware"])
        if old and old["options"] and p["options"] and old["options"] != p["options"]:
            sys.exit(f"gen_manifest: {p['gateware']}: different options in two modules: "
                     f"{old['options']} / {p['options']}")
        if not old or p["options"]:
            packages[p["gateware"]] = p
# what the pipelines' stages change in their packages' tables (pin_out: a pin no more the CPU's)
updated = set()
for pl in pipelines:
    for st in pl["stages"]:
        for k, v in st.get("table_update", {}).items():
            if (st["gateware"], k) in updated:
                sys.exit(f"gen_manifest: two stages claim {k} of {st['gateware']}")
            updated.add((st["gateware"], k))
            packages[st["gateware"]]["table"][k] = v
# every register of the packages gets a number (the runtime's reg_read/1, reg_write/2)
ri = 0
for p in packages.values():
    for r in p.get("registers", []):
        r["index"] = ri
        ri += 1
json.dump(list(packages.values()), open(os.path.join(hw, "packages.json"), "w"), indent=2)
# the SoC peripherals the modules asked for (use EHLS, peripherals: [...]), each once
peripherals = {}
for f in sorted(glob.glob(os.path.join(hw, "*.peripherals"))):
    for p in json.load(open(f)):
        peripherals[p["name"]] = p
json.dump(list(peripherals.values()), open(os.path.join(hw, "peripherals.json"), "w"), indent=2)

print(f"{len(kernels)} kernel(s), {len(pipelines)} pipeline(s), {len(peripherals)} peripheral(s) "
      f"-> {hw}/kernels.json, pipelines.json, peripherals.json, packages.json")
# an end costs a DMA engine the source does not show on its own: a forgotten sink shows here
for p in pipelines:
    if p["ends"]:
        out = p.get("output") or {}
        info = f", buffer {out['buffer']} elements" if out.get("buffer") else ""
        info += f", overflow: {out['overflow']}" if out else ""
        names = ", ".join(f"{e['name']} ({e['dir']})" for e in p["ends"])
        print(f"CPU ends of {p['module']}.{p['name']}: {names}{info}")
