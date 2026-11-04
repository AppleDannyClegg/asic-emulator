# Protocol programs — first drafts (TARS, firmware slice)

First drafts for the PIO-style engines, written against Legion's ISA (board 17:14:35, corrected
17:19:42): 16-bit RP2040-PIO layout `[15:13] opcode / [12:8] delay+side-set (5-bit, max 31)
/ [7:5] operand-A / [4:0] operand-B`; `JMP / WAIT / IN / OUT / PUSH-PULL / MOV / IRQ / SET`;
per-engine OSR/ISR (32-bit), X/Y scratch, 4-deep FIFOs, **per-SM 16-bit clock divider
(int+frac)**, per-SM **shift direction** (right=LSB-first for UART, left=MSB-first for
SPI/I2C). Port to real assembly once Cerebro/Ash confirm the freeze.

Timing model: **1 instruction/cycle**; `[n]` = n extra delay cycles (5-bit field, max 31);
the per-SM clock divider makes one engine cycle = `div` system clocks. So a bit period of
`T` system clocks = `T/div` engine cycles. **The divider is the primary timing knob** — `[d]`
is only fine trim (max 31). Do not hardcode `[d]`; compute `div` from `clock_hz`/rate
(see "Timing").

Convention: TX/MOSI/SCL/SDA are side-set pins; the side-set field drives them on every
instruction (PIO side-set). RX/MISO are read with `IN pins`.

---

## 1. UART TX, 8N1 (Milestone 1 target)

Bit period `T`; start = 0, data LSB-first, stop = 1. Idle = 1.

```
uart_tx:
    pull block            ; OSR <- next byte (from TX FIFO)
    set pindirs, 1        ; TX pin = output
    set x, 7              ; 8 data bits
    set pins, 0 [T-2]     ; START bit (0), hold T cycles
data_loop:
    out pins, 1 [T-2]     ; shift OSR bit0 -> TX pin, hold T cycles
    jmp x-- data_loop [T-2]
    set pins, 1 [T-2]     ; STOP bit (1)
    jmp uart_tx           ; next byte (loop; PULL blocks if FIFO empty)
```

Notes:
- `OUT pins, 1` shifts the **LSB** of OSR to the pin; UART sends LSB-first — matches.
- `[T-2]` assumes the instruction itself takes 1 cycle and the pin is stable for the rest;
  tune per divider. If `T < 2` engine cycles the engine is too slow for the baud — raise
  the engine clock / lower the divider.
- The stop bit can be shortened to 1 cycle (no delay) at the cost of idle recovery time;
  keep a full bit for correctness.

## 2. UART RX, 8N1

Sample the start bit at its centre, then each data bit at the bit centre.

```
uart_rx:
    wait 0 pin 0          ; wait for START (line low)
    set x, 7
    ; align to centre of bit 0: 1.5 T from the falling edge = 0.5 T after start centre
    wait 1 pin 0 [T + T/2 - 1]   ; (start centre) then half a bit into bit 0
    in pins, 1 [T-2]      ; sample data bit 0
    jmp x-- uart_rx_sample [T-2]
    ; stop bit: sample/verify high at its centre
    in pins, 1 [T-2]
    push block            ; ISR -> RX FIFO
    jmp uart_rx
```

Notes:
- The first `wait 1 pin 0 [..]` is awkward in one instruction; in practice use a delay chain
  or split into `wait` + `set`/`jmp` with `[d]` to land at the centre. To be finalised once
  the delay/side-set encoding is fixed.
- Optional: `push iffull` to drop on overrun, or `push block` to back-pressure.

## 3. SPI master, mode 0 (CPOL=0, CPHA=0), MSB-first

Pins: SCLK, MOSI (out), CS (side-set); MISO (in). 8 bits per transfer.

```
spi_txrx:
    pull block            ; OSR <- byte to send
    set x, 7
    set pins, 0           ; CS low
bit_loop:
    out pins, 1 [0]       ; MOSI <- MSB of remaining OSR? (see note)
    set pins, 1 [0]       ; SCLK high (leading edge)
    in pins, 1 [0]        ; sample MISO
    set pins, 0 [0]       ; SCLK low (trailing edge)
    jmp x-- bit_loop
    set pins, 1           ; CS high
    push block            ; ISR -> RX FIFO
    jmp spi_txrx
```

Notes:
- **MSB-first is handled by the engine's shift direction** (Legion 17:19:42): set this SM's
  SHIFTCTRL shift-direction to *left* (MSB-first). No software reverse loop, no pre-reversed
  word. UART uses the default *right* (LSB-first) on its engine.
- Mode 1/2/3 differ only in clock polarity/phase: swap which `set pins` drives the sample
  edge. Parameterise with side-set/`set` rather than duplicating the program.
- CS is per-transfer here; a multi-byte device select wraps several `spi_txrx` calls.

## 4. I2C master (7-bit address, standard mode)

Open-drain: SCL/SDA are driven low for 0 and released (input, pulled up) for 1. Legion
17:19:42: no native open-drain; firmware does it with `SET PINDIRS` (drive low = pindir out
+ `SET PINS 0`; release = pindir in). Because that costs cycles at 400 kHz, a per-pin
`OPEN_DRAIN` mode bit in PINCTRL is proposed ("do differently") so a pin auto-releases when
driven 1 — if that lands, the programs below simplify to a single side-set per bit.

```
; START: SDA 1->0 while SCL high
i2c_start:
    set pindirs, 0        ; release SDA (high via pull-up)
    set pindirs, ...      ; release SCL
    set pindirs, ...      ; pull SDA low while SCL high
    ; then SCL low
```

Because I2C needs per-bit open-drain direction changes, it is the most engine-demanding of
the three and the best argument for side-set + `pindirs` control and for the **sequencer**
to manage ACK polling. Full ACK/clock-stretch handling to be written once the ISA's pin
direction / open-drain support is decided.

```
; byte write, MSB-first, with ACK
i2c_write_byte:
    pull block
    set x, 7
i2c_bit:
    ; drive SDA = MSB (release=1 / pull=0), SCL high, SCL low
    out ...               ; MSB-first (see SPI note)
    jmp x-- i2c_bit
    ; 9th clock: release SDA, sample ACK
    in pins, 1
    push block
```

---

## Timing (all programs)

Given `clock_hz` (e.g. 50 MHz) and protocol rate `baud`:
- `div` (16-bit) = `clock_hz / (baud * cycles_per_bit)`, where `cycles_per_bit` = the
  number of engine cycles you allocate per bit (e.g. 8). Round **down** and absorb the
  remainder in the `[d]` delays, or use a fractional divider if the ISA offers one.
- For 115200 baud at 50 MHz: `div ≈ 50e6/(115200*8) ≈ 54.25` → div 54, and one extra
  system-clock of jitter per bit. At 10 Mbit Ethernet this is far tighter — likely needs
  a faster engine clock and/or a dedicated divider per engine.
- **Do not hardcode `[d]`**: compute it from `div` and the bit count so the same program
  works at any rate. A `SET` of a scratch register + `JMP X--` delay loop is the portable
  form; `[d]` is only exact for one (rate, clock) pair.

## ISA answers (Legion 17:19:42) — resolved

1. **Bit order** — per-SM SHIFTCTRL shift direction (right=LSB UART, left=MSB SPI/I2C);
   `MOV` also has a bit-reverse variant for odd cases. No per-instruction reverse needed.
2. **Open-drain** — no native mode; firmware uses `SET PINDIRS`. Proposed PINCTRL
   `OPEN_DRAIN` bit would remove the cycle cost at 400 kHz.
3. **Delay** — 5-bit field (max 31); long periods come from the 16-bit per-SM divider
   (int+frac), not the delay field.
4. **FIFO** — block/noblock + ifempty/iffull, optional autopull/autopush thresholds.
   UART RX: blocking PUSH back-pressures (correct); lossy sources use noblock.
5. **Program load** — sequencer config port (IMEM/PC/divider/pin map); see board 17:20:16
   for the memory-mapped `{engine_id, reg, value}` proposal.

Remaining to confirm before freeze: Cerebro/Ash review of the corrected ISA, the PINCTRL
open-drain bit, and the config-port shape.

## Next

- Milestone 1 is RTL (UART TX hardcoded on a pin). The UART TX program above is the
  firmware equivalent once the engine exists; it is the acceptance test for the ISA.
- Port each program to real assembly when the ISA freezes (Legion/Cerebro/Ash review).

---

## Concrete UART TX for ISA v0.1 (TARS, Legion 17:20:37 freeze)

Field layout: `[15:13] opcode | [12:8] delay/side-set | [7:5] operand-A | [4:0] operand-B`.
Side-set takes the MSBs of `[12:8]`; with `side_count = 1` (drive the TX pin each
instruction) the side-set bit is `[12]` and the delay is `[11:8]` (0-15). Opcodes:
`JMP=000 WAIT=001 IN=010 OUT=011 PUSH-PULL=100 MOV=101 IRQ=110 SET=111`.

Program (TX pin = side-set bit 0; `div` set for the bit period; `T` = engine cycles/bit):

```
; --- uart_tx (8N1), side-set = TX pin, shift direction RIGHT (LSB-first) ---
    pull block              ; OSR <- TX FIFO
    set pindirs, 1          ; TX pin = output
    set x, 7                ; 8 data bits
    set pins, 0 [T-2]       ; START (0)
data:
    out pins, 1 [T-2]       ; shift OSR bit0 -> TX
    jmp x-- data [T-2]      ; loop 8x
    set pins, 1 [T-2]       ; STOP (1)
    jmp uart_tx             ; next byte
```

Field breakdown (side_count=1, delay d, side bit s):

| # | mnemonic            | op  | side+delay [12:8] | A [7:5]        | B [4:0]        |
|---|---------------------|-----|-------------------|----------------|----------------|
| 0 | `pull block`        | 100 | `s:d`             | `000` block    | `000` PULL     |
| 1 | `set pindirs, 1`    | 111 | `s:0`             | `100` pindirs  | `00001`        |
| 2 | `set x, 7`          | 111 | `s:0`             | `001` x        | `00111`        |
| 3 | `set pins, 0 [T-2]` | 111 | `s:(T-2)`         | `000` pins     | `00000`        |
| 4 | `out pins, 1 [T-2]` | 011 | `s:(T-2)`         | `000` pins     | `00001`        |
| 5 | `jmp x-- data [T-2]`| 000 | `s:(T-2)`         | `010` x--      | `<data addr>`  |
| 6 | `set pins, 1 [T-2]` | 111 | `s:(T-2)`         | `000` pins     | `00001`        |
| 7 | `jmp uart_tx`       | 000 | `s:0`             | `000` always   | `0`            |

Constraints / open items for the encoder:
- `[d]` is 4 bits when `side_count=1` (max 15). A 115200 baud bit at a 50 MHz engine
  needs `T = 50e6/(115200*div)`; with `div=8`, `T≈54` engine cycles — **larger than 15**,
  so the per-bit span must come from `div` (engine cycles), not `[d]`. Set `div` so that
  `T = 1 + d` for a small `d` (e.g. `div = clock_hz/(baud*T)` with `T=8`, `d=6`).
- Exact `operand-A`/`operand-B` codes follow the frozen tables (PIO-style); the values
  above are the intended meanings, to be checked against the assembler once written.
- If `side_count=0`, the TX pin must be driven by `SET PINS`/`OUT PINS` and the full
  5-bit `[12:8]` becomes delay — simpler timing, one extra instruction per bit.

Next: a tiny assembler (`firmware/asm.py`) that emits the 16-bit words for this program
and a disassembler round-trip test, once Cerebro/Ash confirm the operand tables.
