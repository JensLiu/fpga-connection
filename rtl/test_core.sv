// Simulation-only core stimulus — model A (see PROTOCOL_DESIGN.md §8).
//
// Loops:  SETTLE → TX (present one MSG_BYTES message) → WAIT_DONE → GAP → …
//
// TX presents a single logical message larger than BUFFER_SIZE so the engine
// must chunk it across several SDR polls/token rounds. It holds wr_total_len
// and streams MSG_WORDS words while wr_valid; the engine pulls one word per
// wr_ready pulse. When the whole message is out the engine strobes wr_done and
// we move to a GAP so the peer FPGA's RX can be observed.
//
// Pass +fpga_id=N on the Verilator command line to tag all output lines.
// TX word data: { fpga_id[7:0], 8'h00, word_idx[15:0] }.

module test_core #(
    parameter int unsigned SETTLE_CYCLES = 100_000,  // startup delay before first TX
    parameter int unsigned MSG_BYTES     = 200,       // total bytes per message
    parameter int unsigned GAP_CYCLES    = 600_000,   // idle gap between messages
    parameter int unsigned DATA_WIDTH    = 32,
    parameter int unsigned LEN_WIDTH     = 8
) (
    input  logic clk,
    input  logic rst_n,
    core_sdr_if.master core
);

  localparam int unsigned WORD_BYTES = DATA_WIDTH / 8;                 // 4
  localparam int unsigned MSG_WORDS  = (MSG_BYTES + WORD_BYTES - 1) / WORD_BYTES;

  logic [31:0] fpga_id;
  initial begin
    fpga_id = 0;
    void'($value$plusargs("fpga_id=%d", fpga_id));
  end

  typedef enum logic [1:0] { S_SETTLE, S_TX, S_WAIT_DONE, S_GAP } state_t;

  state_t state;
  logic [$clog2(SETTLE_CYCLES+1)-1:0] settle_cnt;
  logic [$clog2(GAP_CYCLES+1)-1:0]    gap_cnt;
  logic [15:0]                         word_idx;   // next word to present
  logic [31:0]                         msg_num;    // completed messages, for logging

  // Hold wr_valid until all words of the message have been consumed.
  assign core.rd_ready    = 1'b1;
  assign core.wr_valid    = (state == S_TX) && (word_idx < 16'(MSG_WORDS));
  assign core.wr_total_len = 16'(MSG_BYTES);
  assign core.wr_data     = {fpga_id[7:0], 8'h00, word_idx};

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state      <= S_SETTLE;
      settle_cnt <= '0;
      gap_cnt    <= '0;
      word_idx   <= '0;
      msg_num    <= '0;
    end else begin
      case (state)

        S_SETTLE:
          if (settle_cnt == ($clog2(SETTLE_CYCLES+1))'(SETTLE_CYCLES)) begin
            word_idx <= '0;
            state    <= S_TX;
          end else
            settle_cnt <= settle_cnt + 1;

        S_TX:
          if (core.wr_valid && core.wr_ready) begin
            $display("[FPGA%0d] TX msg#%0d word %0d/%0d  data=0x%08x",
                     fpga_id, msg_num, word_idx, MSG_WORDS, core.wr_data);
            if (word_idx == 16'(MSG_WORDS) - 1)
              state <= S_WAIT_DONE;   // last word consumed; wait for engine done
            word_idx <= word_idx + 1;
          end

        S_WAIT_DONE:
          if (core.wr_done) begin
            $display("[FPGA%0d] TX msg#%0d done (%0d bytes)",
                     fpga_id, msg_num, MSG_BYTES);
            msg_num <= msg_num + 1;
            gap_cnt <= '0;
            state   <= S_GAP;
          end

        S_GAP:
          if (gap_cnt == ($clog2(GAP_CYCLES+1))'(GAP_CYCLES)) begin
            word_idx <= '0;
            state    <= S_TX;
          end else
            gap_cnt <= gap_cnt + 1;

        default: state <= S_SETTLE;
      endcase

      // Print every received word, regardless of phase.
      if (core.rd_valid && core.rd_ready)
        $display("[FPGA%0d] RX msg#%0d      data=0x%08x (len=%0d B%s)",
                 fpga_id, msg_num, core.rd_data, core.rd_len,
                 core.rd_last ? ", last" : "");
    end
  end

endmodule
