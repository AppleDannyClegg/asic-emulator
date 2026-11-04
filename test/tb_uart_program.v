/*
 * Wheatley - M2 gate: run the UART TX *program* on pio_engine and compare the TX pin to
 * the shared reference (firmware/vectors/uart_tx.json, from uart_ref.py).
 * iverilog -g2012 -o /tmp/tbu.out src/pio_engine.v test/tb_uart_program.v && vvp /tmp/tbu.out
 */
`timescale 1ns/1ps
module tb_uart_program;
  reg clk=0, rst_n=0, enable=0;
  reg imem_we=0; reg [4:0] imem_addr=0; reg [15:0] imem_wdata=0;
  reg [15:0] clkdiv=16'd1;
  reg txf_we=0; reg [31:0] txf_wdata=0; wire txf_full;
  reg rxf_re=0; wire [31:0] rxf_rdata; wire rxf_empty;
  reg [7:0] pin_in=8'hFF; wire [7:0] pin_out, pin_dir;
  reg [2:0] in_base=0, out_base=0, set_base=0; reg [3:0] set_count=1,out_count=1,in_count=1;
  reg shift_left=0; reg [2:0] side_set_count=0, sideset_base=0; reg [7:0] open_drain=0; reg jmp_pin=0;
  wire [3:0] irq_flags; wire [4:0] pc_out; wire stalled;
  pio_engine #(.IMEM_AW(5)) dut(.clk(clk),.rst_n(rst_n),.imem_we(imem_we),.imem_addr(imem_addr),
    .imem_wdata(imem_wdata),.enable(enable),.clkdiv(clkdiv),.txf_we(txf_we),.txf_wdata(txf_wdata),
    .txf_full(txf_full),.rxf_re(rxf_re),.rxf_rdata(rxf_rdata),.rxf_empty(rxf_empty),.pin_in(pin_in),
    .pin_out(pin_out),.pin_dir(pin_dir),.in_base(in_base),.out_base(out_base),.set_base(set_base),
    .set_count(set_count),.out_count(out_count),.in_count(in_count),.shift_left(shift_left),
    .side_set_count(side_set_count),.sideset_base(sideset_base),.open_drain(open_drain),.jmp_pin(jmp_pin),
    .irq_flags(irq_flags),.pc_out(pc_out),.stalled(stalled));
  always #5 clk=~clk;
  integer words [0:7];
  integer N; reg [7:0] samples [0:299]; integer ns; integer i,j; integer match; integer byte_in;
  // expected frame for 0x41 (from firmware/vectors/uart_tx.json): start 0, LSB-first 0x41, stop 1
  integer vec [0:79];
  task load_vec41; integer k; begin
    // 0x41 = 01000001b ; LSB-first data bits: 1 0 0 0 0 0 1 0
    k=0;
    for (i=0;i<8;i=i+1) begin vec[k]=0; k=k+1; end                 // start, 8 cycles
    // data LSB-first: 1,0,0,0,0,0,1,0
    begin integer bpos; end
    for (i=0;i<8;i=i+1) begin integer b; b=(65>>i)&1; for(j=0;j<8;j=j+1) begin vec[k]=b; k=k+1; end end
    for (j=0;j<8;j=j+1) begin vec[k]=1; k=k+1; end                 // stop, 8 cycles
  end endtask
  initial begin
    words[0]=32928; words[1]=57473; words[2]=57383; words[3]=59136;
    words[4]=24577; words[5]=1604; words[6]=59137; words[7]=0;
    load_vec41();
    // program load
    rst_n=0; enable=0;
    for (i=0;i<8;i=i+1) begin @(negedge clk); imem_we=1; imem_addr=i[4:0]; imem_wdata=words[i][15:0]; end
    @(negedge clk); imem_we=0;
    // release reset, keep enable low, THEN push the byte (reset ignores host writes)
    @(negedge clk); rst_n=1; enable=0;
    @(negedge clk); txf_we=1; txf_wdata=32'h00000041;
    @(negedge clk); txf_we=0;
    @(negedge clk); enable=1;
    // sample TX pin each engine cycle until stalled
    ns=0;
    while (ns<300 && !stalled) begin @(negedge clk); samples[ns]=pin_out[0]; ns=ns+1; end
    $display("sampled %0d cycles, stalled=%b; searching for the 80-cycle frame", ns, stalled);
    match=-1;
    for (i=0;i<=ns-80 && match<0;i=i+1) begin
      begin : win
        integer ok; ok=1;
        for (j=0;j<80;j=j+1) if (samples[i+j] !== vec[j][0:0]) ok=0;
        if (ok) match=i;
      end
    end
    if (match>=0) $display("PASS: UART frame for 0x41 matches uart_ref at sample %0d", match);
    else begin
      $display("FAIL: no 80-cycle frame match. first 100 samples:");
      for (i=0;i<100 && i<ns;i=i+1) $write("%b", samples[i]);
      $write("\n");
    end
    $finish;
  end
endmodule
