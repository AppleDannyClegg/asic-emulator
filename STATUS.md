# STATUS / checkpoint — protocol emulator ASIC

_Last updated 2026-11-04 17:23. Resume-from-here doc: read `PLAN.md`, `docs/ISA.md`, and this file._

## Where we are

- **Repo:** `https://github.com/AppleDannyClegg/asic-emulator` (PUBLIC), local `~/projects/git/asic-emulator`,
  branch `main`. Push with the personal account: `GH_TOKEN=$(/opt/homebrew/bin/gh auth token --user AppleDannyClegg) /opt/homebrew/bin/gh ...`
  (the `~/.local/bin/gh` wrapper maps most dirs to the work EMU — avoid it here).
- **Architecture C:** minimal sequencer + 4 PIO-style engines, 8 GPIO, 64×16 shared IMEM. `docs/ISA.md`.
- **ISA FROZEN v0.1** (Legion): 16-bit, `[15:13] op | [12:8] delay/side-set(5) | [7:5] A(3) | [4:0] B(5)`;
  opcodes JMP/WAIT/IN/OUT/PUSH-PULL/MOV/IRQ/SET; per-engine SHIFTCTRL shift direction; 16-bit divider.
- **Milestone 1 (UART TX):** `src/project.v` + `test/` cocotb TB (Vision) — in progress.
- **Firmware:** `firmware/protocols.md` (UART/SPI/I2C plans, on the frozen ISA) + `firmware/uart_ref.py`
  (bit-level reference, self-test PASS) — TARS.

## Open decisions (block freeze-final + M1)

1. **ISA review** — Cerebro/Ash to object or accept `docs/ISA.md` v0.1.
2. **Config port** — how firmware loads after fab over TT pins (Legion Q5 / TARS 17:20:16): propose a
   serial frame (addr,data) and decide; this sets the GPIO count.
3. **PINCTRL OPEN_DRAIN bit** — a per-pin auto-release (helps I2C at 400 kHz).

## Backlog

- UART RX, SPI mode 0, I2C programs; stretch goals (USB-LS, 10 Mbit Ethernet, JTAG/SWD/PS2/CAN).
- Verification: formal (SymbiYosys) on engine control, constrained-random on the ISA, cocotb protocol TBs.
- Fit: synth early → cell area + timing vs the 6×4 budget; then PnR.

## Roles

ARCH/ISA Legion (+Cerebro/Ash) · RTL Vision/Wheatley · IMEM Cerebro · verification Edi/GERTY/TARS/Jocasta ·
firmware TARS/Ash · fit Vision/Cerebro · integrator Weyland.

## Sibling: the Jane Street ASIC puzzle (DONE)

Solved + proven: `~/projects/git/asic-puzzle-solution` — `verify_solution.py` (exit 0) proves the answer
`(* TWO STARS *)` and the O message-ROM (`EMPTY SKY`/`BIG BANG`/`TRY AGAIN`). Full writeup `SOLUTION.md`.
E2 `The night sky awaits` = the example VCD's two 121-bit words as 11×11 grids, 7-bit LSB-first rows.
E1 `JSC regions` = not in the chip (unsubstantiated). Completion window closed 4 Sep 2026.
