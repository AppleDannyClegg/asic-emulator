# asic-emulator — Jane Street "protocol emulator ASIC" competition

Open-source, general-purpose **protocol emulator ASIC**: a small programmable engine that
bit-bangs protocols (UART/SPI/I2C first; USB-LS, 10 Mbit Ethernet, JTAG, SWD, PS/2, CAN stretch)
**in firmware**, reprogrammable after fabrication. Deadline **18 Jan 2027**; prize = Jane Street
pays to tape out the best designs (Mar 2027 shuttle).

- Brief: https://blog.janestreet.com/protocol-emulator-asic-competition/
- Target: IHP **130 nm CMOS5L** via Tiny Tapeout; `ttihp-verilog-template` (cmos5l branch).
- Budget: **6×4 tiles** ≈ 0.7 mm² nominal, **~24K logic cells** (~1K/tile).
- Open source; build in public; **no secrecy** (unlike the puzzle).
- They explicitly welcome **verification rigour** (formal, constrained-random, AI-assisted).

## Architecture options (default C)

- **A — RP2040-PIO-style:** N small programmable state machines (JMP/WAIT/IN/OUT/PUSH/PULL/MOV/SET
  + side-set), per-engine FIFOs, clock dividers, flexible pin map. Proven for UART/SPI/I2C.
- **B — PRU-style single tiny CPU:** RISC + pin/timing ops. More general; harder timing/area.
- **C — HYBRID (recommended):** one small sequencer + 2–4 PIO-like engines, shared instruction
  SRAM, 8 GPIO.

Chosen: **TBD by the team (proposal + rationale on the board).**

## Interfaces

- Tiny Tapeout pins: `ui[7:0]` in, `uo[7:0]` out, `uio[7:0]` bidir, `clk`, `rst_n`, `ena`.
- Config load: host writes engine programs/FIFO data over a config port (protocol TBD).

## Milestones

1. **UART TX on a pin** via the cmos5l template (their suggested ramp) — RTL + a cocotb/verilog TB.
2. **Programmable engine**: instruction memory + ISA + FIFOs; UART written as a program.
3. **SPI, I2C** programs; stretch goals.
4. **Verification**: formal (SymbiYosys) on the engine control, constrained-random on the ISA,
   cocotb protocol TBs.
5. **Fit**: synth early, cell-area + timing checks against the 6×4 budget; PnR.

## Open questions / risks

- **Tile size RESOLVED (TARS 17:16:16):** `6x4` is valid for IHP cmos5l. The validator (`project_info.py:113`) checks against `tt-support-tools/tech/ihp-sg13cmos5l/tile_sizes.yaml`, which lists `6x4` (bbox 1289.28 x 710.64 um = ~0.916 mm2 gross); the template's `info.yaml` comment was stale. `info.yaml` set to `6x4`. (The blog's ~0.7 mm2 is usable-after-overhead.)
- Instruction memory: SRAM vs flip-flops (area).
- Clock: emulator clock vs protocol timing (dividers/cycle counter).
- Determinism: engines must hit protocol timing precisely.

## Roles (board)

- ARCH/ISA: Legion, Ash, Cerebro
- RTL core: Vision, Wheatley
- Instr memory / config load: Cerebro
- Verification: Edi, GERTY, TARS, Jocasta
- Firmware: TARS, Ash
- Fit/synth/PnR: Vision, Cerebro
- Integrator/PM: Weyland
