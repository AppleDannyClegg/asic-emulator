#!/usr/bin/env python3
"""Tiny assembler for the protocol-emulator ISA v0.2 (TARS, firmware slice).

Targets asic-emulator/SPEC.md §3. Emits 16-bit words:
  [15:13] opcode | [12:8] delay(+side-set) | [7:0] operand (split per opcode)

Usage:
  python3 asm.py <program.pio> [--side-count N] [--hex]
  python3 asm.py --selftest

Syntax (one instruction per line, ';' starts a comment, 'label:' defines a label):
  pull block | pull noblock
  push block | push noblock
  set <dst>, <imm>            dst in {pins,x,y,pindirs}
  out <dst>, <n>              dst in {pins,x,y,null,pindirs,pc,isr,exec}
  in <src>, <n>               src in {pins,x,y,null,isr,osr}
  jmp <cond>, <label|addr>    cond in {always,!x,x--,!y,y--,x!=y,pin,!osre}
  mov <dst>, <src>            src may be prefixed '!' (invert); '::' = reverse (unsupported here)
  wait <src>, <pol>, <idx>    src in {gpio,pin,irq}
  irq <set|clear|wait>[, <rel|abs>], <idx>
  <instr> [<delay>]           optional trailing delay in [..]  (side_count=0: 0..31)

Every instruction may carry a delay in brackets, e.g. `out pins, 1 [6]`.
"""
from __future__ import annotations

import sys

OP = {"jmp": 0b000, "wait": 0b001, "in": 0b010, "out": 0b011,
      "push": 0b100, "pull": 0b100, "mov": 0b101, "irq": 0b110, "set": 0b111}

# Numeric operand codes: RP2040 PIO (the ISA is "PIO-proven"; SPEC.md/docs/ISA.md must
# pin these - they were unspecified, which is how asm.py and the RTL diverged, Gort 17:30:34).
JMP_COND = {"always": 0b000, "!x": 0b001, "x--": 0b010, "!y": 0b011,
            "y--": 0b100, "x!=y": 0b101, "pin": 0b110, "!osre": 0b111}
WAIT_SRC = {"gpio": 0b00, "pin": 0b01, "irq": 0b10}
# IN src: 0 pins, 1 x, 2 y, 3 null, 6 isr, 7 osr  (4/5 reserved, as RP2040)
IN_SRC = {"pins": 0b000, "x": 0b001, "y": 0b010, "null": 0b011, "isr": 0b110, "osr": 0b111}
# OUT dst: 0 pins, 1 x, 2 y, 3 null, 4 pindirs, 5 pc, 6 isr, 7 exec
OUT_DST = {"pins": 0b000, "x": 0b001, "y": 0b010, "null": 0b011,
           "pindirs": 0b100, "pc": 0b101, "isr": 0b110, "exec": 0b111}
# SET dst: 0 pins, 1 x, 2 y, 4 pindirs
SET_DST = {"pins": 0b000, "x": 0b001, "y": 0b010, "pindirs": 0b100}
# MOV dst: 0 pins, 1 x, 2 y, 3 null, 4 exec, 5 pc, 6 isr, 7 osr
MOV_DST = {"pins": 0b000, "x": 0b001, "y": 0b010, "null": 0b011,
           "exec": 0b100, "pc": 0b101, "isr": 0b110, "osr": 0b111}
# MOV src B[2:0]: 0 pins, 1 x, 2 y, 3 null, 4 reserved, 5 status, 6 isr, 7 osr
MOV_SRC = {"pins": 0b000, "x": 0b001, "y": 0b010, "null": 0b011,
           "status": 0b101, "isr": 0b110, "osr": 0b111}


class AsmError(Exception):
    pass


def _lookup(table: dict, key: str, what: str):
    """Dict lookup that raises AsmError (not KeyError) on an unknown name."""
    try:
        return table[key]
    except KeyError:
        raise AsmError(f"unknown {what} {key!r}") from None


def _strip_comment(line: str) -> str:
    return line.split(";", 1)[0].strip()


def _split_delay(text: str) -> tuple[str, int]:
    text = text.strip()
    if text.endswith("]"):
        i = text.rfind("[")
        if i == -1:
            raise AsmError(f"unmatched ']' in {text!r}")
        d = int(text[i + 1:-1].strip(), 0)
        return text[:i].strip(), d
    return text, 0


def encode(instr: str, labels: dict[str, int], addr: int, side_count: int) -> int:
    """Encode one mnemonic into a 16-bit word. `addr` = this instruction's address."""
    text, delay = _split_delay(instr)
    parts = text.replace(",", " ").split()
    if not parts:
        raise AsmError("empty instruction")
    op = parts[0].lower()
    if op not in OP:
        raise AsmError(f"unknown opcode {op!r}")
    code = OP[op]
    operand = 0
    if op in ("push", "pull"):
        block = 1 if (len(parts) > 1 and parts[1].lower() == "block") else 0
        # SPEC v0.4 (true RP2040): [7]=0 push / 1 pull, [6]=iffull/ifempty, [5]=block(1)/noblock(0)
        is_pull = 1 if op == "pull" else 0
        operand = (is_pull << 7) | (block << 5)
    elif op == "set":
        dst = _lookup(SET_DST, parts[1].lower(), "SET dst")
        imm = int(parts[2], 0)
        if not 0 <= imm <= 0x1F:
            raise AsmError(f"SET immediate {imm} out of range 0..31")
        operand = (dst << 5) | imm
    elif op == "out":
        dst = _lookup(OUT_DST, parts[1].lower(), "OUT dst")
        n = int(parts[2], 0)
        if not 0 <= n <= 32:
            raise AsmError(f"OUT bit count {n} out of range 0..32")
        operand = (dst << 5) | (n & 0x1F)
    elif op == "in":
        src = _lookup(IN_SRC, parts[1].lower(), "IN src")
        n = int(parts[2], 0)
        if not 0 <= n <= 32:
            raise AsmError(f"IN bit count {n} out of range 0..32")
        operand = (src << 5) | (n & 0x1F)
    elif op == "jmp":
        cond = _lookup(JMP_COND, parts[1].lower(), "JMP cond")
        tgt = parts[2]
        t = labels.get(tgt, None)
        if t is None:
            t = int(tgt, 0)
        # IMEM is 4 banks x 32 (SPEC v0.3.1): JMP addr [4:0] is within-bank, 0..31.
        if not 0 <= t <= 0x1F:
            raise AsmError(f"JMP target {t} out of range 0..31 (within-bank)")
        operand = (cond << 5) | (t & 0x1F)
    elif op == "mov":
        dst = _lookup(MOV_DST, parts[1].lower(), "MOV dst")
        src_tok = parts[2].lower()
        mop = 0  # 00 none, 01 invert !, 10 reverse ::
        if src_tok.startswith("::"):
            mop = 0b10
            src_tok = src_tok[2:]
        elif src_tok.startswith("!"):
            mop = 0b01
            src_tok = src_tok[1:]
        src = _lookup(MOV_SRC, src_tok, "MOV src")
        # SPEC v0.3: [7:5] dst | [4:3] op | [2:0] src
        operand = (dst << 5) | (mop << 3) | src
    elif op == "wait":
        src = _lookup(WAIT_SRC, parts[1].lower(), "WAIT src")
        pol = int(parts[2], 0)
        if not 0 <= pol <= 1:
            raise AsmError(f"WAIT polarity {pol} out of range 0..1")
        idx = int(parts[3], 0) & 0x1F
        # SPEC v0.4 (true RP2040): [7]=polarity, [6:5]=src, [4:0]=index
        operand = (pol << 7) | (src << 5) | idx
    elif op == "irq":
        mode = parts[1].lower()
        rest = parts[2:]
        rel = 1
        if rest and rest[0].lower() in ("rel", "abs"):
            rel = 1 if rest[0].lower() == "rel" else 0
            rest = rest[1:]
        idx = int(rest[0], 0) if rest else 0
        if not 0 <= idx <= 7:
            raise AsmError(f"IRQ index {idx} out of range 0..7")
        wait = 1 if mode == "wait" else 0
        clear = 1 if mode == "clear" else 0
        operand = (wait << 7) | (clear << 6) | (rel << 5) | idx
    if side_count:
        if delay > (1 << (5 - side_count)) - 1:
            raise AsmError(f"delay {delay} too large for side_count={side_count}")
        dfield = (0 << (5 - side_count)) | delay  # side value 0
    else:
        if delay > 31:
            raise AsmError(f"delay {delay} > 31")
        dfield = delay
    return (code << 13) | (dfield << 8) | (operand & 0xFF)


def assemble(source: str, side_count: int = 0, defines: dict[str, int] | None = None) -> list[int]:
    if defines:
        import re as _re

        def _sub(m):
            expr = m.group(1)
            try:
                return str(eval(expr, {"__builtins__": {}}, dict(defines)))
            except Exception as e:  # noqa: BLE001
                raise AsmError(f"bad {{...}} expression {expr!r}: {e}") from None

        source = _re.sub(r"\{([^}]+)\}", _sub, source)
    lines = []
    for raw in source.splitlines():
        line = _strip_comment(raw)
        if not line:
            continue
        lines.append(line)
    # pass 1: labels
    labels: dict[str, int] = {}
    pc = 0
    for line in lines:
        if line.endswith(":"):
            labels[line[:-1].strip()] = pc
            continue
        pc += 1
    # pass 2: encode
    out: list[int] = []
    pc = 0
    for line in lines:
        if line.endswith(":"):
            continue
        out.append(encode(line, labels, pc, side_count))
        pc += 1
    return out


def disassemble(word: int) -> str:
    """Round-trip check: decode the opcode + fields enough to re-encode."""
    code = (word >> 13) & 0b111
    dfield = (word >> 8) & 0x1F
    operand = word & 0xFF
    names = {0b000: "jmp", 0b001: "wait", 0b010: "in", 0b011: "out",
             0b100: "push/pull", 0b101: "mov", 0b110: "irq", 0b111: "set"}
    return f"{names[code]} d={dfield} op={operand:#04x}"


UART_TX = """
; UART TX 8N1, no side-set; TX pin driven by set/out pins. side_count=0, div set for bit period.
start:
    pull block
    set pindirs, 1
    set x, 7
    set pins, 0
data:
    out pins, 1
    jmp x-- data
    set pins, 1
    jmp always, start
"""


def _selftest() -> int:
    words = assemble(UART_TX, side_count=0)
    print(f"UART_TX assembled: {len(words)} instructions")
    for w in words:
        print(f"  {w:016b}  {w:#06x}  {disassemble(w)}")
    # round-trip: re-encode each disassembled opcode? (disassembler is lossy; check stability)
    assert all(0 <= w <= 0xFFFF for w in words)
    # spot-check encodings
    assert (words[0] >> 13) == OP["pull"]
    assert (words[1] >> 13) == OP["set"]
    assert (words[5] >> 13) == OP["jmp"] and ((words[5] >> 5) & 0x7) == JMP_COND["x--"]
    # MOV 2-bit op round-trip (v0.3)
    for mnem, want in [("mov osr, !osr", 0b01), ("mov osr, ::osr", 0b10), ("mov x, y", 0b00)]:
        w = assemble(mnem, 0)[0]
        got = (w >> 3) & 0b11
        assert got == want, f"{mnem}: op={got} want={want}"
    print("self-test: PASS")
    return 0


def main(argv: list[str]) -> int:
    if "--selftest" in argv or len(argv) == 1:
        return _selftest()
    path = argv[1]
    side_count = 0
    if "--side-count" in argv:
        side_count = int(argv[argv.index("--side-count") + 1])
    defines: dict[str, int] = {}
    if "--define" in argv:
        for spec in argv[argv.index("--define") + 1:]:
            if "=" not in spec:
                break
            k, v = spec.split("=", 1)
            defines[k] = int(v, 0)
    words = assemble(open(path).read(), side_count, defines)
    as_hex = "--hex" in argv
    for w in words:
        print(f"{w:04x}" if as_hex else f"{w:016b}  {w:#06x}  {disassemble(w)}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except AsmError as e:
        print(f"asm error: {e}", file=sys.stderr)
        raise SystemExit(2)
