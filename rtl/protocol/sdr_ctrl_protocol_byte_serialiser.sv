// Serialises a protocol_t packet into an 8-bit byte stream (iter_if).
//
// Frame format emitted (matches parser expectation):
//   byte 0       : opcode
//   byte 1       : payload length (0 = no payload)
//   bytes 2..N+1 : payload bytes, LSB-first (byte 0 at bits [7:0])
//
// Accepts one packet per burst: core.ready is asserted for exactly one cycle
// when the packet is latched. The next packet can be presented once the
// current one is fully serialised (state returns to S_IDLE).

module sdr_ctrl_protocol_byte_serialiser
  import pkg_sdr_ctrl_protocol::*;
(
    input logic clk,
    input logic rst_n,
    // Packet input
    sdr_ctrl_protocol_if.slave  core,
    // Byte stream output
    iter_if.master               iter
);

  localparam int unsigned IterElemSize = 8;

  typedef enum logic [1:0] {
    S_IDLE,     // waiting for a packet
    S_OPCODE,   // emitting opcode byte
    S_LEN,      // emitting length byte
    S_PAYLOAD   // emitting payload bytes
  } state_t;

  state_t    state,    state_n;
  protocol_t pkt,      pkt_n;
  logic [7:0] byte_idx, byte_idx_n;
  logic [7:0] rem,      rem_n;

  logic iter_fire;
  assign iter_fire = iter.valid && iter.ready;

  always_comb begin
    state_n    = state;
    pkt_n      = pkt;
    byte_idx_n = byte_idx;
    rem_n      = rem;
    core.ready = 0;
    iter.valid = 0;
    iter.data  = '0;

    case (state)

      S_IDLE: begin
        if (core.valid) begin
          core.ready = 1;   // latch and consume in one cycle
          pkt_n      = core.data;
          state_n    = S_OPCODE;
        end
      end

      S_OPCODE: begin
        iter.valid = 1;
        iter.data  = 8'(pkt.opcode);
        if (iter_fire)
          state_n = S_LEN;
      end

      S_LEN: begin
        iter.valid = 1;
        iter.data  = pkt.len;
        if (iter_fire) begin
          byte_idx_n = 0;
          rem_n      = pkt.len;
          state_n    = (pkt.len == 0) ? S_IDLE : S_PAYLOAD;
        end
      end

      S_PAYLOAD: begin
        iter.valid = 1;
        iter.data  = pkt.payload[byte_idx * IterElemSize +: IterElemSize];
        if (iter_fire) begin
          byte_idx_n = byte_idx + 1;
          rem_n      = rem - 1;
          if (rem == 1)
            state_n = S_IDLE;
        end
      end

      default: $fatal(1, "Unreachable sdr_ctrl_protocol_serialiser state");

    endcase
  end

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state    <= S_IDLE;
      pkt      <= '0;
      byte_idx <= '0;
      rem      <= '0;
    end else begin
      state    <= state_n;
      pkt      <= pkt_n;
      byte_idx <= byte_idx_n;
      rem      <= rem_n;
    end
  end

endmodule
