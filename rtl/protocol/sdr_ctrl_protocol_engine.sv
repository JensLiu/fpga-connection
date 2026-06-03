`timescale 1ns / 1ps

// Protocol engine — FPGA side. Pull/credit redesign (see PROTOCOL_DESIGN.md).
//
// One physical SDR→FPGA wire carries both OP_POLL (TX control) and OP_DATA (RX
// samples), so a single shared decoder feeds an opcode DEMUX. The engine is
// otherwise two independent state machines:
//
//   TX engine  Owns the serialiser (`req`). Sends OP_READY once at boot, then
//              waits. Each OP_POLL grants a one-buffer credit (tracked as a
//              single bit). With a credit and a pending core message it
//              assembles one chunk of min(bytes_left, BUFFER_SIZE) bytes,
//              pulling words from the core, hands it to the serialiser, and
//              consumes the credit. wr_done strobes when bytes_left hits 0.
//
//   RX engine  Fire-and-forget. Latches each OP_DATA packet in one cycle (so
//              the decoder never stalls) and walks the payload to the core one
//              word per cycle, ignoring rd_ready.
//
//   Demux      OP_POLL → TX credit; OP_DATA → RX engine; else drop.

module sdr_ctrl_protocol_engine
  import pkg_sdr_ctrl_protocol::*;
#(
    // Resend OP_READY this often (in cycles) until the first poll arrives, so
    // boot tolerates either power-up order / a late-connecting SDR.
    parameter int unsigned READY_PERIOD = 50_000
) (
    input logic clk,
    input logic rst_n,
    core_sdr_if.slave            core,
    sdr_ctrl_protocol_if.master  req,   // FPGA → SDR (serialiser)
    sdr_ctrl_protocol_if.slave   rsp    // SDR → FPGA (decoder)
);

  localparam int unsigned DATA_WIDTH = 32;                  // core word width
  localparam int unsigned DATA_BYTES = DATA_WIDTH / 8;      // 4
  localparam int unsigned PAY_BITS   = MAX_PAYLOAD_BYTES*8; // chunk payload bits

  if (MAX_PAYLOAD_BYTES > 255) begin : gen_len_check
    $error("BUFFER_SIZE=%0d exceeds 8-bit len field", MAX_PAYLOAD_BYTES);
  end
  if (MAX_PAYLOAD_BYTES % DATA_BYTES != 0) begin : gen_align_check
    $error("BUFFER_SIZE=%0d must be a multiple of the core word size (%0d B)",
           MAX_PAYLOAD_BYTES, DATA_BYTES);
  end

  function automatic protocol_t ctrl_pkt(input opcode_t op);
    ctrl_pkt.opcode  = op;
    ctrl_pkt.len     = 8'h00;
    ctrl_pkt.payload = '0;
  endfunction

  // ---------------------------------------------------------------------------
  // Inbound opcode demux (combinational)
  // ---------------------------------------------------------------------------
  logic rsp_is_poll, rsp_is_data;
  assign rsp_is_poll = rsp.valid && (rsp.data.opcode == OP_POLL);
  assign rsp_is_data = rsp.valid && (rsp.data.opcode == OP_DATA);

  // =====================================================================
  // TX engine
  // =====================================================================
  typedef enum logic [1:0] {
    TX_BOOT,     // resend OP_READY until the first poll arrives
    TX_WAIT,     // hold credit / message; start a chunk when both present
    TX_COLLECT,  // pull words from the core into the chunk buffer
    TX_SEND      // hand the assembled chunk to the serialiser
  } tx_state_t;

  tx_state_t            tx_state;
  logic                 have_credit;          // one outstanding poll
  logic                 in_msg;               // a core message is in flight
  logic [15:0]          bytes_left;           // remaining bytes of the message
  logic [7:0]           chunk_len;            // bytes in the current chunk
  logic [7:0]           byte_idx;             // bytes collected into chunk so far
  logic [PAY_BITS-1:0]  chunk_buf;            // assembled chunk payload
  logic [$clog2(READY_PERIOD)-1:0] ready_cnt; // boot READY retransmit timer

  logic req_fire;
  assign req_fire = req.valid && req.ready;

  // A message is available this cycle if one is latched or being presented now.
  logic        tx_msg_active;
  logic [15:0] tx_left;
  assign tx_msg_active = in_msg || core.wr_valid;
  assign tx_left       = in_msg ? bytes_left : core.wr_total_len;

  // wr_ready is asserted only while collecting a chunk.
  assign core.wr_ready = (tx_state == TX_COLLECT);

  // req (serialiser) is driven entirely by the TX engine.
  always_comb begin
    req.valid = 1'b0;
    req.data  = ctrl_pkt(OP_READY);
    case (tx_state)
      TX_BOOT: begin
        req.valid = (ready_cnt == 0);  // emit one READY each period
        req.data  = ctrl_pkt(OP_READY);
      end
      TX_SEND: begin
        req.valid       = 1'b1;
        req.data.opcode = OP_DATA;
        req.data.len    = chunk_len;
        req.data.payload = chunk_buf;
      end
      default: ;
    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      tx_state     <= TX_BOOT;
      have_credit  <= 1'b0;
      in_msg       <= 1'b0;
      bytes_left   <= '0;
      chunk_len    <= '0;
      byte_idx     <= '0;
      chunk_buf    <= '0;
      ready_cnt    <= '0;
      core.wr_done <= 1'b0;
    end else begin
      core.wr_done <= 1'b0;

      // Credit accrues from any poll, regardless of TX state. At most one is
      // ever outstanding (SDR polls once per drain, then waits).
      if (rsp_is_poll) have_credit <= 1'b1;

      // Latch a new message's total length when idle.
      if (!in_msg && core.wr_valid) begin
        in_msg     <= 1'b1;
        bytes_left <= core.wr_total_len;
      end

      case (tx_state)
        TX_BOOT:
          // Leave boot as soon as the first poll proves the SDR is up and
          // listening; that poll's credit carries into TX_WAIT.
          if (have_credit || rsp_is_poll) begin
            tx_state <= TX_WAIT;
          end else if (req_fire) begin
            ready_cnt <= ($clog2(READY_PERIOD))'(READY_PERIOD - 1);
          end else if (ready_cnt != 0) begin
            ready_cnt <= ready_cnt - 1;
          end

        TX_WAIT:
          if (have_credit && tx_msg_active && (tx_left != 0)) begin
            chunk_len <= (tx_left > 16'(MAX_PAYLOAD_BYTES))
                           ? 8'(MAX_PAYLOAD_BYTES) : 8'(tx_left);
            byte_idx  <= '0;
            tx_state  <= TX_COLLECT;
          end

        TX_COLLECT:
          if (core.wr_valid) begin  // wr_ready is high in this state
            chunk_buf[byte_idx*8 +: 32] <= core.wr_data;
            byte_idx <= byte_idx + 8'(DATA_BYTES);
            if (byte_idx + 8'(DATA_BYTES) >= chunk_len)
              tx_state <= TX_SEND;
          end

        TX_SEND:
          if (req_fire) begin
            have_credit <= 1'b0;
            bytes_left  <= bytes_left - 16'(chunk_len);
            if (bytes_left == 16'(chunk_len)) begin
              // Final chunk of this message.
              in_msg       <= 1'b0;
              core.wr_done <= 1'b1;
            end
            tx_state <= TX_WAIT;
          end

        default: tx_state <= TX_BOOT;
      endcase
    end
  end

  // =====================================================================
  // RX engine (fire-and-forget)
  // =====================================================================
  typedef enum logic {
    RX_IDLE,   // accept an OP_DATA packet (decoder never waits long)
    RX_EMIT    // walk payload to the core, one word per cycle
  } rx_state_t;

  rx_state_t           rx_state;
  logic [PAY_BITS-1:0] rx_payload;
  logic [7:0]          rx_len;
  logic [7:0]          rx_idx;

  // Accept POLL always (TX consumes it); accept DATA only when RX is idle.
  // Anything else is dropped. The decoder thus never stalls on RX data in
  // practice (UART byte rate << core clock, so RX_EMIT finishes first).
  always_comb begin
    rsp.ready = 1'b1;
    if (rsp_is_data) rsp.ready = (rx_state == RX_IDLE);
  end

  logic [7:0] rx_rem;
  assign rx_rem = rx_len - rx_idx;

  always_comb begin
    core.rd_valid = 1'b0;
    core.rd_data  = '0;
    core.rd_len   = '0;
    core.rd_last  = 1'b0;
    if (rx_state == RX_EMIT) begin
      core.rd_valid = 1'b1;
      core.rd_data  = rx_payload[rx_idx*8 +: 32];
      core.rd_len   = (rx_rem >= 8'(DATA_BYTES)) ? 8'(DATA_BYTES) : rx_rem;
      core.rd_last  = (rx_rem <= 8'(DATA_BYTES));
    end
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      rx_state   <= RX_IDLE;
      rx_payload <= '0;
      rx_len     <= '0;
      rx_idx     <= '0;
    end else begin
      case (rx_state)
        RX_IDLE:
          if (rsp_is_data && (rsp.data.len != 0)) begin
            rx_payload <= rsp.data.payload;
            rx_len     <= rsp.data.len;
            rx_idx     <= '0;
            rx_state   <= RX_EMIT;
          end

        RX_EMIT: begin
          // Advance regardless of rd_ready (fire-and-forget).
          rx_idx <= rx_idx + 8'(DATA_BYTES);
          if (rx_rem <= 8'(DATA_BYTES))
            rx_state <= RX_IDLE;
        end

        default: rx_state <= RX_IDLE;
      endcase
    end
  end

endmodule
