`timescale 1ns / 1ps

// Abstraction layer between the core logic and the SDR protocol engine.
//
// The core sees a plain split read/write channel and has no knowledge of the
// underlying poll/credit flow control or chunking. See PROTOCOL_DESIGN.md §8.
//
// Write channel — TX, model A (core → engine → SDR OTA TX):
//   The core presents a whole message: it holds `wr_total_len` (total bytes,
//   may exceed BUFFER_SIZE) stable and streams `wr_data` words while wr_valid.
//   The engine pulls one word per `wr_ready` pulse — and `wr_ready` is asserted
//   ONLY while it is actively serialising a chunk (just after an SDR poll).
//   Between chunks `wr_ready` is low: that is the held ack. When the final
//   chunk has been handed to the serialiser, the engine strobes `wr_done` for
//   one cycle. The core must keep the next unconsumed word available (wr_valid
//   high) until all `wr_total_len` bytes have been consumed.
//
// Read channel — RX (engine → core, SDR OTA RX → core):
//   Fire-and-forget. The engine emits one word per cycle with rd_valid; the
//   core is expected to keep up (core clock >> UART byte rate). `rd_ready` is
//   advisory only — the engine never stalls on it. `rd_last` marks the final
//   word of each received packet so the core can group words without any
//   reassembly metadata on the wire.

interface core_sdr_if #(
    parameter int unsigned DATA_WIDTH      = 32,  // payload word width in bits
    parameter int unsigned LEN_WIDTH       = 8,   // per-word byte-count field
    parameter int unsigned TOTAL_LEN_WIDTH = 16   // whole-message byte count
) ();

  // Write channel (TX)
  logic                       wr_valid;
  logic                       wr_ready;     // pulses per word, only mid-chunk
  logic [DATA_WIDTH-1:0]      wr_data;
  logic [TOTAL_LEN_WIDTH-1:0] wr_total_len; // total message length in bytes
  logic                       wr_done;      // 1-cycle strobe: whole message sent

  // Read channel (RX)
  logic                  rd_valid;
  logic                  rd_ready;  // advisory; RX never stalls on it
  logic [DATA_WIDTH-1:0] rd_data;
  logic [LEN_WIDTH-1:0]  rd_len;    // valid bytes in rd_data
  logic                  rd_last;   // final word of the current RX packet

  // core is master: drives writes, consumes reads
  modport master (
      output wr_valid, input  wr_ready, output wr_data, output wr_total_len,
      input  wr_done,
      input  rd_valid, output rd_ready, input  rd_data, input  rd_len,
      input  rd_last
  );

  // engine is slave: consumes writes, drives reads
  modport slave (
      input  wr_valid, output wr_ready, input  wr_data, input  wr_total_len,
      output wr_done,
      output rd_valid, input  rd_ready, output rd_data, output rd_len,
      output rd_last
  );

endinterface
