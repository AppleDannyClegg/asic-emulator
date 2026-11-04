#!/usr/bin/env python3
"""Encoding conformance for firmware/asm.py against the numeric operand tables (Gort).

Expected words are written out by hand from the table TARS posted at 17:31:15 on 4 Nov 2026
(frozen as SPEC.md §3 v0.4), not computed from asm.py's own dictionaries, so a wrong entry in asm.py fails here.

The table is SPEC.md §3 "Numeric selector codes (NORMATIVE)", v0.4 (Legion 17:33:11), which
follows the RP2040 datasheet for WAIT, PUSH/PULL and MOV src. Where SPEC and RP2040 differ, SPEC wins.

Citations name the SPEC §3 row (rows, not line numbers, so they survive edits).

Run: python3 firmware/test_encoding.py   (exit 0 = all golden + error cases pass)
"""
from __future__ import annotations

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asm  # noqa: E402

# (mnemonic, expected word). Layout: [15:13] op | [12:8] delay | [7:5] A | [4:0] B.
GOLDEN = [
    # [SPEC §3 row "SET dst"] SET: op 111, dst pins=000 x=001 y=010 pindirs=100
    ("set pins, 0",        0b111_00000_000_00000),
    ("set pins, 1",        0b111_00000_000_00001),
    ("set x, 7",           0b111_00000_001_00111),
    ("set y, 31",          0b111_00000_010_11111),
    ("set pindirs, 1",     0b111_00000_100_00001),
    # [SPEC §3 "Delay field decode"] delay lands in [12:8]
    ("set pins, 0 [6]",    0b111_00110_000_00000),
    ("set pins, 0 [31]",   0b111_11111_000_00000),
    # [SPEC §3 row "OUT dst"] OUT: op 011, dst pins=000 x=001 y=010 null=011 pindirs=100 pc=101 isr=110 exec=111
    ("out pins, 1",        0b011_00000_000_00001),
    ("out x, 8",           0b011_00000_001_01000),
    ("out null, 1",        0b011_00000_011_00001),
    ("out pindirs, 2",     0b011_00000_100_00010),
    ("out pc, 5",          0b011_00000_101_00101),
    ("out isr, 4",         0b011_00000_110_00100),
    ("out exec, 16",       0b011_00000_111_10000),
    ("out pins, 32",       0b011_00000_000_00000),   # 32 encodes as 0
    # [SPEC §3 row "IN src"] IN: op 010, src pins=000 x=001 y=010 null=011 isr=110 osr=111
    ("in pins, 1",         0b010_00000_000_00001),
    ("in null, 24",        0b010_00000_011_11000),
    ("in isr, 8",          0b010_00000_110_01000),
    ("in osr, 8",          0b010_00000_111_01000),
    # [SPEC §3 rows "JMP cond", "JMP addr"] JMP: op 000, cond always=000 !x=001 x--=010 !y=011 y--=100 x!=y=101 pin=110 !osre=111
    ("jmp always, 0",      0b000_00000_000_00000),
    ("jmp !x, 3",          0b000_00000_001_00011),
    ("jmp x--, 4",         0b000_00000_010_00100),
    ("jmp !y, 5",          0b000_00000_011_00101),
    ("jmp y--, 6",         0b000_00000_100_00110),
    ("jmp x!=y, 7",        0b000_00000_101_00111),
    ("jmp pin, 8",         0b000_00000_110_01000),
    ("jmp !osre, 31",      0b000_00000_111_11111),
    # [SPEC §3 rows "MOV dst", "MOV op"] MOV dst: pins=000 x=001 y=010 null=011 exec=100 pc=101 isr=110 osr=111; op [4:3]
    ("mov x, y",           0b101_00000_001_00_010),
    ("mov y, !x",          0b101_00000_010_01_001),
    ("mov osr, ::osr",     0b101_00000_111_10_111),
    # [SPEC §3 row "MOV src"] MOV src: pins=0 x=1 y=2 null=3 (4 reserved) status=5 isr=6 osr=7 (SPEC §3 v0.4 = RP2040)
    ("mov x, status",      0b101_00000_001_00_101),
    ("mov x, isr",         0b101_00000_001_00_110),
    ("mov pins, !osr",     0b101_00000_000_01_111),
    # [SPEC §3 row "PUSH/PULL" in the numeric table] PUSH/PULL: [7]=0 push/1 pull, [6]=iffull/ifempty, [5]=block
    ("pull block",         0b100_00000_101_00000),
    ("pull noblock",       0b100_00000_100_00000),
    ("push block",         0b100_00000_001_00000),
    ("push noblock",       0b100_00000_000_00000),
    # [SPEC §3 row "WAIT" in the numeric table] WAIT: [7]=polarity, [6:5]=src gpio=0 pin=1 irq=2, [4:0]=idx
    ("wait gpio, 1, 3",    0b001_00000_100_00011),
    ("wait pin, 0, 2",     0b001_00000_001_00010),
    ("wait irq, 1, 7",     0b001_00000_110_00111),
    # [SPEC §3 row "IRQ"] IRQ: A[2]=wait A[1]=clear(1)/set(0) A[0]=rel(1)/abs(0), B=idx 0..7
    ("irq set, abs, 3",    0b110_00000_000_00011),
    ("irq clear, abs, 3",  0b110_00000_010_00011),
    ("irq wait, rel, 7",   0b110_00000_101_00111),
]

# Must raise asm.AsmError (not a Python exception, not a silently masked word).
MUST_REJECT = [
    "jmp always, 32",      # JMP addr is [4:0]
    "set x, 32",           # SET imm is 5 bits
    "set pins, -1",
    "out pins, 33",
    "in pins, 33",
    "set pins, 0 [32]",    # delay is 5 bits
    "set foo, 1",          # unknown dst
    "out foo, 1",
    "in foo, 1",
    "jmp sometimes, 0",    # unknown cond
    "mov foo, x",
    "mov x, exec",          # MOV src 4 is reserved and there is no exec source (v0.4)
    "frob x, 1",           # unknown opcode
    "set 3, 1",            # SET dst 3 is reserved; only names are accepted
    "irq set, abs, 8",     # IRQ index is 0..7 (SPEC §3)
    "wait irq, 2, 1",      # polarity is one bit
]


def _asm1(mnemonic: str) -> int:
    words = asm.assemble(mnemonic)
    assert len(words) == 1, words
    return words[0]


def main() -> int:
    fails = 0
    for mnem, want in GOLDEN:
        try:
            got = _asm1(mnem)
        except Exception as e:  # noqa: BLE001 - report every way it can break
            print(f"FAIL  {mnem:22s} raised {type(e).__name__}: {e}")
            fails += 1
            continue
        if got != want:
            print(f"FAIL  {mnem:22s} got {got:#06x} want {want:#06x}")
            fails += 1
    golden_ok = len(GOLDEN) - fails

    rej_fail = 0
    for mnem in MUST_REJECT:
        try:
            got = _asm1(mnem)
            print(f"FAIL  {mnem:22s} accepted as {got:#06x}, want AsmError")
            rej_fail += 1
        except asm.AsmError:
            pass
        except Exception as e:  # noqa: BLE001
            print(f"FAIL  {mnem:22s} raised {type(e).__name__}: {e}, want AsmError")
            rej_fail += 1

    print(f"golden {golden_ok}/{len(GOLDEN)}, reject {len(MUST_REJECT) - rej_fail}/{len(MUST_REJECT)}")
    return 1 if (fails or rej_fail) else 0


if __name__ == "__main__":
    raise SystemExit(main())
