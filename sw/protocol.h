#pragma once
#include <stdint.h>
#include <string.h>

// Must match pkg_sdr_ctrl_protocol.sv
#define MAX_PAYLOAD_BYTES 64

typedef enum __attribute__((packed)) {
  OP_POLL = 0x01,   // FPGA → SDR : are you ready?
  OP_READY = 0x02,  // SDR  → FPGA: ready, enter IDLE
  OP_REQ_TX = 0x03, // FPGA → SDR : switch to TX mode
  OP_ACK_TX = 0x04, // SDR  → FPGA: TX mode entered
  OP_END_TX = 0x05, // FPGA → SDR : end of TX burst, return to RX
  OP_ACK_RX = 0x06, // SDR  → FPGA: RX mode resumed
  OP_DATA = 0x10,   // either      : sample payload (len > 0)
  OP_PAUSE = 0x20,  // either      : stop sending DATA (buffer high-water)
  OP_RESUME = 0x21, // either      : resume sending DATA (buffer low-water)
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
  case OP_POLL:
    return "POLL";
  case OP_READY:
    return "READY";
  case OP_REQ_TX:
    return "REQ_TX";
  case OP_ACK_TX:
    return "ACK_TX";
  case OP_END_TX:
    return "END_TX";
  case OP_ACK_RX:
    return "ACK_RX";
  case OP_DATA:
    return "DATA";
  case OP_PAUSE:
    return "PAUSE";
  case OP_RESUME:
    return "RESUME";
  }
  return "?";
}