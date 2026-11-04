/*
 * Copyright (c) 2024 Vision
 * SPDX-License-Identifier: Apache-2.0
 *
 * pio_engine - one RP2040-PIO-style state machine (ISA freeze v0.1, Legion 17:20:37).
 *
 * 16-bit instruction: [15:13] op | [12:8] delay/side-set(5) | [7:5] operand-A(3) | [4:0] operand-B(5)
 * One instruction per (clkdiv) engine cycle.
 *
 * This first cut (M2.0) implements the ops the UART TX program needs:
 *   PULL, SET (pins / pindirs / x / y), OUT pins, JMP (always / !X / X-- / !Y / Y--), MOV, IN, PUSH.
 * WAIT / IRQ / side-set / autopull are M2.1.
 *
 * Pin model: one 8-bit GPIO port; `pindirs` is the per-pin direction mask, `pins` the driven value.
 * SET/OUT/IN use base+count windows from PINCTRL.
 */

`default_nettype none

module pio_engine #(
    parameter integer IMEM_AW = 5,  // SPEC v0.4: 32-instruction bank per engine; JMP addr [4:0]
    parameter integer XY_W    = 32  // X/Y width; SPEC allows 16 under area pressure
) (
    input  wire        clk,
    input  wire        rst_n,

    // Instruction memory write port
    input  wire        imem_we,
    input  wire [IMEM_AW-1:0] imem_addr,
    input  wire [15:0] imem_wdata,

    // Control / timing
    input  wire        enable,
    input  wire [15:0] clkdiv,       // engine cycle = clkdiv system clocks (1 = every clock)

    // TX FIFO (host -> engine), RX FIFO (engine -> host), 4-deep x 32-bit
    input  wire        txf_we,
    input  wire [31:0] txf_wdata,
    output wire        txf_full,
    input  wire        rxf_re,
    output wire [31:0] rxf_rdata,
    output wire        rxf_empty,

    // GPIO
    input  wire [7:0]  pin_in,
    output wire [7:0]  pin_out,
    output wire [7:0]  pin_dir,
    input  wire [2:0]  in_base,
    input  wire [2:0]  out_base,
    input  wire [2:0]  set_base,
    input  wire [3:0]  set_count,
    input  wire [3:0]  out_count,
    input  wire [3:0]  in_count,

    // SHIFTCTRL: 0 = shift right (LSB-first, UART), 1 = shift left (MSB-first, SPI/I2C)
    input  wire        shift_left,

    // PINCTRL side-set window (SPEC v0.4): [12:8] high `side_set_count` bits = side-set
    input  wire [2:0]  side_set_count,
    input  wire [2:0]  sideset_base,
    input  wire [7:0]  open_drain,   // PINCTRL: driven-1 auto-releases this pin (I2C)
    input  wire        jmp_pin,      // EXECCTRL JMP_PIN: value for the JMP PIN condition

    output wire [3:0]  irq_flags,
    output wire [IMEM_AW-1:0] pc_out,
    output wire        stalled
);

  reg [15:0] imem [0:(1<<IMEM_AW)-1];
  always @(posedge clk) if (imem_we) imem[imem_addr] <= imem_wdata;

  reg [IMEM_AW-1:0] pc;
  wire [15:0] instr = imem[pc];
  wire [2:0]  op    = instr[15:13];
  wire [2:0]  opA   = instr[7:5];
  wire [4:0]  opB   = instr[4:0];

  localparam OP_JMP = 3'd0, OP_WAIT = 3'd1, OP_IN = 3'd2, OP_OUT = 3'd3,
             OP_PUSH = 3'd4, OP_MOV = 3'd5, OP_IRQ = 3'd6, OP_SET = 3'd7;

  reg [31:0] osr, isr;
  reg [XY_W-1:0] x, y;   // SPEC v0.4: 32-bit default; 16 allowed under area pressure
  wire [31:0] x32 = {{(32-XY_W){1'b0}}, x};
  wire [31:0] y32 = {{(32-XY_W){1'b0}}, y};
  reg [7:0]  pins, pindirs;
  reg [3:0]  irq;

  // engine clock divider
  reg [15:0] div_cnt;
  wire tick = enable && (clkdiv <= 16'd1 || div_cnt == clkdiv - 16'd1);
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n)              div_cnt <= 16'd0;
    else if (!enable)        div_cnt <= 16'd0;
    else if (tick)           div_cnt <= 16'd0;
    else                     div_cnt <= div_cnt + 16'd1;
  end

  // FIFOs
  reg [31:0] txf [0:3]; reg [2:0] txf_cnt;
  reg [31:0] rxf [0:3]; reg [2:0] rxf_cnt;
  assign txf_full  = (txf_cnt == 3'd4);
  assign rxf_empty = (rxf_cnt == 3'd0);
  assign rxf_rdata = rxf[0];

  // 2-FF synchroniser for the async GPIO inputs (metastability). `pin_s` is the usable
  // value everywhere the engine reads pins (IN / WAIT / MOV PIN source). A glitch filter
  // is a later addition; the synchroniser is the correctness minimum.
  reg [7:0] pin_s0, pin_s1;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin pin_s0 <= 8'd0; pin_s1 <= 8'd0; end
    else begin pin_s0 <= pin_in; pin_s1 <= pin_s0; end
  end
  wire [7:0] pin_s = pin_s1;

  // MOV value helper: op 0 = copy, 1 = bitwise NOT, 2 = 8-bit bit-reverse ("::")
  function [7:0] move_val(input [7:0] s, input [1:0] mop);
    case (mop)
      2'd1: move_val = ~s;
      2'd2: move_val = {s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7]};
      default: move_val = s;
    endcase
  endfunction

  // PUSH/PULL: PIO uses opA[7]=0 push / 1 pull (opA is 3 bits here, so use opB[7]? keep PIO's
  // encoding: the PUSH/PULL instruction's bit 7 distinguishes pull; we carry it in opA[2]).
  wire is_pull = opA[2];
  wire is_block = opA[0];  // SPEC v0.4 PUSH/PULL [5]=block

  // shift helpers
  wire [5:0] out_n = (out_count == 0) ? 6'd1 : {2'b0, out_count};
  wire [5:0] in_n  = (in_count  == 0) ? 6'd1 : {2'b0, in_count};

  // MOV source + op (SPEC v0.4): src 0 pins,1 x,2 y,3 null,4 rsvd,5 status,6 isr,7 osr
  wire [31:0] mov_src = (opB[2:0] == 3'd0) ? {24'b0, pin_s} :
                        (opB[2:0] == 3'd1) ? x32 :
                        (opB[2:0] == 3'd2) ? y32 :
                        (opB[2:0] == 3'd5) ? 32'd0 :
                        (opB[2:0] == 3'd6) ? isr :
                        (opB[2:0] == 3'd7) ? osr : 32'd0;
  wire [31:0] move_val32 = (opB[4:3] == 2'd1) ? ~mov_src :
                           (opB[4:3] == 2'd2) ? {mov_src[0],mov_src[1],mov_src[2],mov_src[3],mov_src[4],mov_src[5],mov_src[6],mov_src[7],
                                                 mov_src[8],mov_src[9],mov_src[10],mov_src[11],mov_src[12],mov_src[13],mov_src[14],mov_src[15],
                                                 mov_src[16],mov_src[17],mov_src[18],mov_src[19],mov_src[20],mov_src[21],mov_src[22],mov_src[23],
                                                 mov_src[24],mov_src[25],mov_src[26],mov_src[27],mov_src[28],mov_src[29],mov_src[30],mov_src[31]} : mov_src;

  // IN source (SPEC v0.4): 0 pins (in_base window), 6 isr, 7 osr
  wire [31:0] in_data = (opA == 3'd6) ? isr : (opA == 3'd7) ? osr : {24'b0, (pin_s >> in_base)};

  // WAIT (SPEC v0.4): A[2]=pol, A[1:0]=src (0 gpio,1 pin,2 irq), B[2:0]=index
  wire wait_pol = opA[2];
  wire [7:0] wait_val = (opA[1:0] == 2'd0) ? pin_s :
                        (opA[1:0] == 2'd1) ? (pin_s >> in_base) :
                        {4'b0, irq};
  wire wait_ok = (wait_val[opB[2:0]] == wait_pol);

  // JMP target: 5-bit within-bank address (opB[4:0]); zero-extended to the PC width.
  wire [4:0] jaddr = opB[4:0];

  // delay + side-set field [12:8] (SPEC v0.4): top side_set_count bits = side-set value,
  // low (5 - side_set_count) bits = integer delay in engine cycles.
  wire [4:0] ss_shift = 5'd5 - {2'b0, side_set_count};
  wire [4:0] sideset_val = (side_set_count == 3'd0) ? 5'd0 : (instr[12:8] >> ss_shift);
  wire [4:0] delay_val  = (instr[12:8] & (5'd1 << ss_shift) - 5'd1);
  reg [4:0]  delay_cnt;

  integer i;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      pc <= 0; osr <= 0; isr <= 0; x <= 0; y <= 0; pins <= 0; pindirs <= 0; irq <= 0;
      txf_cnt <= 0; rxf_cnt <= 0; delay_cnt <= 5'd0;
    end else begin
      // host TXF push (every clock), SINGLE writer; skipped when the engine pulls this cycle
      if (txf_we && txf_cnt != 4 && !(enable && tick && op == OP_PUSH && is_pull && txf_cnt != 0)) begin
        txf[txf_cnt] <= txf_wdata;
        txf_cnt <= txf_cnt + 1'b1;
      end
      if (enable && tick) begin
      // delay [12:8] low bits: hold for `delay_val` extra engine cycles (SPEC v0.4)
      if (delay_cnt != 5'd0) begin
        delay_cnt <= delay_cnt - 5'd1;
      end else begin
      delay_cnt <= delay_val;
      pc <= pc + 1'b1;
      // side-set: drive the side-set pin window every engine cycle (SPEC v0.4)
      for (i = 0; i < 8; i = i + 1)
        if (i >= sideset_base && (i - sideset_base) < side_set_count)
          pins[i] <= sideset_val[i - sideset_base];
      case (op)
        OP_SET: begin
          case (opA)
            3'd0: begin // SET pins, imm  -> drive opB[set_count-1:0] window onto set_base..
              for (i = 0; i < 8; i = i + 1)
                if (i >= set_base && (i - set_base) < set_count && (i - set_base) < 5)
                  pins[i] <= opB[i - set_base];
            end
            3'd1: x <= opB;
            3'd2: y <= opB;
            3'd4: begin // SET pindirs, imm (SPEC v0.4: A=4) -> SAME window as SET PINS
              for (i = 0; i < 8; i = i + 1)
                if (i >= set_base && (i - set_base) < set_count && (i - set_base) < 5)
                  pindirs[i] <= opB[i - set_base];
            end
            default: ;
          endcase
        end
        OP_MOV: begin
          // dst A: 1=x, 2=y (others M2.1). src B[2:0] + op B[4:3] per SPEC v0.4.
          case (opA)
            3'd1: x <= move_val32;
            3'd2: y <= move_val32;
            default: ;
          endcase
        end
        OP_OUT: begin
          // OUT pins, n -> drive osr[out_count-1:0] onto out pins, then osr >>= out_count
          case (opA)
            3'd0: begin // OUT pins, n -> drive window from osr (dir per SHIFTCTRL), then shift osr
              for (i = 0; i < 8; i = i + 1)
                if (i >= out_base && (i - out_base) < out_count)
                  pins[i] <= shift_left ? osr[31 - (i - out_base)] : osr[i - out_base];
              osr <= (out_n >= 32) ? 32'b0 : (shift_left ? (osr << out_n) : (osr >> out_n));
            end
            3'd4: begin // OUT pindirs, n
              for (i = 0; i < 8; i = i + 1)
                if (i >= out_base && (i - out_base) < out_count)
                  pindirs[i] <= shift_left ? osr[31 - (i - out_base)] : osr[i - out_base];
              osr <= (out_n >= 32) ? 32'b0 : (shift_left ? (osr << out_n) : (osr >> out_n));
            end
            default: ;
          endcase
        end
        OP_IN: begin
          // IN pins, n -> isr = (isr >> in_count) | (pin_window << (32-in_count))
          // src A (SPEC v0.4): 0 pins (in_base window), 6 isr, 7 osr. Shift ISR per SHIFTCTRL.
          isr <= shift_left
                 ? ((isr << in_n) | (in_data & ((32'd1 << in_n) - 32'd1)))
                 : ((isr >> in_n) | (in_data << (32 - in_n)));
        end
        OP_PUSH: begin
          if (is_pull) begin
            if (txf_cnt != 0) begin
              osr <= txf[0];
              for (i = 0; i < 3; i = i + 1) txf[i] <= txf[i+1];
              txf_cnt <= txf_cnt - 1'b1;
            end else if (is_block) begin
              irq[0] <= 1'b1;   // block: stall (empty FIFO)
              pc <= pc;
            end else begin
              irq[0] <= 1'b1;   // noblock: proceed with the stale OSR
            end
          end else begin
            if (rxf_cnt != 4) begin
              rxf[rxf_cnt] <= isr;
              rxf_cnt <= rxf_cnt + 1'b1;
            end else begin
              irq[0] <= 1'b1;   // overrun
            end
          end
        end
        OP_JMP: begin
          case (opA)
            3'd0: pc <= jaddr;
            3'd1: if (x == 0) pc <= jaddr;
            3'd2: begin if (x != 0) pc <= jaddr; x <= x - 1'b1; end
            3'd3: if (y == 0) pc <= jaddr;
            3'd4: begin if (y != 0) pc <= jaddr; y <= y - 1'b1; end
            3'd5: if (x != y) pc <= jaddr;
            3'd6: if (jmp_pin) pc <= jaddr;
            3'd7: ;  // !OSRE needs the OSR bit count (autopull) - NOT implemented (flagged)
            default: ;
          endcase
        end
        OP_WAIT: begin
          // WAIT (SPEC v0.4): A[2]=pol, A[1:0]=src (0 gpio,1 pin,2 irq), B[2:0]=index
          if (!wait_ok) pc <= pc;      // stall until the condition holds
        end
        OP_IRQ: begin
          // A[2]=wait, A[1]=clear, A[0]=relative, B[2:0]=index
          if (opA[2]) begin if (!irq[opB[2:0]]) pc <= pc; end
          else if (opA[1]) irq[opB[2:0]] <= 1'b0;
          else             irq[opB[2:0]] <= 1'b1;
        end
        default: ;
      endcase
      end          // delay gate
      end          // enable && tick
    end
  end

  assign pin_out   = pins;
  assign pin_dir   = pindirs & ~(open_drain & pins);  // OPEN_DRAIN: driven-1 -> release
  assign irq_flags = irq;
  assign pc_out    = pc;
  assign stalled   = enable && (op == OP_PUSH) && is_pull && is_block && (txf_cnt == 0);

endmodule
