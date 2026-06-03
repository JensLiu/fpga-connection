#pragma once
#include <stdint.h>
#include <string.h>

// Must match pkg_sdr_ctrl_protocol.sv (BUFFER_SIZE).
#define BUFFER_SIZE       64
#define MAX_PAYLOAD_BYTES BUFFER_SIZE

typedef enum __attribute__((packed)) {
  OP_READY    = 0x02,  // FPGA → SDR : one-shot at boot, "engine up, you may poll"
  OP_POLL     = 0x01,  // SDR  → FPGA: TX buffer empty, one-buffer credit

  // Hub-SDR sub-protocol (invisible to FPGA)
  OP_REQ_SLOT = 0x08,  // SDR  → Hub : TX buffer non-empty, request slot
  OP_GRANT    = 0x09,  // Hub  → SDR : slot granted, drain buffer
  OP_DONE     = 0x0A,  // SDR  → Hub : buffer drained, slot released

  OP_DATA     = 0x10,  // bidirectional: sample payload (len > 0)
} opcode_t;

// Wire frame: [ opcode (1B) | len (1B) | payload (len B) ]
typedef struct {
  opcode_t opcode;
  uint8_t len;
  uint8_t payload[MAX_PAYLOAD_BYTES];
} packet_t;

static inline packet_t make_ctrl(opcode_t op) {
  packet_t p;
  memset(&p, 0, sizeof(p));
  p.opcode = op;
  p.len = 0;
  return p;
}

static inline const char *opcode_name(opcode_t op) {
  switch (op) {
  case OP_READY:    return "READY";
  case OP_POLL:     return "POLL";
  case OP_REQ_SLOT: return "REQ_SLOT";
  case OP_GRANT:    return "GRANT";
  case OP_DONE:     return "DONE";
  case OP_DATA:     return "DATA";
  }
  return "?";
}
