/*
 * Copyright (c) 2024 Vision
 * SPDX-License-Identifier: Apache-2.0
 *
 * Milestone 1: hardcoded-divisor UART TX on a single pin.
 *   ui_in[7:0]  = byte to transmit
 *   uio_in[0]   = tx_start (pulse to begin a transmission)
 *   uo_out[0]   = TX line (idle high, 8N1)
 *   uo_out[1]   = busy
 *   uio_out/uio_oe = 0 (no bidirectional pins yet)
 *
 * This is the toolchain ramp only; the programmable engine replaces it in M2.
 */

`default_nettype none

module tt_um_protocol_emulator #(
    parameter integer CLK_HZ = 50_000_000,  // TT clock (config.json CLOCK_PERIOD=20ns)
    parameter integer BAUD   = 115_200
) (
    input  wire [7:0] ui_in,    // Dedicated inputs
    output wire [7:0] uo_out,   // Dedicated outputs
    input  wire [7:0] uio_in,   // IOs: Input path
    output wire [7:0] uio_out,  // IOs: Output path
    output wire [7:0] uio_oe,   // IOs: Enable path
    input  wire       ena,      // always 1 when powered
    input  wire       clk,      // clock
    input  wire       rst_n     // reset_n - low to reset
);

  // Clocks per bit (round to nearest).
  localparam integer DIV = (CLK_HZ + (BAUD / 2)) / BAUD;

  reg [15:0] div_cnt;
  reg [3:0]  bit_idx;   // 0 = start, 1..8 = data (LSB first), 9 = stop
  reg [9:0]  shifter;   // {stop, data[7:0], start}
  reg        busy;
  reg        tx;

  wire tx_start = uio_in[0];

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      div_cnt <= 16'd0;
      bit_idx <= 4'd0;
      shifter <= 10'h3FF;
      busy    <= 1'b0;
      tx      <= 1'b1;  // idle high
    end else if (!busy) begin
      tx <= 1'b1;
      if (tx_start) begin
        shifter <= {1'b1, ui_in, 1'b0};  // stop, data, start
        busy    <= 1'b1;
        bit_idx <= 4'd0;
        div_cnt <= 16'd0;
      end
    end else if (div_cnt == DIV - 1) begin
      div_cnt <= 16'd0;
      tx      <= shifter[0];
      shifter <= {1'b1, shifter[9:1]};
      if (bit_idx == 4'd9) begin
        busy <= 1'b0;
      end else begin
        bit_idx <= bit_idx + 4'd1;
      end
    end else begin
      div_cnt <= div_cnt + 16'd1;
    end
  end

  assign uo_out  = {6'b0, busy, tx};
  assign uio_out = 8'b0;
  assign uio_oe  = 8'b0;

  // List all unused inputs to prevent warnings
  wire _unused = &{ena, 1'b0};

endmodule
