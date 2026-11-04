#!/usr/bin/env python3
"""RTL-free vector export (TARS) for the M2 engine TB (Wheatley 17:36:26).

For each program in firmware/programs/ emits:
  - `imem`: the (addr, word) list from asm.py, so a TB loads it verbatim;
  - for uart_tx, `uart` vectors: for each test byte, the expected TX pin level
    per engine cycle, derived from uart_ref (ONE shared reference end to end).

Output: firmware/vectors/<program>.json. Run: python3 firmware/export_vectors.py
"""
from __future__ import annotations

import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import asm  # noqa: E402
import uart_ref  # noqa: E402

HERE = pathlib.Path(__file__).parent
PROGRAMS = HERE / "programs"
OUT = HERE / "vectors"

# Engine cycles per bit for the UART program (delay field max 31 -> T <= 32).
UART_T = 8
UART_BYTES = [0x00, 0x41, 0xA5, 0xFF]


def export_imem(path: pathlib.Path, defines: dict[str, int] | None = None) -> dict:
    words = asm.assemble(path.read_text(), 0, defines)
    return {"program": path.name, "words": words,
            "imem": [{"addr": i, "word": w} for i, w in enumerate(words)]}


def uart_vectors(t: int) -> list[dict]:
    """Expected TX level per engine cycle for one frame per byte.

    The uart_tx program drives: idle high, START for T cycles, 8 data bits LSB-first
    (T cycles each), STOP for T cycles. `uart_ref.uart_tx_bits(byte, T)` returns exactly
    that per-cycle sequence, so the TB can compare cycle-by-cycle.
    """
    out = []
    for byte in UART_BYTES:
        bits = uart_ref.uart_tx_bits(byte, t)
        out.append({"byte": byte, "bit_cycles": t, "tx": bits})
    return out


def main() -> int:
    OUT.mkdir(exist_ok=True)
    for path in sorted(PROGRAMS.glob("*.pio")):
        defines = {"T": UART_T} if path.name == "uart_tx.pio" else None
        doc = export_imem(path, defines)
        if path.name == "uart_tx.pio":
            doc["uart"] = uart_vectors(UART_T)
        dest = OUT / (path.stem + ".json")
        dest.write_text(json.dumps(doc, indent=2) + "\n")
        print(f"{dest}: {len(doc['words'])} words"
              + (f", {len(doc['uart'])} uart vectors" if "uart" in doc else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
