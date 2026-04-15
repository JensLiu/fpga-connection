// Deserialises an 8-bit byte stream (iter_if) into protocol_t packets.
//
// Frame format (on wire, in order):
//   byte 0       : opcode
//   byte 1       : payload length (0 = no payload)
//   bytes 2..N+1 : payload (N = len)
//
// Bytes are shifted into payload LSB-first (byte 0 of payload at bits [7:0]).

module sdr_ctrl_protocol_byte_decoder
  import pkg_sdr_ctrl_protocol::*;
(
    input logic clk,
    // Parsed packet output
    sdr_ctrl_protocol_if.master core,
    // Incoming byte stream
    iter_if.slave iter
);

  typedef enum logic [1:0] {
    S_OPCODE,    // waiting for opcode byte
    S_LEN,       // waiting for length byte
    S_PAYLOAD,   // accumulating payload bytes
    S_FINISHED   // packet ready, waiting for consumer
  } state_t;

  state_t      state,     state_n;
  protocol_t   prot_buf,  prot_buf_n;
  logic [7:0]  rem,       rem_n;        // bytes remaining in payload
  logic [7:0]  byte_idx,  byte_idx_n;  // next write position in payload

  always_comb begin
    // defaults
    state_n    = state;
    prot_buf_n = prot_buf;
    rem_n      = rem;
    byte_idx_n = byte_idx;
    iter.ready = 0;
    core.valid = 0;
    core.data  = prot_buf;

    case (state)
      S_OPCODE: begin
        if (iter.valid) begin
          iter.ready          = 1;
          prot_buf_n.opcode   = opcode_t'(iter.data);
          prot_buf_n.len      = '0;
          prot_buf_n.payload  = '0;
          byte_idx_n          = 0;
          state_n             = S_LEN;
        end
      end

      S_LEN: begin
        if (iter.valid) begin
          iter.ready      = 1;
          prot_buf_n.len  = iter.data;
          rem_n           = iter.data;
          state_n         = (iter.data == 0) ? S_FINISHED : S_PAYLOAD;
        end
      end

      S_PAYLOAD: begin
        if (iter.valid) begin
          iter.ready = 1;
          prot_buf_n.payload[byte_idx * 8 +: 8] = iter.data;
          byte_idx_n = byte_idx + 1;
          rem_n      = rem - 1;
          if (rem == 1)
            state_n = S_FINISHED;
        end
      end

      S_FINISHED: begin
        core.valid = 1;
        if (core.ready)
          state_n = S_OPCODE;
      end

      default: $fatal(1, "Unreachable sdr_ctrl_protocol_decoder state");
    endcase
  end

  always_ff @(posedge clk) begin
    state    <= state_n;
    prot_buf <= prot_buf_n;
    rem      <= rem_n;
    byte_idx <= byte_idx_n;
  end

endmodule
