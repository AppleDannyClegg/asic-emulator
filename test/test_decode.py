# SPDX-License-Identifier: Apache-2.0
# Decode conformance for pio_engine (Gort): every program is assembled by firmware/asm.py, so the
# words are SPEC §3 v0.4 encodings, and each test checks the architectural effect in the RTL.
# A failing test here means the RTL decodes a frozen code differently from SPEC - not a TB bug.
#
# Run (from test/):
#   PATH=$PWD/../.venv-cocotb/bin:$PATH make SIM_BUILD=sim_build/decode TOPLEVEL=tb_decode \
#     COCOTB_TEST_MODULES=test_decode VERILOG_SOURCES="$PWD/../src/pio_engine.v $PWD/tb_decode.v"

import os
import sys

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "firmware"))
import asm  # noqa: E402

HALT = "\nhalt:\n    jmp always, halt\n"


def engine_test(fn):
    """cocotb.test that first starts the clock (cocotb cancels it at the end of every test)."""
    async def wrapper(dut):
        cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
        await fn(dut)
    wrapper.__name__ = fn.__name__
    wrapper.__qualname__ = fn.__qualname__
    return cocotb.test()(wrapper)


async def run(dut, src, cycles=12, txf=(), pin_in=0, **cfg):
    """Reset, load `src` (assembled by asm.py), apply window cfg, push `txf`, run `cycles`."""
    words = asm.assemble(src + HALT)
    dut.enable.value = 0
    dut.rst_n.value = 0
    dut.pin_in.value = pin_in
    for name, val in cfg.items():
        getattr(dut, name).value = val
    await ClockCycles(dut.clk, 2)
    for a, w in enumerate(words):
        dut.imem_addr.value = a
        dut.imem_wdata.value = w
        dut.imem_we.value = 1
        await RisingEdge(dut.clk)
    dut.imem_we.value = 0
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    for v in txf:
        dut.txf_wdata.value = v
        dut.txf_we.value = 1
        await RisingEdge(dut.clk)
    dut.txf_we.value = 0
    await ClockCycles(dut.clk, 3)  # let the 2-FF pin synchroniser settle before the program runs
    dut.enable.value = 1
    await ClockCycles(dut.clk, cycles)
    dut.enable.value = 0
    await RisingEdge(dut.clk)


def reg(dut, name):
    return int(getattr(dut.dut, name).value)


# ---- SET (SPEC §3 row "SET dst": pins=0 x=1 y=2 pindirs=4) ----

@engine_test
async def set_pins_window(dut):
    await run(dut, "set pins, 5", set_base=0, set_count=4)
    assert int(dut.pin_out.value) & 0xF == 5, f"pin_out={int(dut.pin_out.value):#04x}"


@engine_test
async def set_pindirs_code4(dut):
    await run(dut, "set pindirs, 10", set_base=0, set_count=4)
    assert int(dut.pin_dir.value) & 0xF == 0b1010, f"pin_dir={int(dut.pin_dir.value):#04x}"


@engine_test
async def set_x_y(dut):
    await run(dut, "set x, 7\nset y, 3")
    assert (reg(dut, "x"), reg(dut, "y")) == (7, 3), (reg(dut, "x"), reg(dut, "y"))


# ---- MOV (SPEC §3 rows "MOV dst"/"MOV src"/"MOV op": src pins=0 x=1 y=2 null=3) ----

@engine_test
async def mov_x_y(dut):
    await run(dut, "set y, 9\nmov x, y")
    assert reg(dut, "x") == 9, reg(dut, "x")


@engine_test
async def mov_x_pins_src0(dut):
    await run(dut, "mov x, pins", pin_in=0x5A)
    assert reg(dut, "x") == 0x5A, f"x={reg(dut, 'x'):#04x}"


@engine_test
async def mov_x_null_src3(dut):
    await run(dut, "set x, 5\nmov x, null", pin_in=0xFF)
    assert reg(dut, "x") == 0, f"x={reg(dut, 'x'):#04x} (0xff = src 3 read as pins)"


@engine_test
async def mov_invert(dut):
    await run(dut, "set x, 15\nmov y, !x")
    assert reg(dut, "y") & 0xFF == 0xF0, f"y={reg(dut, 'y'):#04x}"


@engine_test
async def mov_reverse(dut):
    await run(dut, "set x, 1\nmov y, ::x")
    assert reg(dut, "y") == 0x80000000, f"y={reg(dut, 'y'):#010x} (SPEC §4: X/Y are 32-bit)"


# ---- PUSH/PULL (SPEC §3 row "PUSH/PULL": [7]=0 push/1 pull, [5]=block) ----

@engine_test
async def pull_block_takes_txf(dut):
    await run(dut, "pull block\nout pins, 1", txf=[0xA5], out_base=0, out_count=1)
    assert int(dut.pin_out.value) & 1 == 1, "OSR bit0 of 0xA5 not on pin 0"
    assert reg(dut, "txf_cnt") == 0, f"txf_cnt={reg(dut, 'txf_cnt')}"


@engine_test
async def push_block_fills_rxf(dut):
    await run(dut, "push block")
    assert int(dut.rxf_empty.value) == 0, "push block did not write the RX FIFO"
    assert reg(dut, "txf_cnt") == 0


@engine_test
async def pull_block_empty_stalls(dut):
    await run(dut, "pull block\nset x, 1", cycles=8)
    assert reg(dut, "x") == 0, "ran past a blocking pull on an empty TX FIFO"
    assert int(dut.pc_out.value) == 0, f"pc={int(dut.pc_out.value)}"


# ---- JMP (SPEC §3 row "JMP cond") - each: taken path sets y=2, fall-through sets y=1 ----

def _jmp(setup, cond):
    return f"""
    {setup}
    jmp {cond}, taken
    set y, 1
    jmp always, halt
taken:
    set y, 2
"""


async def _jmp_check(dut, setup, cond, want_taken):
    await run(dut, _jmp(setup, cond), cycles=10)
    got = reg(dut, "y")
    want = 2 if want_taken else 1
    assert got == want, f"jmp {cond} after '{setup}': y={got}, want {want}"


@engine_test
async def jmp_not_x(dut):
    await _jmp_check(dut, "set x, 0", "!x", True)
    await _jmp_check(dut, "set x, 3", "!x", False)


@engine_test
async def jmp_x_dec(dut):
    await _jmp_check(dut, "set x, 3", "x--", True)
    await _jmp_check(dut, "set x, 0", "x--", False)


@engine_test
async def jmp_not_y(dut):
    await _jmp_check(dut, "set y, 0", "!y", True)


@engine_test
async def jmp_x_ne_y(dut):
    await _jmp_check(dut, "set x, 1\nset y, 0", "x!=y", True)
    await _jmp_check(dut, "set x, 0\nset y, 0", "x!=y", False)


# NOT COVERED: jmp pin (no JMP_PIN select port on pio_engine yet; EXECCTRL is M2.1) and
# jmp !osre (SPEC does not define when OSR counts as empty - no shift counter in the RTL).


@engine_test
async def jmp_target_is_defined(dut):
    """A taken JMP must land on a defined PC (JMP addr is B[4:0]; IMEM_AW is 6)."""
    await run(dut, "jmp always, here\nset x, 1\nhere:\n    set y, 2", cycles=6)
    pc = dut.pc_out.value
    assert pc.is_resolvable, f"pc_out={pc} after a taken JMP (X/Z bits)"
