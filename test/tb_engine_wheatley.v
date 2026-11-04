/*
 * Wheatley - independent engine checks for src/pio_engine.v (SPEC v0.4).
 * Self-checking iverilog TB (no cocotb needed):
 *   iverilog -g2012 -o /tmp/tbw.out src/pio_engine.v test/tb_engine_wheatley.v && vvp /tmp/tbw.out
 * Covers the fixes: SET PINDIRS window, MOV :: (32-bit), IN in_base window, delay field.
 */
`timescale 1ns/1ps
module tb_engine_wheatley;
  reg clk=0, rst_n=0, enable=0;
  reg imem_we=0; reg [4:0] imem_addr=0; reg [15:0] imem_wdata=0;
  reg [15:0] clkdiv=16'd1;
  reg txf_we=0; reg [31:0] txf_wdata=0; wire txf_full;
  reg rxf_re=0; wire [31:0] rxf_rdata; wire rxf_empty;
  reg [7:0] pin_in=8'h02; wire [7:0] pin_out, pin_dir;
  reg [2:0] in_base=3'd1, out_base=3'd0, set_base=3'd2;
  reg [3:0] set_count=4'd2, out_count=4'd1, in_count=4'd1;
  reg shift_left=0; reg [2:0] side_set_count=3'd0, sideset_base=3'd0;
  wire [7:0] irq_flags; wire [4:0] pc_out; wire stalled;
  pio_engine #(.IMEM_AW(5)) dut(.clk(clk),.rst_n(rst_n),.imem_we(imem_we),.imem_addr(imem_addr),
    .imem_wdata(imem_wdata),.enable(enable),.clkdiv(clkdiv),.txf_we(txf_we),.txf_wdata(txf_wdata),
    .txf_full(txf_full),.rxf_re(rxf_re),.rxf_rdata(rxf_rdata),.rxf_empty(rxf_empty),.pin_in(pin_in),
    .pin_out(pin_out),.pin_dir(pin_dir),.in_base(in_base),.out_base(out_base),.set_base(set_base),
    .set_count(set_count),.out_count(out_count),.in_count(in_count),.shift_left(shift_left),
    .side_set_count(side_set_count),.sideset_base(sideset_base),
    .irq_flags(irq_flags),.pc_out(pc_out),.stalled(stalled));
  always #5 clk=~clk;
  integer n, fails=0;
  task wr(input [5:0] a, input [15:0] d); begin
    @(negedge clk); imem_we=1; imem_addr=a; imem_wdata=d; @(negedge clk); imem_we=0; end endtask
  initial begin
    // [0] SET pindirs,imm=3 (A=4) ; [1] SET x,0x11 ; [2] MOV y,::x ; [3] IN pins,1 ; [4] JMP 4
    rst_n=0; enable=0;
    wr(0,16'hE083); wr(1,16'hE031); wr(2,16'hA051); wr(3,16'h4001); wr(4,16'h0004);
    @(negedge clk); rst_n=1; enable=1; repeat(10) @(negedge clk);
    if (pin_dir !== 8'b00001100) begin $display("FAIL pindirs=%b", pin_dir); fails=fails+1; end else $display("PASS pindirs window");
    if (dut.y !== 32'h88000000) begin $display("FAIL y=%h", dut.y); fails=fails+1; end else $display("PASS MOV :: 32-bit");
    if (dut.isr[31] !== 1'b1) begin $display("FAIL isr=%b", dut.isr); fails=fails+1; end else $display("PASS IN in_base window");

    // delay check: [0]=SET x,0 [delay=4]; [1]=SET pins,1
    rst_n=0; enable=0;
    wr(0,(7<<13)|(4<<8)|0); wr(1,(7<<13)|(0<<5)|1);
    @(negedge clk); rst_n=1; enable=1;
    n=0; while (pin_out==0 && n<40) begin @(negedge clk); n=n+1; end
    if (n !== 6) begin $display("FAIL delay count=%0d (exp 6)", n); fails=fails+1; end else $display("PASS delay=4 (6 ticks)");

    if (fails==0) $display("ALL PASS"); else $fatal(1, "FAILURES=%0d", fails);
    $finish;
  end
endmodule
