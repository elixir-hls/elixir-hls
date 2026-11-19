#!/usr/bin/env python3
"""Check the timing of a built SoC (Gowin's timing report) and refuse a SoC that does not
meet it, unless the application accepted the shortfall on purpose.

Fails when
  * a clock's Fmax is below its constraint plus the margin (EHLS_FMAX_MARGIN, percent,
    default 5): the design passes the tools but has no room for temperature, voltage and
    the next small change;
  * any setup or hold path in the report has negative slack (every path table is read: the
    report's "Total Negative Slack" summary leaves out paths between clocks);
  * the report lacks the whole design's setup or hold paths (an old build: build it again).

Accepting (in the environment, e.g. the application's hls.env, with a comment saying why):
  EHLS_TIMING_WAIVE='<regex>'      violating paths whose "from -> to" matches are accepted
  EHLS_MARGIN_WAIVE='<clock>,...'  these clocks may be below the margin (not below the
                                  constraint)
Everything accepted is still printed.

usage: check_timing.py <soc dir>     exit 0: OK (writes <soc dir>/TIMING_OK), 1: not OK
"""
import html
import os
import re
import sys

soc = sys.argv[1]
rpt = os.path.join(soc, "gateware", "impl", "pnr", "project_tr_content.html")
margin = float(os.environ.get("EHLS_FMAX_MARGIN", "5"))
waive = os.environ.get("EHLS_TIMING_WAIVE", "")
margin_waive = {c.strip() for c in os.environ.get("EHLS_MARGIN_WAIVE", "").split(",") if c.strip()}

if not os.path.exists(rpt):
    print(f"NOT OK: no timing report ({rpt}): the build failed (unrouted nets? see the build log)")
    marker = os.path.join(soc, "TIMING_OK")
    if os.path.exists(marker):
        os.remove(marker)
    sys.exit(1)
text = re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", " ", open(rpt, errors="ignore").read())))
problems, accepted, lines, seen_items = [], [], [], set()

# Fmax per clock: "1 clk50 50.000(MHz) 367.478(MHz) 3 TOP ..."
summary = re.search(r"Max Frequency Summary:(.*?)Total Negative Slack", text)
if not summary:
    sys.exit(f"check_timing: no Fmax summary in {rpt}")
for name, want, got in re.findall(r"\d+ (\S+) ([\d.]+)\(MHz\) ([\d.]+)\(MHz\)", summary.group(1)):
    want, got = float(want), float(got)
    room = (got / want - 1) * 100
    line = f"{name}: {got:.1f} MHz for {want:.1f} MHz ({room:+.1f}%)"
    lines.append(line)
    if got < want:
        problems.append(f"Fmax below the constraint: {line}")
    elif room < margin:
        (accepted if name in margin_waive else problems).append(
            f"Fmax margin under {margin:g}%: {line}")

# every path table row: "N slack from to fromclk toclk relation skew delay"
tables = re.split(r"(Setup Paths Table|Hold Paths Table)", text)
kinds = {"Setup Paths Table": "setup", "Hold Paths Table": "hold"}
seen = set()
kind = None
for part in tables:
    if part in kinds:
        kind = kinds[part]
        seen.add(kind)
        continue
    if kind is None:
        continue
    for slack, frm, to, fc, tc in re.findall(
            r"\d+ (-?\d+\.\d+) (\S+) (\S+) (\S+:\[[RF]\]) (\S+:\[[RF]\]) -?[\d.]+ -?[\d.]+ -?[\d.]+", part):
        if float(slack) >= 0:
            continue
        path = f"{frm} -> {to}"
        item = f"{kind} slack {slack} ns: {path} ({fc} -> {tc})"
        if item in seen_items:
            continue
        seen_items.add(item)
        (accepted if waive and re.search(waive, path) else problems).append(f"timing violation, {item}")
for k in ("setup", "hold"):
    # the whole design's worst paths (not only those of some ports)
    if not re.search(rf"Report Command:report_timing -{k} -max_paths \d+ (?!-from|-to)", text):
        problems.append(f"no {k} paths of the whole design in the timing report: build the SoC "
                        "again (gowin_litex.setup asks for them)")

print("timing:", "; ".join(lines))
rooms = [float(re.search(r"\(([+-][\d.]+)%\)", l).group(1)) for l in lines]
print(f"smallest margin: {min(rooms):.1f}%")
for a in accepted:
    print(f"  accepted (hls.env): {a}")
marker = os.path.join(soc, "TIMING_OK")
if problems:
    for p in problems:
        print(f"  NOT OK: {p}")
    print("The SoC does not meet its timing: it may work, fail now and then, or fail when warm.\n"
          "Try other placements (GW_PLACE / GW_ROUTE), or accept each item in the application's\n"
          "hls.env (EHLS_TIMING_WAIVE / EHLS_MARGIN_WAIVE, with the reason), or use the SoC once\n"
          "with EHLS_ACCEPT_TIMING=1.")
    if os.path.exists(marker):
        os.remove(marker)
    sys.exit(1)
open(marker, "w").write("\n".join(["timing: " + "; ".join(lines)] + accepted) + "\n")
print("timing OK")
