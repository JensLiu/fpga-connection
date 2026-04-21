// Simulation-only core stimulus.
//
// Continuously loops:  SETTLE → TX (TX_BURSTS words) → GAP → TX → GAP → …
//
// The GAP phase deasserts wr_valid so the engine can complete END_TX/ACK_RX
// and stay in S_IDLE long enough to drain any buffered incoming DATA packets
// from the other FPGA.  No explicit coordination between the two FPGAs is
// needed; each just prints whatever RX words arrive during its gap.
//
// Timing note: with the default UART divisor of 868 (115200 baud @ 100 MHz),
// one 6-byte packet costs ~52k clock cycles.  A burst of TX_BURSTS words plus
// the END_TX/ACK_RX overhead and receiving TX_BURSTS words back takes roughly
// 1 M cycles ≈ 7 s of real wall time at the current Verilator simulation
// speed.  Set GAP_CYCLES large enough to cover this.  For faster simulation,
// lower the UART divisor in uart_top.sv and sim.cpp (must match).
//
// Pass +fpga_id=N on the Verilator command line to tag all output lines.
// TX data: { fpga_id[7:0], 8'h00, 8'h00, burst_word_idx }.
//
// Replace with the real OpenPiton core interface when ready.

module test_core #(
    parameter int unsigned SETTLE_CYCLES = 100_000,  // startup delay before first TX
    parameter int unsigned TX_BURSTS     = 8,         // words per TX burst
    parameter int unsigned GAP_CYCLES    = 600_000,   // idle gap between bursts
    parameter int unsigned DATA_WIDTH    = 32,
    parameter int unsigned LEN_WIDTH     = 8
) (
    input  logic clk,
    input  logic rst_n,
    core_sdr_if.master core
);

  logic [31:0] fpga_id;
  initial begin
    fpga_id = 0;
    void'($value$plusargs("fpga_id=%d", fpga_id));
  end

  typedef enum logic [1:0] { S_SETTLE, S_TX, S_GAP } state_t;

  state_t  state;
  logic [$clog2(SETTLE_CYCLES+1)-1:0] settle_cnt;
  logic [$clog2(TX_BURSTS+1)-1:0]     burst_cnt;
  logic [$clog2(GAP_CYCLES+1)-1:0]    gap_cnt;
  logic [31:0]                         burst_num;  // total completed bursts, for logging

  assign core.rd_ready = 1'b1;
  assign core.wr_valid = (state == S_TX);
  assign core.wr_data  = {fpga_id[7:0], 8'h00, 8'h00, 8'(burst_cnt)};
  assign core.wr_len   = {{(LEN_WIDTH-3){1'b0}}, 3'd4};  // 4 valid bytes

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= S_SETTLE;
      settle_cnt <= '0;
      burst_cnt  <= '0;
      gap_cnt    <= '0;
      burst_num  <= '0;
    end else begin
      case (state)

        S_SETTLE:
          if (settle_cnt == ($clog2(SETTLE_CYCLES+1))'(SETTLE_CYCLES))
            state <= S_TX;
          else
            settle_cnt <= settle_cnt + 1;

        S_TX:
          if (core.wr_valid && core.wr_ready) begin
            $display("[FPGA%0d] TX #%0d.%0d  data=0x%08x",
                     fpga_id, burst_num, burst_cnt, core.wr_data);
            if (burst_cnt == ($clog2(TX_BURSTS+1))'(TX_BURSTS - 1)) begin
              burst_cnt <= '0;
              gap_cnt   <= '0;
              burst_num <= burst_num + 1;
              state     <= S_GAP;
            end else begin
              burst_cnt <= burst_cnt + 1;
            end
          end

        S_GAP:
          if (gap_cnt == ($clog2(GAP_CYCLES+1))'(GAP_CYCLES))
            state <= S_TX;
          else
            gap_cnt <= gap_cnt + 1;

        default: state <= S_SETTLE;
      endcase

      // Print every received word, regardless of which phase we are in
      if (core.rd_valid && core.rd_ready)
        $display("[FPGA%0d] RX #%0d      data=0x%08x (len=%0d B)",
                 fpga_id, burst_num, core.rd_data, core.rd_len);
    end
  end

endmodule
