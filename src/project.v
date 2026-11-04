/*
 * Copyright (c) 2024 Vision
 * SPDX-License-Identifier: Apache-2.0
 *
 * tt_um_protocol_emulator - M3 top-level: 4 PIO-style engines + shared cfg port.
 *
 * Engines: 4 x pio_engine, each owns a 32x16 instruction bank (imem writes are
 * banked: cfg IMEM_WRITE addr[6:5] = engine, addr[4:0] = offset).
 *
 * GPIO: the 8 bidirectional uio pins are the engine GPIO port (uio_out = pin_out,
 * uio_oe = pin_dir, pin_in = uio_in). uo_out = debug/status.
 *
 * Cfg port (time-muxed on uio[7:4] while uio_in[6]=cfg_load):
 *   uio[4] = cfg_clk (rising edge shifts one bit)
 *   uio[5] = cfg_din (host -> chip; M3 is write-only; bidir readback = M3.1)
 *   uio[6] = cfg_load
 *   uio[7] = cfg_done (chip -> host, pulsed after a command executes)
 * Frame: 8-bit cmd then 32-bit payload MSB-first.
 *   cmd 0x01 IMEM_WRITE  payload = {addr[6:0], instr[15:0]}  (addr[6:5]=engine)
 *   cmd 0x02 SM_REG      payload = {sm[1:0], reg[3:0], value[23:0]}
 *                        reg 0 CLKDIV, 1 PINCTRL, 2 SHIFTCTRL, 3 ENABLE
 *   cmd 0x03 TXF_PUSH    payload = {sm[1:0], 4'b0, word[25:0]}
 *   cmd 0x04 DONE        payload ignored (engines run once their ENABLE bit is set)
 */

`default_nettype none

module tt_um_protocol_emulator #(
    parameter integer NENG = 3   // number of pio_engine instances (3 = functional floor for concurrent UART+SPI+I2C)
) (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);

  // cfg pins (on uio[7:4] while cfg_load)
  wire cfg_clk  = uio_in[4];
  wire cfg_din  = uio_in[5];
  wire cfg_load = uio_in[6];
  reg  cfg_done;

  // per-engine control
  reg  [15:0] clkdiv   [0:NENG-1];
  // PINCTRL split (SPEC §9, Weyland 18:02:56): reg1 = PINCTRL-A (open_drain + bases),
  // reg5 = PINCTRL-B (counts + side-set). Per engine.
  reg  [7:0]  open_drain  [0:NENG-1];
  reg  [2:0]  in_base     [0:NENG-1];
  reg  [2:0]  out_base    [0:NENG-1];
  reg  [2:0]  set_base    [0:NENG-1];
  reg  [3:0]  in_count    [0:NENG-1];
  reg  [3:0]  out_count   [0:NENG-1];
  reg  [3:0]  set_count   [0:NENG-1];
  reg  [2:0]  side_set_count [0:NENG-1];
  reg  [2:0]  sideset_base  [0:NENG-1];
  reg  [7:0]  shiftctl [0:NENG-1];
  reg         enable   [0:NENG-1];

  // engine <-> top wiring
  wire [7:0]  e_pin_out [0:NENG-1];
  wire [7:0]  e_pin_dir [0:NENG-1];
  wire [3:0]  e_irq     [0:NENG-1];
  wire        e_txf_full[0:NENG-1];
  wire        e_stalled [0:NENG-1];
  wire [4:0]  e_pc      [0:NENG-1];

  // imem write bus (banked)
  reg         imem_we   [0:NENG-1];
  reg  [4:0]  imem_addr [0:NENG-1];
  reg  [15:0] imem_wdata[0:NENG-1];

  // txf push bus
  reg         txf_we    [0:NENG-1];
  reg  [31:0] txf_wdata [0:NENG-1];

  // pin bases/counts: one shared convention for M3 (engine 0 tx etc. are firmware's job);
  // for now expose fixed nibble fields from pinctrl: base = pinctrl[6:4], count = pinctrl[3:0]+1
  // (firmware sets these; M3.1 makes it a proper register map). Defaults below.
  // OR only over the instantiated engines (NENG), so a 3-engine build does not read e_pin_out[3].
  reg  [7:0] engine_pin_out;
  reg  [7:0] engine_pin_dir;
  integer gi;
  always @* begin
    engine_pin_out = 8'b0;
    engine_pin_dir = 8'b0;
    for (gi = 0; gi < NENG; gi = gi + 1) begin
      engine_pin_out = engine_pin_out | e_pin_out[gi];
      engine_pin_dir = engine_pin_dir | e_pin_dir[gi];
    end
  end

  genvar g;
  generate
    for (g = 0; g < NENG; g = g + 1) begin : eng
      pio_engine #(.IMEM_AW(5)) u_eng (
        .clk(clk), .rst_n(rst_n),
        .imem_we(imem_we[g]), .imem_addr(imem_addr[g]), .imem_wdata(imem_wdata[g]),
        .enable(enable[g]), .clkdiv(clkdiv[g]),
        .txf_we(txf_we[g]), .txf_wdata(txf_wdata[g]), .txf_full(e_txf_full[g]),
        .rxf_re(1'b0), .rxf_rdata(), .rxf_empty(),
        .pin_in(uio_in), .pin_out(e_pin_out[g]), .pin_dir(e_pin_dir[g]),
        .in_base(in_base[g]), .out_base(out_base[g]), .set_base(set_base[g]),
        .set_count(set_count[g]), .out_count(out_count[g]), .in_count(in_count[g]),
        .shift_left(shiftctl[g][0]),
        .side_set_count(side_set_count[g]), .sideset_base(sideset_base[g]),
        .open_drain(open_drain[g]),
        .jmp_pin(1'b0),
        .irq_flags(e_irq[g]), .pc_out(e_pc[g]), .stalled(e_stalled[g])
      );
    end
  endgenerate

  // ---- cfg FSM: 8-bit cmd + 32-bit payload, MSB-first -------------------
  reg [39:0] shreg;
  reg [5:0]  bitcnt;      // 0..39
  reg        cfg_clk_d;
  wire       cfg_clk_rise = cfg_clk & ~cfg_clk_d;

  // decoded fields
  // On the 40th bit (bitcnt==39) shreg holds bits 0..38 (shreg[38]=bit0) and cfg_din is
  // bit39, so the completed frame = {shreg[38:0], cfg_din}; cmd = bits 0..7, payload = 8..39.
  wire [7:0]  cmd     = shreg[38:31];
  wire [31:0] payload = {shreg[30:0], cfg_din};
  wire [6:0]  im_addr = payload[22:16];
  wire [15:0] im_data = payload[15:0];
  wire [1:0]  sm_sel  = payload[29:28];
  wire [3:0]  reg_sel = payload[27:24];
  wire [23:0] reg_val = payload[23:0];
  wire [31:0] tx_word = {6'b0, payload[25:0]};

  integer k;
  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      cfg_clk_d <= 1'b0;
      shreg <= 40'd0;
      bitcnt <= 6'd0;
      cfg_done <= 1'b0;
      for (k = 0; k < NENG; k = k + 1) begin
        clkdiv[k] <= 16'd1;
        open_drain[k] <= 8'd0;
        in_base[k] <= 3'd0; out_base[k] <= 3'd0; set_base[k] <= 3'd0;
        in_count[k] <= 4'd1; out_count[k] <= 4'd1; set_count[k] <= 4'd1;
        side_set_count[k] <= 3'd0; sideset_base[k] <= 3'd0;
        shiftctl[k] <= 8'd0;
        enable[k] <= 1'b0;
        imem_we[k] <= 1'b0;
        imem_addr[k] <= 5'd0;
        imem_wdata[k] <= 16'd0;
        txf_we[k] <= 1'b0;
        txf_wdata[k] <= 32'd0;
      end
    end else begin
      cfg_clk_d <= cfg_clk;
      for (k = 0; k < NENG; k = k + 1) begin
        imem_we[k] <= 1'b0;
        txf_we[k]  <= 1'b0;
      end
      cfg_done <= 1'b0;

      if (cfg_load && cfg_clk_rise) begin
        shreg <= {shreg[38:0], cfg_din};
        if (bitcnt == 6'd39) begin
          bitcnt <= 6'd0;
          // execute on the 40th bit (cmd/payload are the completed frame)
          case (cmd)
            8'h01: begin // IMEM_WRITE
              if (im_addr[6:5] < NENG) begin
                imem_we[im_addr[6:5]] <= 1'b1;
                imem_addr[im_addr[6:5]] <= im_addr[4:0];
                imem_wdata[im_addr[6:5]] <= im_data;
              end
            end
            8'h02: begin // SM_REG
              case (reg_sel)
                4'd0: clkdiv[sm_sel]   <= reg_val[15:0];
                4'd1: begin // PINCTRL-A: open_drain[7:0] | in_base[10:8] | out_base[13:11] | set_base[16:14]
                  open_drain[sm_sel] <= reg_val[7:0];
                  in_base[sm_sel]    <= reg_val[10:8];
                  out_base[sm_sel]   <= reg_val[13:11];
                  set_base[sm_sel]   <= reg_val[16:14];
                end
                4'd2: shiftctl[sm_sel] <= reg_val[7:0];
                4'd3: enable[sm_sel]   <= reg_val[0];
                4'd5: begin // PINCTRL-B: in_count[3:0] | out_count[7:4] | set_count[11:8] | side_set_count[14:12] | sideset_base[17:15]
                  in_count[sm_sel]       <= reg_val[3:0];
                  out_count[sm_sel]      <= reg_val[7:4];
                  set_count[sm_sel]      <= reg_val[11:8];
                  side_set_count[sm_sel] <= reg_val[14:12];
                  sideset_base[sm_sel]   <= reg_val[17:15];
                end
                default: ;
              endcase
            end
            8'h03: begin // TXF_PUSH
              if (sm_sel < NENG) begin
                txf_we[sm_sel] <= 1'b1;
                txf_wdata[sm_sel] <= tx_word;
              end
            end
            default: ;
          endcase
          cfg_done <= 1'b1;
        end else begin
          bitcnt <= bitcnt + 6'd1;
        end
      end
    end
  end

  // ---- pin mux: engine GPIO on uio[7:0] (cfg pins win while cfg_load) ----
  // uio[7] carries cfg_done (M3.0: dedicated to the cfg handshake; M3.1 proper mux).
  assign uio_out = {cfg_done, engine_pin_out[6:0]};
  assign uio_oe  = {1'b1, engine_pin_dir[6:0]};

  // status on uo_out
  assign uo_out  = {e_irq[0], e_stalled[0], e_pc[0]};

  // unused
  wire _unused = &{ena, ui_in, e_txf_full[0], 1'b0};

endmodule