# Elixir HLS — vision

English | [日本語](vision.ja.md)

## Why

A system with an FPGA is usually described several times over: C or Elixir for the CPU,
Verilog for the circuits, and a document saying what both should do, kept in step by hand.
Elixir HLS describes the whole system, the CPU side and the FPGA side, in one language,
Elixir, and that description is the specification: it runs, so what the system must do is
stated exactly, by code that can be executed.

Elixir fits the FPGA side because it is functional. A pure function with no shared,
mutable state is a circuit: its expressions are logic, state is explicit (the state of a function
returning `{output, next_state}` becomes registers), and functions joined with the pipe `|>` are a dataflow of streams.
So one language covers every level, from the application (processes that tune and
watch the hardware) down to the logic (bit widths such as `s18`, tables, memories, the
clock-by-clock state of a filter).

Putting it into hardware is automated: each circuit is generated from its Elixir function,
built into the SoC with its runtime, and checked in simulation against the same function.
The specification stays the single source; the hardware follows from it.

This matters more as AI agents write and change more of the code. One executable
specification in one language is something an agent can read whole, change in one place
and check by running it, instead of keeping several hand-written descriptions consistent;
the automated lowering and its checks keep the hardware true to it.

## What it is

High-level synthesis from Elixir: a function written once runs on the CPU as Elixir and in
an FPGA as a circuit, and every circuit is checked in simulation against its Elixir
function. Stream instances (`definstance`) run in the FPGA on their own while the program
around them, on a VM next to the FPGA, only tunes and watches them, or calls them as functions. Pins with only a
current value, such as an LED or a switch, are read and written with plain function calls, and
what must not be lost, such as a button press, arrives as a message.

It synthesizes what its example, an FM radio, needs; the expressiveness more general
processing needs is still to come.

The first target is the Sipeed Tang Primer 25K: a LiteX SoC in the FPGA, with AtomVM on its
CPU (a soft CPU); the program and its circuits fit on one chip.

## Layers

![The layers: front ends (defhls / definstance, later Nx defn) into the core IR, the back end (MLIR, CIRCT, SystemVerilog) and the verification in elixir-hls' core; the RTL boundary; the device, SoC and runtime backends; targets, blocks and applications on top](images/layers.svg)

The core knows no board, vendor, SoC or VM: it writes RTL and a description of it. What
depends on the hardware sits in device, SoC and runtime backends; a target is a board on top
of a combination of them ([design.md](design.md)).

For now the synthesis goes through CIRCT: Elixir is lowered to standard MLIR dialects and
CIRCT turns them into circuits. How far this route carries, in what it can express and in
the size and speed of what it makes, is part of the work.

## Repositories

The `elixir-hls` organization holds elixir-hls, the targets (a base and its HLS layer, e.g.
`atomvm-tang25k` and `atomvm-tang25k-hls`), the block packages and the applications.

## Planned

* Nerves: the full BEAM on embedded Linux next to an FPGA, as another kind of target.
* Nx: `defn` as a second front end into the core IR, beside `defhls` / `definstance`.
