`timescale 1ns / 1ps

// Protocol engine — FPGA side.
//
//   S_UNINIT       Sends OP_POLL every POLL_PERIOD cycles until OP_READY arrives.
//   S_IDLE         SDR is in RX mode. Routes incoming OP_DATA to core.
//                  On core write request: negotiates TX mode.
//   S_WAIT_ACK_TX  Sent OP_REQ_TX, waiting for OP_ACK_TX.
//   S_TX_STREAMING Sending OP_DATA packets from core to SDR.
//   S_TX_PAUSED    Received OP_PAUSE from SDR; holding until OP_RESUME.
//   S_WAIT_ACK_RX  Sent OP_END_TX, waiting for OP_ACK_RX.
//   S_RX_STREAMING Forwarding OP_DATA from SDR to core.

module sdr_ctrl_protocol_engine
  import pkg_sdr_ctrl_protocol::*;
#(
    parameter int unsigned POLL_PERIOD = 1000  // clk cycles between POLLs in S_UNINIT
) (
    input logic clk,
    input logic rst_n,
    core_sdr_if.slave            core,
    sdr_ctrl_protocol_if.master  req,   // FPGA → SDR
    sdr_ctrl_protocol_if.slave   rsp    // SDR → FPGA
);

  if (MAX_PAYLOAD_BYTES > 255) begin : gen_payload_size_check
    $error("MAX_PAYLOAD_BYTES=%0d exceeds 8-bit len field", MAX_PAYLOAD_BYTES);
  end

  typedef enum logic [2:0] {
    S_UNINIT,         // waiting for SDR to boot
    S_IDLE,           // SDR in RX, no active core request
    S_WAIT_ACK_TX,    // sent REQ_TX, waiting for ACK_TX
    S_TX_STREAMING,   // pushing DATA to SDR
    S_TX_PAUSED,      // SDR back-pressured, waiting for RESUME
    S_WAIT_ACK_RX,    // sent END_TX, waiting for ACK_RX
    S_RX_STREAMING    // forwarding SDR RX samples to core
  } state_t;

  state_t state, state_n;

  logic [$clog2(POLL_PERIOD)-1:0] poll_cnt, poll_cnt_n;

  // Handshake fire signals — must be assign, not logic initialisation
  logic    rsp_fire, req_fire, core_wr_fire, core_rd_fire;
  opcode_t rsp_op;
  assign rsp_fire    = rsp.valid  && rsp.ready;
  assign rsp_op      = rsp.data.opcode;
  assign req_fire    = req.valid  && req.ready;
  assign core_wr_fire = core.wr_valid && core.wr_ready;
  assign core_rd_fire = core.rd_valid && core.rd_ready;

  // Build a zero-payload control packet
  function automatic protocol_t ctrl_pkt(input opcode_t op);
    ctrl_pkt.opcode  = op;
    ctrl_pkt.len     = 8'h00;
    ctrl_pkt.payload = '0;
  endfunction

  always_comb begin
    // Output defaults
    state_n    = state;
    poll_cnt_n = poll_cnt;
    req.valid  = 0;
    req.data   = ctrl_pkt(OP_POLL);
    rsp.ready  = 0;
    core.wr_ready = 0;
    core.rd_valid = 0;
    core.rd_data  = '0;
    core.rd_len   = '0;

    case (state)

      // -----------------------------------------------------------------------
      S_UNINIT: begin
        rsp.ready = 1;
        if (rsp_fire && rsp_op == OP_READY) begin
          state_n = S_IDLE;
        end else if (poll_cnt == 0) begin
          req.valid  = 1;
          req.data   = ctrl_pkt(OP_POLL);
          poll_cnt_n = ($clog2(POLL_PERIOD))'(POLL_PERIOD - 1);
        end else begin
          poll_cnt_n = poll_cnt - 1;
        end
      end

      // -----------------------------------------------------------------------
      S_IDLE: begin
        rsp.ready = 1;
        if (core.wr_valid) begin
          // Core wants to push OTA data — request TX mode from SDR
          req.valid = 1;
          req.data  = ctrl_pkt(OP_REQ_TX);
          if (req_fire)
            state_n = S_WAIT_ACK_TX;
        end else if (rsp_fire && rsp_op == OP_DATA) begin
          // SDR has RX samples; present first word to core and start streaming
          core.rd_valid = 1;
          core.rd_data  = rsp.data.payload[$bits(core.rd_data)-1:0];
          core.rd_len   = rsp.data.len;
          if (core_rd_fire)
            state_n = S_RX_STREAMING;
        end
        // Unsolicited PAUSE/RESUME in IDLE are silently ignored.
      end

      // -----------------------------------------------------------------------
      S_WAIT_ACK_TX: begin
        rsp.ready = 1;
        if (rsp_fire && rsp_op == OP_ACK_TX)
          state_n = S_TX_STREAMING;
      end

      // -----------------------------------------------------------------------
      S_TX_STREAMING: begin
        rsp.ready = 1;
        if (rsp_fire && rsp_op == OP_PAUSE) begin
          state_n = S_TX_PAUSED;
        end else if (core.wr_valid) begin
          // Forward one word from core as a DATA packet
          assert (core.wr_len <= 8'(MAX_PAYLOAD_BYTES))
            else $fatal(1, "core.wr_len=%0d exceeds MAX_PAYLOAD_BYTES=%0d",
                        core.wr_len, MAX_PAYLOAD_BYTES);
          req.valid        = 1;
          req.data.opcode  = OP_DATA;
          req.data.len     = {{(8-$bits(core.wr_len)){1'b0}}, core.wr_len};
          req.data.payload = {{($bits(req.data.payload)-$bits(core.wr_data)){1'b0}}, core.wr_data};
          if (req_fire)
            core.wr_ready = 1;  // acknowledge consumed word to core
        end else begin
          // Core has no more data — end the TX burst
          req.valid = 1;
          req.data  = ctrl_pkt(OP_END_TX);
          if (req_fire)
            state_n = S_WAIT_ACK_RX;
        end
      end

      // -----------------------------------------------------------------------
      S_TX_PAUSED: begin
        rsp.ready = 1;
        if (rsp_fire && rsp_op == OP_RESUME)
          state_n = S_TX_STREAMING;
      end

      // -----------------------------------------------------------------------
      S_WAIT_ACK_RX: begin
        rsp.ready = 1;
        if (rsp_fire && rsp_op == OP_ACK_RX)
          state_n = S_IDLE;
      end

      // -----------------------------------------------------------------------
      S_RX_STREAMING: begin
        rsp.ready = core.rd_ready;  // only consume when core can accept
        if (rsp_fire && rsp_op == OP_DATA) begin
          core.rd_valid = 1;
          core.rd_data  = rsp.data.payload[$bits(core.rd_data)-1:0];
          core.rd_len   = rsp.data.len;
        end else if (!rsp.valid) begin
          // SDR stopped sending — return to IDLE
          state_n = S_IDLE;
        end
      end

      default: $fatal(1, "Unreachable sdr_ctrl_protocol_engine state");

    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state    <= S_UNINIT;
      poll_cnt <= '0;
    end else begin
      state    <= state_n;
      poll_cnt <= poll_cnt_n;
    end
  end

endmodule
