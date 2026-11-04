# Protocol Emulator ASIC — ISA & Architecture Spec (v0.2)

Status: **frozen for Milestone 1** (pending Cerebro/Ash objection). Owner: Legion (ARCH/ISA).
Target: IHP 130 nm CMOS5L via Tiny Tapeout, `tiles: "6x4"` (24 tiles, ~0.75 mm² usable, ~24K logic cells).

## 1. Overview

A small, **firmware-reprogrammable** engine that bit-bangs hardware protocols (UART, SPI, I²C first;
stretch: USB-LS, 10 Mbit Ethernet, JTAG, SWD, PS/2, CAN). Inspired by the RP2040 PIO and TI PRU.

Architecture **C (hybrid)**: one minimal *sequencer* + **4 PIO-style engines**, 8 GPIO.

- The **engines** execute tiny, deterministic, cycle-accurate programs (1 instruction/cycle, optional
  side-set each cycle) — this is what hits protocol timing.
- The **sequencer** is a small FSM (not a general CPU): program load, engine enable/PC, clock-divider and
  pin-map configuration, FIFO DMA assist, IRQ vectoring.
- Pure PIO (A) struggles with multi-step protocol state; pure CPU (B) cannot hit single-cycle pin timing.
  C gets both cheaply.

## 2. Top-level blocks

| Block | Notes |
|---|---|
| `engines[0..3]` | PIO-style state machines (see §4) |
| `imem` | 64 × 16-bit shared instruction SRAM, 16-bit PC per engine (address wraps within a configured window) |
| `sequencer` | config FSM + register file (see §9) |
| `cfg_port` | 4-pin serial configuration/load port (§9), time-muxed on `uio[7:4]` |
| `gpio` | 8 pins, mapped per-engine to in/out/set/side-set bases |

## 3. Instruction encoding (16-bit)

```
 [15:13] opcode (3)
 [12:8]  delay / side-set field (5)
 [7:0]   operand (split per opcode, below)
```

If `side_set_count = k` (0..5), the **top k bits** of `[12:8]` are the side-set value; the remaining
`5-k` bits are the post-instruction **delay** (0..31). With no side-set, the full 5 bits are delay.
The **divider** (§6) is the primary timing knob; delay is fine trim. A `JMP X--` loop gives arbitrary gaps.

| Op | Code | Operand split | Semantics |
|---|---|---|---|
| `JMP` | 000 | `[7:5]` cond, `[4:0]` addr | branch to `addr` if `cond` |
| `WAIT` | 001 | `[7:6]` src, `[5]` pol, `[4:0]` idx | stall until `(src[idx] == pol)` |
| `IN` | 010 | `[7:5]` src, `[4:0]` n | shift `n` bits from `src` into ISR |
| `OUT` | 011 | `[7:5]` dst, `[4:0]` n | shift `n` bits from OSR to `dst` |
| `PUSH/PULL` | 100 | `[7]` block, `[6]` iffull/ifempty, `[5]` push/pull, `[4:0]` 0 | FIFO transfer |
| `MOV` | 101 | `[7:5]` dst, `[4]` op, `[3:0]` src | move `src` to `dst` |
| `IRQ` | 110 | `[7]` wait, `[6]` clear/set, `[5]` rel/abs, `[4:0]` idx | set/clear/wait on IRQ flag |
| `SET` | 111 | `[7:5]` dst, `[4:0]` imm | `dst = imm` (5-bit) |

`JMP` conditions: `000` always, `001` `!X`, `010` `X--`, `011` `!Y`, `100` `Y--`, `101` `X!=Y`,
`110` `PIN`, `111` `!OSRE`.

`IN` sources: `pins, x, y, null, isr, osr`. `OUT` destinations: `pins, x, y, null, pindirs, pc, isr, exec`.
`MOV` sources: `pins, x, y, null, isr, osr, status`; with `op`: `normal, invert(!), reverse(::)`.
`WAIT` sources: `gpio, pin, irq`.

## 4. Engine (per state machine ×4)

State: `PC` (16-bit, wrapped to the engine's `[wrap_top:wrap_bottom]` window), `X` (32-bit), `Y` (32-bit),
`OSR` (32-bit output shift register), `ISR` (32-bit input shift register), `TXF` FIFO (4-deep × 32),
`RXF` FIFO (4-deep × 32), `IRQ` view.

Config registers (per engine, set by the sequencer):

- `CLKDIV` — 16-bit integer + 8-bit fractional divisor; engine advances one instruction every
  `div` system clocks.
- `SHIFTCTRL` — `OUT_SHIFTDIR`/`IN_SHIFTDIR` (right = LSB-first **default**, left = MSB-first for SPI/I²C),
  autopull/autopush enable + thresholds, `JOIN_TXF/RXF`.
- `PINCTRL` — `IN_BASE/COUNT`, `OUT_BASE/COUNT`, `SET_BASE/COUNT`, `SIDESET_BASE/COUNT`,
  `SIDESET_OPT`, and **`OPEN_DRAIN[7:0]`** (per-pin; a driven `1` releases the pin — I²C open-drain in one
  cycle instead of toggling PINDIRS).
- `EXECCTRL` — `WRAP_TOP/BOTTOM`, `STATUS_SEL/N`, `JMP_PIN`, optional `SIDE_PINDIR` mode.

## 5. Pin model

8 GPIO. Each engine maps, independently:

- **IN**: a contiguous window `[IN_BASE, IN_BASE+IN_COUNT)` of GPIO sampled into the ISR.
- **OUT / SET**: a window written by `OUT`/`SET PINS`.
- **SET PINDIRS**: a window for direction (I²C fallback open-drain).
- **SIDESET**: a window written on *every* instruction cycle (0..5 bits).

A pin can be shared by engines; the last writer within a cycle wins (document this — firmware should
assign disjoint pin ownership per protocol).

## 6. Clock & timing

One system clock `clk_hz` (Tiny Tapeout `clock_hz` in `info.yaml`). Each engine divides it by
`CLKDIV` (int + frac) to get `engine_hz`. Firmware computes
`div = clk_hz / (baud * cycles_per_bit)` — **never hard-code a delay**; the divider is per-protocol.
10 Mbit needs `engine_hz ≥ ~40 MHz`; pick `clk_hz` accordingly (a spec target, not a firmware hack).

## 7. FIFOs

4-deep TX and RX per engine (RP2040-proven depth; deepen only if area allows).

- **PUSH/PULL**: `block/noblock`, `iffull/ifempty`.
- **Autopull/autopush**: thresholds in `SHIFTCTRL` so `OUT`/`IN` auto-refill/flush without explicit
  PUSH/PULL.
- **Overrun policy (RX)**: default **non-blocking push-if-full = drop the byte + set a sticky overrun IRQ**
  (polled/cleared by firmware). A blocking RX that deadlocks a protocol is worse than a dropped byte.
  **TX default blocking** (back-pressure).

## 8. Interrupts

8 shared IRQ flags; `IRQ` sets/clears/waits; `WAIT IRQ` lets engines synchronise (cross-engine trigger,
e.g. SPI-master + chip-select engine). Rel/abs addressing as in PIO.

## 9. Sequencer control & firmware loading

Register-mapped control port (inside the chip):

- `IMEM_WRITE` (`addr[5:0]`, `instr[15:0]`)
- `SMx_CLKDIV`, `SMx_EXECCTRL`, `SMx_SHIFTCTRL`, `SMx_PINCTRL`
- `SMx_ENABLE`, `SMx_PC`, `TXF_PUSH`, `RXF_POP`, `IRQ_CLEAR`

**Post-fab load (Tiny Tapeout has no host bus):** a 4-pin serial **config port** time-muxed on
`uio[7:4]` when `cfg_load=1`:

- pins: `cfg_clk`, `cfg_din`, `cfg_load`, `cfg_done`
- frame: `cmd[7:0]` + `payload[31:0]` (cmd selects IMEM write / SM register / enable / done)
- at runtime `cfg_load=0` and all 8 GPIO are free for protocols.

This is the **one open ARCH choice**: share `uio[7:4]` (proposed) vs reserve 4 dedicated config pins.

## 10. Area plan

Budget ~24K cells. Rough allocation: 4 engines + shared 64×16 IMEM (SRAM) + FIFOs + sequencer.
Fixtures to keep in check: 64×16 IMEM as **SRAM**, not flops; 4-deep FIFOs; shared IMEM.
**Fallback order if over budget:** 4 → 2 engines → drop sequencer to a fixed FSM.

## 11. What we do differently (competition differentiators)

1. `CLKDIV` + **cycle-count compare** for long exact delays without delay-slot juggling.
2. Cross-engine `IRQ` triggers so protocols chain (SPI master + CS engine).
3. Optional 2-word immediate escape for compact firmware constants.
4. Per-pin `OPEN_DRAIN` (I²C in one cycle/bit).
5. Serial config port for genuine post-fab reprogrammability.

## 12. Open items

- Cerebro/Ash: confirm encoding field widths, IMEM 64×16 vs 2×32, 4 vs 2 engines for area.
- Config port: shared `uio[7:4]` vs dedicated pins.
- Milestone 1 (UART TX) proceeds independently on the template (Vision/Wheatley).

_This spec is the ARCH/ISA contract; RTL and firmware target it. Changes require a board ACK._