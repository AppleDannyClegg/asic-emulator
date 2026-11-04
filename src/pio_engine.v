/*
 * Copyright (c) 2024 Vision
 * SPDX-License-Identifier: Apache-2.0
 *
 * pio_engine - one RP2040-PIO-style state machine (ISA freeze v0.1, Legion 17:20:37).
 *
 * 16-bit instruction: [15:13] op | [12:8] delay/sideset(5) | [7:5] operand-A(3) | [4:0] operand-B(5)
 * One instruction per (clkdiv) engine cycle. This first cut implements the ops needed
 * for the UART TX program: PULL, SET (pins/x/y/pindirs), OUT pins/x, JMP (always / !X / X-- / !Y / Y--),
 * MOV, IN, PUSH. WAIT/IRQ/side-set/autopull are stubbed for M2.1.
 *
 * Pin model: a single 8-bit GPIO port; per-pin direction mask (pindirs), output value (pins).
 */

`default_nettype none

module pio_engine #(
    parameter integer IMEM_AW = 6  // 64 x 16-bit
) (
    input  wire        clk,
    input  wire        rst_n,

    // Instruction memory write port (from the sequencer/config port)
    input  wire        imem_we,
    input  wire [IMEM_AW-1:0] imem_addr,
    input  wire [15:0] imem_wdata,

    // Control
    input  wire        enable,
    input  wire [15:0] clkdiv,        // engine cycle = (clkdiv) system clocks (1 = every clock)

    // TX FIFO write port (host -> engine), RX FIFO read port (engine -> host)
    input  wire        txf_we,
    input  wire [31:0] txf_wdata,
    output wire        txf_full,
    input  wire        rxf_re,
    output wire [31:0] rxf_rdata,
    output wire        rxf_empty,

    // GPIO
    input  wire [7:0]  pin_in,        // sampled input pins
    output wire [7:0]  pin_out,       // driven output values
    output wire [7:0]  pin_dir,       // 1 = output
    input  wire [2:0]  in_base,
    input  wire [2:0]  out_base,
    input  wire [2:0]  set_base,
    input  wire [4:0]  out_count,     // number of OUT pins (<=8)

    output wire [3:0]  irq_flags,     // sticky IRQ flags (bit0 = tx stall, etc.)

    output wire [IMEM_AW-1:0] pc_out,
    output wire        stalled
);

  // ---- instruction memory -------------------------------------------------
  reg [15:0] imem [0:(1<<IMEM_AW)-1];
  always @(posedge clk) if (imem_we) imem[imem_addr] <= imem_wdata;

  // ---- program counter ----------------------------------------------------
  reg [IMEM_AW-1:0] pc;
  wire [15:0] instr = imem[pc];
  wire [2:0]  op    = instr[15:13];
  wire [4:0]  delay = instr[12:8];
  wire [2:0]  opA   = instr[7:5];
  wire [4:0]  opB   = instr[4:0];

  localparam OP_JMP = 3'd0, OP_WAIT = 3'd1, OP_IN = 3'd2, OP_OUT = 3'd3,
             OP_PUSH = 3'd4, OP_MOV = 3'd5, OP_IRQ = 3'd6, OP_SET = 3'd7;

  // ---- state --------------------------------------------------------------
  reg [31:0] osr, isr;
  reg [4:0]  osr_cnt, isr_cnt;
  reg [7:0]  x, y;
  reg [7:0]  pins, pindirs;
  reg [3:0]  irq;

  // ---- engine clock divider ----------------------------------------------
  reg [15:0] div_cnt;
  wire tick = enable && (clkdiv <= 16'd1 || div_cnt == clkdiv - 16'd1);
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) div_cnt <= 16'd0;
    else if (!enable) div_cnt <= 16'd0;
    else if (tick) div_cnt <= 16'd0;
    else div_cnt <= div_cnt + 16'd1;
  end

  // ---- FIFOs (4-deep, 32-bit) --------------------------------------------
  reg [31:0] txf [0:3]; reg [2:0] txf_cnt;
  reg [31:0] rxf [0:3]; reg [2:0] rxf_cnt;
  assign txf_full  = (txf_cnt == 3'd4);
  assign rxf_empty = (rxf_cnt == 3'd0);
  assign rxf_rdata = rxf[0];

  wire pull_req = (op == OP_PUSH) && opA[7-5+2] == 1'b1;  // [7] set => PULL (PIO convention)

  // ---- helper: shift in/out ----------------------------------------------
  wire [4:0] n = (opB == 5'd0) ? 5'd32 : opB;  // 0 means 32

  function [31:0] ror32(input [31:0] v, input integer k);  // right shift by k (1..32)
    begin
      ror32 = (k >= 32) ? v : (v >> k);
    end
  endfunction

  // ---- sequential execute -------------------------------------------------
  integer i;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc <= 0; osr <= 0; isr <= 0; osr_cnt <= 0; isr_cnt <= 0;
      x <= 0; y <= 0; pins <= 0; pindirs <= 0; irq <= 0;
      txf_cnt <= 0; rxf_cnt <= 0;
    end else if (enable && tick) begin
      // defaults
      pc <= pc + 1'b1;
      case (op)
        OP_SET: begin
          case (opA)
            3'd0: begin // SET pins, imm
              for (i = 0; i < 8; i = i + 1)
                if (i >= set_base && (i - set_base) < opB)
                  pins[i] <= 1'b0; // placeholder; handled below by masked set
            end
            3'd1: x <= opB;
            3'd2: y <= opB;
            3'd3: pindirs <= opB;
            default: ;
          endcase
          if (opA == 3'd0) begin
            for (i = 0; i < 8; i = i + 1)
              if (i >= set_base && (i - set_base) < opB)
                pins[i] <= 1'b1;
          end
        end
        OP_MOV: begin
          // opA = dest, opB[2:0] = src; opB[3] = invert, opB[4] = reverse
          case (opA)
            3'd1: x <= opB[3] ? ~y : y;   // MOV x, y (src 2)
            3'd2: y <= opB[3] ? ~x : x;   // MOV y, x (src 1)
            default: ;
          endcase
        end
        OP_OUT: begin
          // OUT pins,n  (opA=0); shift osr right, drive out_base..out_base+out_count
          case (opA)
            3'd0: begin
              for (i = 0; i < 8; i = i + 1)
                if (i >= out_base && (i - out_base) < out_count)
                  pins[i] <= osr[i - out_base];
              osr <= ror32(osr, (out_count == 0) ? 32 : out_count);
              osr_cnt <= osr_cnt + out_count;
            end
            default: ;
          endcase
        end
        OP_IN: begin
          // IN pins,n -> shift pin_in[in_base +: n] into ISR (right)
          isr <= (isr >> n) | ({{(32-8){1'b0}}, pin_in} << (32 - n));
          isr_cnt <= isr_cnt + n;
        end
        OP_PUSH: begin
          if (opA[7-5+2]) begin // PULL
            if (txf_cnt != 0) begin
              osr <= txf[0];
              for (i = 0; i < 3; i = i + 1) txf[i] <= txf[i+1];
              txf_cnt <= txf_cnt - 1'b1;
              osr_cnt <= 0;
            end else begin
              irq[0] <= 1'b1;  // stall flag (blocking pull with empty FIFO)
              pc <= pc;        // stall on this instruction
            end
          end else begin        // PUSH isr -> RX FIFO
            if (rxf_cnt != 4) begin
              rxf[rxf_cnt] <= isr;
              rxf_cnt <= rxf_cnt + 1'b1;
              isr_cnt <= 0;
            end else begin
              irq[0] <= 1'b1;  // overrun
            end
          end
        end
        OP_JMP: begin
          case (opA)
            3'd0: pc <= opB[IMEM_AW-1:0];                 // always
            3'd1: if (x == 0) pc <= opB[IMEM_AW-1:0];     // !X
            3'd2: begin if (x != 0) pc <= opB[IMEM_AW-1:0]; x <= x - 1'b1; end // X--
            3'd3: if (y == 0) pc <= opB[IMEM_AW-1:0];     // !Y
            3'd4: begin if (y != 0) pc <= opB[IMEM_AW-1:0]; y <= y - 1'b1; end // Y--
            default: ;
          endcase
        end
        default: ; // WAIT / IRQ: M2.1
      endcase
    end
  end

  // TX FIFO host write
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) ; // txf_cnt handled above
    else if (txf_we && txf_cnt != 4) begin
      txf[txf_cnt] <= txf_wdata;
      txf_cnt <= txf_cnt + 1'b1;
    end
  end

  assign pin_out  = pins;
  assign pin_dir  = pindirs;
  assign irq_flags = irq;
  assign pc_out   = pc;
  assign stalled  = enable && (op == OP_PUSH) && opA[7-5+2] && (txf_cnt == 0);

endmodule
