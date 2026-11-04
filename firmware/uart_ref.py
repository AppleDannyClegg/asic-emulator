#!/usr/bin/env python3
"""UART 8N1 reference waveform + test vectors (TARS, firmware/verification).

ISA-independent reference the RTL testbench (Vision) and the firmware UART program
(TARS) can both be checked against. No dependencies.

  uart_tx_bits(byte, bit_cycles, idle=1) -> list[int]   # pin value per system clock
  uart_rx_check(bits, bit_cycles)        -> (byte|None, framing_ok)

Line is idle-high. A frame = START(0) + 8 data bits LSB-first + STOP(1), each held
`bit_cycles` clocks. `bit_cycles` = round(clock_hz / baud) (the engine divider target).

Run: python3 uart_ref.py  -> self-test over all 256 bytes at a few bit periods.
"""
from __future__ import annotations


def uart_tx_bits(byte: int, bit_cycles: int, idle: int = 1) -> list[int]:
    """Return the TX pin level for one 8N1 frame, sampled once per system clock.

    Frame length = 10 * bit_cycles (start + 8 data + stop). LSB-first.
    """
    if not 0 <= byte <= 0xFF:
        raise ValueError("byte must be 0..255")
    if bit_cycles < 1:
        raise ValueError("bit_cycles must be >= 1")
    out: list[int] = [0] * bit_cycles                      # START
    for i in range(8):                                      # data, LSB first
        out += [((byte >> i) & 1)] * bit_cycles
    out += [1] * bit_cycles                                 # STOP
    return out


def uart_rx_check(bits: list[int], bit_cycles: int) -> tuple[int | None, bool]:
    """Decode a frame by sampling at the centre of each bit. Returns (byte, framing_ok).

    The first bit is the START; it must be low. Data bits are sampled at
    (start + (1.5 + i) * bit_cycles) for i = 0..7 (bit centres); STOP sampled at
    (start + 9.5 * bit_cycles) and must be high.
    """
    n = len(bits)
    if n < 10 * bit_cycles:
        return None, False
    start = 0
    if bits[start + bit_cycles // 2] != 0:
        return None, False
    val = 0
    for i in range(8):
        centre = start + bit_cycles // 2 + (i + 1) * bit_cycles
        if centre >= n:
            return None, False
        val |= (bits[centre] & 1) << i
    stop = start + bit_cycles // 2 + 9 * bit_cycles
    framing_ok = stop < n and bits[stop] == 1
    return val, framing_ok


def bit_cycles_for(clock_hz: int, baud: int) -> int:
    """Integer divider target; the remainder is absorbed as per-bit jitter."""
    return max(1, round(clock_hz / baud))


def _selftest() -> int:
    bad = 0
    for clock_hz, baud in [(50_000_000, 115_200), (50_000_000, 1_000_000), (12_000_000, 9600)]:
        bc = bit_cycles_for(clock_hz, baud)
        jitter = abs(clock_hz / baud - bc) / (clock_hz / baud)
        print(f"clock={clock_hz} baud={baud} -> bit_cycles={bc} jitter={jitter*100:.2f}%")
        for byte in range(256):
            bits = uart_tx_bits(byte, bc)
            got, ok = uart_rx_check(bits, bc)
            if got != byte or not ok:
                print(f"  FAIL byte={byte:#04x} got={got} ok={ok}")
                bad += 1
    print("self-test:", "PASS" if bad == 0 else f"{bad} FAIL")
    return 1 if bad else 0


if __name__ == "__main__":
    raise SystemExit(_selftest())
