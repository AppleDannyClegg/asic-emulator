# SPDX-FileCopyrightText: © 2024 Vision
# SPDX-License-Identifier: Apache-2.0
# Unit test for pio_engine: load an unrolled UART TX program, push a byte, decode the TX pin.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, ClockCycles

# op | [12:8] delay/side | [7:5] A | [4:0] B
PROG = [
    0x80A0,  # 0  pull block            (op=4, [7]=pull, [5]=block per v0.4)
    0xE081,  # 1  set pindirs, 1        (op=7, A=100 pindirs per SPEC v0.4, B=1)
    0xE001,  # 2  set pins, 1  (idle)
    0xE000,  # 3  set pins, 0  (start)
    0x6001,  # 4  out pins, 1  (bit0)
    0x6001,  # 5  out pins, 1
    0x6001,  # 6  out pins, 1
    0x6001,  # 7  out pins, 1
    0x6001,  # 8  out pins, 1
    0x6001,  # 9  out pins, 1
    0x6001,  # 10 out pins, 1
    0x6001,  # 11 out pins, 1  (bit7)
    0xE001,  # 12 set pins, 1  (stop)
    0x000D,  # 13 jmp 13 (halt)
]


async def load(dut):
    for a, w in enumerate(PROG):
        dut.imem_addr.value = a
        dut.imem_wdata.value = w
        dut.imem_we.value = 1
        await RisingEdge(dut.clk)
    dut.imem_we.value = 0


@cocotb.test()
async def test_engine_uart_tx(dut):
    cocotb.start_soon(Clock(dut.clk, 10, unit="ns").start())
    dut.enable.value = 0
    dut.clkdiv.value = 1
    dut.txf_we.value = 0
    dut.pin_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 3)
    await load(dut)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 1)

    for byte in (0x41, 0x00, 0xFF, 0xA5):
        # reset the engine state between bytes
        dut.enable.value = 0
        dut.rst_n.value = 0
        await ClockCycles(dut.clk, 2)
        await load(dut)
        dut.rst_n.value = 1
        # push the byte into the TX FIFO
        dut.txf_wdata.value = byte
        dut.txf_we.value = 1
        await RisingEdge(dut.clk)
        dut.txf_we.value = 0
        dut.enable.value = 1

        # capture the TX pin for a full frame (idle + start + 8 data + stop)
        samples = []
        for _ in range(20):
            await RisingEdge(dut.clk)
            samples.append(int(dut.pin_out.value) & 1)

        # find the start bit: first 0 that follows a 1
        start = None
        for i in range(1, len(samples)):
            if samples[i - 1] == 1 and samples[i] == 0:
                start = i
                break
        assert start is not None, f"no start bit; samples={samples}"
        assert samples[start] == 0, "start bit must be 0"
        data = 0
        for i in range(8):
            data |= samples[start + 1 + i] << i
        stop = samples[start + 9]
        dut._log.info(f"byte=0x{byte:02X} samples={samples} start={start} data=0x{data:02X} stop={stop}")
        assert stop == 1, "stop bit must be 1"
        assert data == byte, f"decoded 0x{data:02X} != sent 0x{byte:02X}"
        # SET pindirs must actually drive the TX pin (else the 'set pindirs' word is a no-op
        # and the test would pass for the wrong reason - Gort 18:01:37 mutation).
        assert (int(dut.pin_dir.value) & 1) == 1, "TX pin must be driven (pindirs set)"

    dut._log.info("pio_engine UART TX unit test passed")
