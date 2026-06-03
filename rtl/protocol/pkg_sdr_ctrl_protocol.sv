`timescale 1ns / 1ps
package pkg_sdr_ctrl_protocol;

  // SDR TX buffer size in bytes. The SDR holds at most one buffer-fill at a
  // time; the FPGA never sends more than this per chunk. See PROTOCOL_DESIGN.md.
  //
  //   * Must be <= 255 because `len` is an 8-bit field on the wire.
  //   * Must be a multiple of DATA_WIDTH/8 (4) so chunk boundaries land on core
  //     word boundaries (only the final word of a whole message may be partial).
  parameter int unsigned BUFFER_SIZE = 64;

  // Max payload bytes carried in one frame == one buffer-fill.
  parameter int unsigned MAX_PAYLOAD_BYTES = BUFFER_SIZE;

  typedef enum logic [7:0] {
    OP_READY = 8'h02,  // FPGA → SDR : one-shot at boot, "engine up, you may poll"
    OP_POLL  = 8'h01,  // SDR  → FPGA: TX buffer empty, one-buffer credit (len = 0)
    OP_DATA  = 8'h10   // bidirectional: sample payload (len > 0)
  } opcode_t;

  typedef struct packed {
    opcode_t                          opcode;
    logic [7:0]                       len;      // payload length in bytes
    logic [MAX_PAYLOAD_BYTES*8-1:0]   payload;  // valid for [len-1:0] bytes
  } protocol_t;

endpackage
