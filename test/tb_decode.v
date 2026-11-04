`default_nettype none
`timescale 1ns / 1ps
// Decode-conformance TB for pio_engine (Gort). Driven by test_decode.py, which assembles every
// program with firmware/asm.py, so the words under test are the SPEC §3 v0.4 encodings.
// Window config is a TB input so each test can choose it.
module tb_decode ();
  reg clk = 0, rst_n = 0, enable = 0;
  reg imem_we = 0; reg [5:0] imem_addr = 0; reg [15:0] imem_wdata = 0;
  reg [15:0] clkdiv = 1;
  reg txf_we = 0; reg [31:0] txf_wdata = 0;
  reg rxf_re = 0;
  reg [7:0] pin_in = 0;
  reg [2:0] in_base = 0, out_base = 0, set_base = 0;
  reg [3:0] set_count = 4, out_count = 1, in_count = 1;
  reg shift_left = 0;
  wire txf_full, rxf_empty, stalled;
  wire [31:0] rxf_rdata;
  wire [7:0] pin_out, pin_dir;
  wire [3:0] irq_flags;
  wire [5:0] pc_out;

  pio_engine #(.IMEM_AW(6)) dut (
    .clk(clk), .rst_n(rst_n), .imem_we(imem_we), .imem_addr(imem_addr), .imem_wdata(imem_wdata),
    .enable(enable), .clkdiv(clkdiv),
    .txf_we(txf_we), .txf_wdata(txf_wdata), .txf_full(txf_full),
    .rxf_re(rxf_re), .rxf_rdata(rxf_rdata), .rxf_empty(rxf_empty),
    .pin_in(pin_in), .pin_out(pin_out), .pin_dir(pin_dir),
    .in_base(in_base), .out_base(out_base), .set_base(set_base),
    .set_count(set_count), .out_count(out_count), .in_count(in_count),
    .shift_left(shift_left),
    .irq_flags(irq_flags), .pc_out(pc_out), .stalled(stalled)
  );
endmodule
