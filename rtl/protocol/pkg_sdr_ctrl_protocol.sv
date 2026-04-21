`timescale 1ns / 1ps
package pkg_sdr_ctrl_protocol;

  // Maximum payload bytes per packet. Control packets carry 0. DATA packets
  // carry up to this many bytes of samples.
  // Must be <= 255 because len is an 8-bit field on the wire.
  parameter int unsigned MAX_PAYLOAD_BYTES = 64;

  typedef enum logic [7:0] {
    OP_POLL    = 8'h01,  // FPGA → SDR : are you ready?
    OP_READY   = 8'h02,  // SDR  → FPGA: ready, enter IDLE
    OP_REQ_TX  = 8'h03,  // FPGA → SDR : switch to TX mode
    OP_ACK_TX  = 8'h04,  // SDR  → FPGA: TX mode entered
    OP_END_TX  = 8'h05,  // FPGA → SDR : end of TX burst, return to RX
    OP_ACK_RX  = 8'h06,  // SDR  → FPGA: RX mode resumed
    OP_DATA    = 8'h10,  // either      : sample payload (len > 0)
    OP_PAUSE   = 8'h20,  // either      : stop sending DATA (buffer high-water)
    OP_RESUME  = 8'h21   // either      : resume sending DATA (buffer low-water)
  } opcode_t;

  typedef struct packed {
    opcode_t                          opcode;
    logic [7:0]                       len;      // payload length in bytes
    logic [MAX_PAYLOAD_BYTES*8-1:0]   payload;  // valid for [len-1:0] bytes
  } protocol_t;

endpackage
