/*
 * Wheatley - M3.2 cfg-loop gate.
 * Load the uart_tx program + CLKDIV + ENABLE + a TX byte THROUGH THE CFG PORT (uio[7:4]),
 * then check engine0's TX pin against firmware/vectors/uart_tx.json (the shared uart_ref frame).
 * Non-vacuous: on the pre-fix cfg FSM (off-by-one frame decode) this FAILs; on the fix it PASSes.
 * iverilog -g2012 -o /tmp/tbcfg.out src/pio_engine.v src/project.v test/tb_uart_cfg.v && vvp /tmp/tbcfg.out
 */
`timescale 1ns/1ps
module tb_uart_cfg;
  reg clk=0, rst_n=0, ena=1;
  reg [7:0] ui_in=0, uio_in=0;
  wire [7:0] uo_out, uio_out, uio_oe;
  tt_um_protocol_emulator #(.NENG(3)) dut(.ui_in(ui_in),.uo_out(uo_out),
    .uio_in(uio_in),.uio_out(uio_out),.uio_oe(uio_oe),.ena(ena),.clk(clk),.rst_n(rst_n));
  always #5 clk=~clk;
  integer i,j,ns,match,bi,ok; reg samp [0:299]; reg expv [0:79];
  reg [39:0] frame;
  integer words [0:7];

  task send_frame(input [7:0] cmd, input [31:0] pay); integer b; begin
    frame = {cmd, pay};
    uio_in[6] = 1'b1;                  // cfg_load
    for (b=39;b>=0;b=b-1) begin
      uio_in[5] = frame[b];            // cfg_din, MSB-first
      @(negedge clk); uio_in[4]=1'b1;  // cfg_clk rise next posedge
      @(negedge clk); uio_in[4]=1'b0;
    end
  end endtask

  initial begin
    words[0]=32928; words[1]=57473; words[2]=57383; words[3]=59136;
    words[4]=24577; words[5]=1604; words[6]=59137; words[7]=0;
    rst_n=0; repeat(3) @(negedge clk); rst_n=1;
    for (i=0;i<8;i=i+1) send_frame(8'h01, (i<<16)|words[i]);   // IMEM_WRITE x8 -> engine0 bank
    send_frame(8'h02, {2'd0,4'd0,24'd1});                      // SM0 CLKDIV = 1
    send_frame(8'h02, {2'd0,4'd3,24'd1});                      // SM0 ENABLE = 1
    send_frame(8'h03, {2'd0,26'h41});                          // SM0 TXF_PUSH 0x41
    uio_in[6]=1'b0; @(negedge clk);
    // sample engine0 TX (uio_out[0]) each clock for 300 cycles
    for (ns=0; ns<300; ns=ns+1) begin @(negedge clk); samp[ns]=uio_out[0]; end
    // expected 0x41 (uart_ref): start 0, LSB-first 0x41, stop 1, 8 cycles each
    for (j=0;j<80;j=j+1) begin
      bi=j/8;
      if (bi==0) expv[j]=0; else if (bi<=8) expv[j]=(65>>(bi-1))&1; else expv[j]=1;
    end
    match=-1;
    for (i=0;i<=ns-80 && match<0;i=i+1) begin
      ok=1;
      for (j=0;j<80;j=j+1) if (samp[i+j]!==expv[j]) ok=0;
      if (ok) match=i;
    end
    // Gort 18:41:53: assert the TX pin is actually driven (pindirs), same class as test_engine.
    if (match>=0 && dut.e_pin_dir[0][0]!==1'b1) begin
      match=-1; $display("FAIL: TX frame matched but pin_dir[0]=%b (pin not driven)", dut.e_pin_dir[0][0]);
    end
    if (match>=0) $display("PASS cfg-loop: engine0 TX frame for 0x41 matches uart_ref at sample %0d", match);
    else          $display("FAIL cfg-loop: pin_dir0[0]=%b enable0=%b", dut.e_pin_dir[0][0], dut.enable[0]);

    // ---- phase 2: FSTAT overrun status THROUGH THE TOP (Gort 19:59:30 / Vision 19:58:50) ----
    // Reload engine0 with 5x 'push noblock' (0x8000) + halt; 5 pushes fill the 4-deep RXF -> overrun.
    send_frame(8'h02, {2'd0,4'd3,24'd0});        // SM0 ENABLE = 0 (reconfig)
    for (i=0;i<5;i=i+1) send_frame(8'h01, (i<<16)|16'h8000);
    send_frame(8'h01, (5<<16)|16'h0005);         // halt: jmp 5
    send_frame(8'h02, {2'd0,4'd3,24'd1});        // SM0 ENABLE = 1
    uio_in[6]=1'b0; repeat(20) @(negedge clk);
    if (uo_out[3] !== 1'b1) begin
      $display("FAIL fstat: 5x push noblock -> uo_out[3]=%b (expected 1), any_overrun=%b", uo_out[3], dut.any_overrun);
      $finish;
    end
    $display("PASS fstat: RXF overrun drives uo_out[3]=1 through the top (any_overrun=%b)", dut.any_overrun);
    $finish;
  end
endmodule
