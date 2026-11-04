`default_nettype none
`timescale 1ns / 1ps
// Unit TB for pio_engine: load an unrolled UART TX program and capture the TX pin.
module tb_engine ();
  reg clk = 0, rst_n = 0, enable = 0;
  reg imem_we = 0; reg [5:0] imem_addr = 0; reg [15:0] imem_wdata = 0;
  reg [15:0] clkdiv = 1;
  reg txf_we = 0; reg [31:0] txf_wdata = 0;
  reg [7:0] pin_in = 0;
  wire txf_full, rxf_empty, stalled;
  wire [31:0] rxf_rdata;
  wire [7:0] pin_out, pin_dir;
  wire [3:0] irq_flags;
  wire [5:0] pc_out;

  pio_engine #(.IMEM_AW(5)) dut (
    .clk(clk), .rst_n(rst_n), .imem_we(imem_we), .imem_addr(imem_addr), .imem_wdata(imem_wdata),
    .enable(enable), .clkdiv(clkdiv),
    .txf_we(txf_we), .txf_wdata(txf_wdata), .txf_full(txf_full),
    .rxf_re(0), .rxf_rdata(rxf_rdata), .rxf_empty(rxf_empty),
    .pin_in(pin_in), .pin_out(pin_out), .pin_dir(pin_dir),
    .in_base(3'd0), .out_base(3'd0), .set_base(3'd0),
    .set_count(4'd1), .out_count(4'd1), .in_count(4'd1),
    .shift_left(1'b0),  // SHIFTCTRL: 0 = LSB-first (UART)
    .irq_flags(irq_flags), .pc_out(pc_out), .stalled(stalled)
  );

  always #5 clk = ~clk;  // 10ns period
endmodule
