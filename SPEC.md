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
| `engines[0..NENG-1]` | PIO-style state machines; `NENG` = 2..4, **default 3** (see §4) |
| `imem` | **NENG banks × 32 × 16-bit** (default 3 → 96×16); each engine owns one 32-instruction bank; PC is 5-bit **within** the bank; `JMP addr [4:0]` is within-bank |
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
| `WAIT` | 001 | `[7]` pol, `[6:5]` src, `[4:0]` idx | stall until `(src[idx] == pol)` |
| `IN` | 010 | `[7:5]` src, `[4:0]` n | shift `n` bits from `src` into ISR |
| `OUT` | 011 | `[7:5]` dst, `[4:0]` n | shift `n` bits from OSR to `dst` |
| `PUSH/PULL` | 100 | `[7]` 0 push/1 pull, `[6]` iffull/ifempty, `[5]` block, `[4:0]` 0 | FIFO transfer |
| `MOV` | 101 | `[7:5]` dst, `[4:3]` op, `[2:0]` src | move `src` to `dst` (`op`: 00 none, 01 invert `!`, 10 reverse `::`) |
| `IRQ` | 110 | `[7]` wait, `[6]` clear/set, `[5]` rel/abs, `[4:0]` idx | set/clear/wait on IRQ flag |
| `SET` | 111 | `[7:5]` dst, `[4:0]` imm | `dst = imm` (5-bit) |

`JMP` conditions: `000` always, `001` `!X`, `010` `X--`, `011` `!Y`, `100` `Y--`, `101` `X!=Y`,
`110` `PIN`, `111` `!OSRE`.

`IN` sources: `pins, x, y, null, isr, osr`. `OUT` destinations: `pins, x, y, null, pindirs, pc, isr, exec`.
`MOV` sources (3-bit, up to 8): `pins, x, y, null, isr, osr, status`; with 2-bit `op`: `none, invert(!), reverse(::)`.
`WAIT` sources: `gpio, pin, irq`.

### Numeric selector codes (NORMATIVE — asm.py, RTL and firmware MUST use these)

Operand **A** = `[7:5]` (3 bits); Operand **B** = `[4:0]` (5 bits), unless noted. These resolve the
asm/RTL divergence Gort found — do not invent codes.

| Field | Codes |
|---|---|
| `JMP` cond (`A`) | 0 always · 1 `!X` · 2 `X--` · 3 `!Y` · 4 `Y--` · 5 `X!=Y` · 6 `PIN` · 7 `!OSRE` |
| `JMP` addr (`B[4:0]`) | 0..31, within this engine's 32-instruction bank |
| `WAIT` | `[7]`=polarity (1=wait-high) · `[6:5]`=src (0 gpio, 1 pin, 2 irq) · `[4:0]`=index |
| `IN` src (`A`) | 0 pins · 1 x · 2 y · 3 null · **6 isr · 7 osr** (4,5 reserved) |
| `OUT` dst (`A`) | 0 pins · 1 x · 2 y · 3 null · 4 pindirs · 5 pc · 6 isr · 7 exec |
| `MOV` dst (`A`) | 0 pins · 1 x · 2 y · 3 null · **4 exec · 5 pc · 6 isr · 7 osr** |
| `MOV` src (`B[2:0]`) | 0 pins · 1 x · 2 y · 3 null · **4 reserved · 5 status · 6 isr · 7 osr** |
| `MOV` op (`B[4:3]`) | 00 none · 01 invert `!` · 10 reverse `::` · 11 reserved |
| `SET` dst (`A`) | 0 pins · 1 x · 2 y · **4 pindirs** (3,5,6,7 reserved) |
| `IRQ` (`A`) | `A[2]`=wait · `A[1]`=clear(1)/set(0) · `A[0]`=relative(1)/absolute(0) · `B[2:0]`=index 0..7 |
| `PUSH/PULL` | `[7]`=0 push / 1 pull · `[6]`=iffull/ifempty · `[5]`=block(1)/noblock(0) · `[4:0]`=0 |

**WAIT polarity:** `WAIT <src>, <pol>, <idx>` — `[7]` = polarity (1=high), `[6:5]` = src, `[4:0]` = index.

**RP2040 conformance:** these three fields follow the RP2040 datasheet exactly (so `pioasm`/known-good
PIO test vectors apply): WAIT `[7]`=pol/`[6:5]`=src; PUSH/PULL `[7]`=0 push/1 pull/`[5]`=block;
MOV src `4`=reserved/`5`=status/`6`=isr/`7`=osr.

**Deviation (stated, not RP2040):** the `IRQ` instruction uses our own layout — `A[2]`=wait,
`A[1]`=clear, `A[0]`=relative, `B[2:0]`=index (0..7). Do **not** assume `pioasm` IRQ encodings apply.

**Delay field decode (normative):** `[12:8]` = side-set value in the **top** `side_set_count` bits,
followed by delay in the low `5 - side_set_count` bits. The integer delay = that many engine cycles.
RTL MUST decode this field (it is part of the ISA, not a comment).

## 4. Engine (per state machine ×4)

State: `PC` (5-bit within the engine's 32-instruction bank; wrapped to `[wrap_top:wrap_bottom]`),
`X` (32-bit), `Y` (32-bit), `OSR` (32-bit output shift register), `ISR` (32-bit input shift register),
`TXF` FIFO (4-deep × 32), `RXF` FIFO (4-deep × 32), `IRQ` view. X/Y/OSR/ISR are **32-bit** (OSR/ISR
must be, for shift ops); X/Y may drop to 16-bit only under hard area pressure.

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
- **Overrun policy (RX)**: default **non-blocking push-if-full = drop the byte + set a sticky
  `RXOVER` bit in the engine's FIFO-status register `FSTAT`** (cf. RP2040 `FDEBUG.RXOVER`) — **not** a
  user IRQ. Sticky: cleared only by an explicit cfg `FSTAT_CLEAR`, never by `IRQ clear`. Also cfg-readable
  (M3.2). A blocking RX that deadlocks a protocol is worse than a dropped byte.
  **TX default blocking** (back-pressure). A stall is a *status* (`stalled`/`FSTAT`), never a user IRQ.

## 8. Interrupts

8 shared IRQ flags (`0..7`), **owned exclusively by firmware**: `IRQ` sets/clears/waits; `WAIT IRQ`
lets engines synchronise (cross-engine trigger, e.g. SPI-master + chip-select engine). Rel/abs
addressing as in PIO.

**User IRQs are NOT status signals.** FIFO empty/full/stall and RX `OVERRUN` live in the engine's
`FSTAT` register (readable via cfg, M3.2) and must never alias a user IRQ flag. In particular a
blocking/noblock stall or an RX overrun must **not** set any of IRQ 0..7 — otherwise firmware
`wait irq,1,0` / `irq clear 0` would be woken or wiped by another engine's FIFO state.

## 9. Sequencer control & firmware loading

Register-mapped control port (inside the chip):

Register-mapped control port (inside the chip). `cmd 0x02 SM_REG` payload = `sm[1:0]<<28 | reg[3:0]<<24 | value[23:0]`; registers:

- `reg 0` CLKDIV (16-bit int)
- `reg 1` PINCTRL-A = `open_drain[7:0] | in_base[10:8] | out_base[13:11] | set_base[16:14]`
- `reg 2` SHIFTCTRL
- `reg 3` ENABLE
- `reg 4` PC
- `reg 5` PINCTRL-B = `in_count[3:0] | out_count[7:4] | set_count[11:8] | side_set_count[14:12] | sideset_base[17:15]`

PINCTRL is **two writes** (`reg 1` + `reg 5`) because the 24-bit value cannot hold 3 bases + 3 counts +
`open_drain[7:0]` + `side_set_count` (29 bits).

- `cmd 0x01 IMEM_WRITE` payload = `addr[6:0]` (bank `[6:5]` + offset `[4:0]`) `<<16 | instr[15:0]`
- `cmd 0x03 TXF_PUSH` payload = `sm[1:0]<<28 | word[27:0]`
- `cmd 0x04 DONE` (start engines)
- `RXF_POP` / `IRQ_CLEAR` / status readback = M3.2 (via the bidirectional cfg_dout).

**Post-fab load (Tiny Tapeout has no host bus):** a 4-pin serial **config port** time-muxed on
`uio[7:4]` when `cfg_load=1`:

- pins: `cfg_clk`, `cfg_din`, `cfg_load`, `cfg_done`
- frame: `cmd[7:0]` + `payload[31:0]` (cmd selects IMEM write / SM register / enable / done)
- at runtime `cfg_load=0` and all 8 GPIO are free for protocols.

**DECIDED:** share `uio[7:4]` (all 8 GPIO free at runtime). `cfg_din` is **bidirectional**
(`uio[5]` = cfg_din/cfg_dout): write cmds drive the chip, read cmds make the chip drive it. The config
FSM sets `uio_oe[5]` for reads only; at runtime the engine owns the pin. **Turn-around gap required:**
the host must release `uio[5]` before the chip drives it on a read command (fixed half-phase rule) so
the two never drive the same pin in one `cfg_clk` phase.

## 10. Area plan

Budget is **mapped IHP sg13g2 area**, not generic gate count. 6×4 usable ≈ 750,000 µm².
Measured (M3.1 top, pre-PnR, per-engine PINCTRL decoded): shipped default **NENG=3, XY_W=32, FIFO=4 =
282,452 µm² (~38%)**; `NENG=4` same config = 375,627 µm² (~50%). At a typical ~1.5-2× PnR/CTS growth
that is ~57-76% (3 engines, fits) vs ~75-100% (4 engines, risky) — hence **default NENG=3**.
Levers if PnR is tight: `FIFO_DEPTH 4→2` (~-7%), `XY_W 32→16` (~-5%), then fewer engines. All are
compile-time params, no rewrite (FIFO depth change needs a SPEC §7 revision + firmware re-check).

Fixtures: IMEM/FIFOs synthesise as flops (not SRAM) — an SRAM macro would shrink area further.

## 11. What we do differently (competition differentiators)

1. `CLKDIV` + **cycle-count compare** for long exact delays without delay-slot juggling.
2. Cross-engine `IRQ` triggers so protocols chain (SPI master + CS engine).
3. Optional 2-word immediate escape for compact firmware constants.
4. Per-pin `OPEN_DRAIN` (I²C in one cycle/bit).
5. Serial config port for genuine post-fab reprogrammability.

## 12. Open items

- Cerebro/Ash: confirm encoding field widths and 4 vs 2 engines for area. (IMEM resolved: 4×32×16, one bank per engine.)
- Config port: shared `uio[7:4]` vs dedicated pins.
- Milestone 1 (UART TX) proceeds independently on the template (Vision/Wheatley).

_This spec is the ARCH/ISA contract; RTL and firmware target it. Changes require a board ACK._