# SPDX-FileCopyrightText: © 2024 Vision
# SPDX-License-Identifier: Apache-2.0
#
# Milestone 1 self-checking test: UART TX emits ui_in as 8N1, LSB-first, idle high.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

DIV = 10  # CLK_HZ/BAUD from the tb parameter override


async def uart_send(dut, byte):
    """Pulse tx_start with ui_in=byte, then capture the 10 UART bit cells."""
    dut.ui_in.value = byte
    dut.uio_in.value = 0x01
    await ClockCycles(dut.clk, 1)
    dut.uio_in.value = 0x00

    # One bit period later the start bit is driven; sample mid-bit for all 10 cells.
    await ClockCycles(dut.clk, DIV)
    bits = []
    for _ in range(10):
        await ClockCycles(dut.clk, DIV // 2)
        bits.append(int(dut.uo_out.value) & 1)
        await ClockCycles(dut.clk, DIV - DIV // 2)
    return bits


@cocotb.test()
async def test_uart_tx(dut):
    dut._log.info("Start UART TX test")
    clock = Clock(dut.clk, 1, unit="us")  # 1 MHz, matches tb DIV=10
    cocotb.start_soon(clock.start())

    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 5)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 1)

    # Idle line must be high.
    assert (int(dut.uo_out.value) & 1) == 1, "TX idle must be high"

    for byte in (0x41, 0x00, 0xFF, 0xA5):
        bits = await uart_send(dut, byte)
        dut._log.info(f"byte=0x{byte:02X} bits={bits}")
        assert bits[0] == 0, "start bit must be 0"
        assert bits[9] == 1, "stop bit must be 1"
        data = 0
        for i in range(8):
            data |= bits[1 + i] << i  # LSB first
        assert data == byte, f"decoded 0x{data:02X} != sent 0x{byte:02X}"

    # Busy must return low when done.
    await ClockCycles(dut.clk, 2 * DIV)
    assert (int(dut.uo_out.value) >> 1) & 1 == 0, "busy must clear after the stop bit"
    dut._log.info("UART TX test passed")
