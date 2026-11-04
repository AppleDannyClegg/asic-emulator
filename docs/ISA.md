# ISA + engine model — **FROZEN v0.2** (Legion, board 4 Nov 2026; Cerebro/Ash objection window)

Architecture **C: a minimal sequencer + 4 PIO-style engines**, shared instruction SRAM, up to 8 GPIO.
Target IHP 130 nm CMOS5L via Tiny Tapeout, **6×4 tiles** (~0.9 mm² gross, ~24K cells).

## Engine (per PIO-like state machine)

- 16-bit PC; 32-bit OSR + ISR shift registers; 4-deep TX / 4-deep RX FIFO; 16-bit clock divider
  (int + frac); 8-pin in/out/set/side-set mapping; 4 IRQ flags; stall-on-blocking.
- 1 instruction/cycle; optional side-set every cycle.
- **SHIFTCTRL** per engine: OUT/IN shift **direction** (right = LSB-first default; left = MSB-first).
  UART 8N1 = right/LSB; SPI/I2C = left/MSB. MOV has a bit-reverse variant for odd cases.

## 16-bit instruction layout (RP2040-PIO)

```
[15:13] opcode (3)
[12:8]  delay / side-set (5, max 31)   <- shared; side-set takes the high bits
[7:5]   operand A (3)
[4:0]   operand B (5)
```

**Correction:** delay is **5 bits**, not 3. Long bit periods come from the per-engine **16-bit
clock divider** (set `div = engine_clk / (baud × cycles_per_bit)`), never from hardcoded delay.
10 Mbit operation needs a fast engine clock — a spec target, not a firmware hack.

## Opcodes

`JMP`(000) / `WAIT`(001) / `IN`(010) / `OUT`(011) / `PUSH`-`PULL`(100) / `MOV`(101) / `IRQ`(110) / `SET`(111)

Instruction memory: **64 × 16-bit shared SRAM**, 16-bit PC per engine.
- JMP conds: always, !X, X--, !Y, Y--, X!=Y, PIN, !OSRE.
- WAIT: gpio/pin/irq, polarity.
- IN src: pins/x/y/isr/osr, n bits. OUT dst: pins/x/y/pc/isr/exec, n bits.
- PUSH/PULL: block/noblock, iffull/ifempty. Full RX FIFO + blocking PUSH stalls the engine
  (correct back-pressure for UART); noblock drops/overwrites. Optional autopull/autopush thresholds.
- MOV dst,src: pins/x/y/isr/osr/status + 2-bit op `[4:3]` = none / `!` (not) / `::` (bit-reverse), 3-bit src `[2:0]`. (Encoding: `[7:5]` dst, `[4:3]` op, `[2:0]` src.)
- SET dst: pins/x/y/pindirs, 5-bit immediate.

## I2C open-drain

No native open-drain in PIO. Firmware emulates it with `SET PINDIRS` (drive low = pindir out +
`SET PINS 0`; release = pindir in). At 400 kHz that costs cycles, so **proposal:** a per-pin
`OPEN_DRAIN` mode bit in PINCTRL so a pin auto-releases when driven 1. (Our "do differently" item.)

## Sequencer / config (OPEN QUESTION — ARCH)

Register-mapped control: IMEM write (addr + 16-bit data), `SMx_CLKDIV`/`EXECCTRL`/`SHIFTCTRL`/
`PINCTRL`, `SMx_ENABLE`, TXF push / RXF pop, IRQ clear, then set PC + enable.

**DECIDED (v0.2):** a 4-pin serial **config port** for post-fab load, time-multiplexed on
`uio[7:4]` when `cfg_load=1` so all 8 GPIO are free at runtime. Pins `cfg_clk / cfg_din /
cfg_load / cfg_done`; frame = `cmd[7:0]` + `payload[31:0]` (cmd selects IMEM write / SM register /
enable / done). See `SPEC.md` §9 for the full register/​frame map. `PINCTRL.OPEN_DRAIN[7:0]` is
confirmed as the I2C simplifier (SET PINDIRS remains the fallback).
