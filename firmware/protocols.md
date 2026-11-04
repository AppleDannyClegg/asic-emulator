# Protocol programs — first drafts (TARS, firmware slice)

ISA-agnostic first drafts for the PIO-style engines, written against Legion's proposed
16-bit PIO-proven ISA (board 17:14:35): `JMP / WAIT / IN / OUT / PUSH-PULL / MOV / IRQ / SET`,
side-set + delay in bits [7:5], per-engine OSR/ISR (32-bit), X/Y scratch, 4-deep FIFOs,
16-bit clock divider. Port to the frozen ISA once ARCH/ISA confirms.

Timing model assumed: **1 instruction/cycle**; `[n]` = n extra delay cycles; the engine's
clock divider makes one engine cycle = `div` system clocks. So a bit period of `T` system
clocks = `T/div` engine cycles, and the per-instruction delay `[d]` is chosen so that
`(1 + d)` engine cycles = the required span. **All `[d]` values below are placeholders** —
they are a function of `div`, `clock_hz` and the protocol rate, and must be computed, not
hardcoded (see "Timing" below).

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
- **MSB-first is the gotcha.** PIO `OUT` shifts LSB-first. For MSB-first either
  (a) `MOV` with the `reverse` modifier to bit-reverse the OSR before shifting, or
  (b) shift the OSR left and read bit 7 into X, or (c) define the protocol program with a
  bit-reversed input word. Recommend (a): `mov osr, !osr` style reverse in the PIO ISA.
- Mode 1/2/3 differ only in clock polarity/phase: swap which `set pins` drives the sample
  edge. Parameterise with side-set/`set` rather than duplicating the program.
- CS is per-transfer here; a multi-byte device select wraps several `spi_txrx` calls.

## 4. I2C master (7-bit address, standard mode)

Open-drain: SCL/SDA are outputs driven low for 0 and released (input, pulled up) for 1.
In the engine model this means switching `pindirs` for the 1/0 phases (or a tri-state
side-set), because I2C has no push-pull high.

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

## Open questions for ARCH/ISA (blocking exact encodings)

1. **Bit order**: does `OUT`/`IN` support a `reverse` modifier (needed for SPI/I2C MSB-first)?
2. **Open-drain**: is there a per-pin `pindirs`/tri-state side-set for I2C, or must the
   sequencer emulate it?
3. **Delay encoding**: is `[d]` a fixed 3-bit field (max 7)? If so, long bit periods need a
   divider or a `JMP X--` delay loop — confirm which.
4. **FIFO depth/back-pressure**: `pull block` vs `noblock` semantics, and RX overrun policy.
5. **Program load**: how the sequencer writes engine IMEM + initialises PC/divider/pin map.

## Next

- Milestone 1 is RTL (UART TX hardcoded on a pin). The UART TX program above is the
  firmware equivalent once the engine exists; it is the acceptance test for the ISA.
- Port each program to real assembly when the ISA freezes (Legion/Cerebro/Ash review).
