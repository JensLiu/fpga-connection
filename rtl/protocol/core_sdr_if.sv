`timescale 1ns / 1ps

// Abstraction layer between the core logic and the SDR protocol engine.
//
// The core sees a plain split read/write channel and has no knowledge of
// the underlying SDR TX/RX mode switching.
//
// Write channel (core → engine → SDR OTA TX):
//   core asserts wr_valid + wr_data + wr_len.
//   engine asserts wr_ready when it has consumed the word.
//
// Read channel (engine → core, SDR OTA RX → core):
//   engine asserts rd_valid + rd_data + rd_len.
//   core asserts rd_ready when it has consumed the word.

interface core_sdr_if #(
    parameter int unsigned DATA_WIDTH = 32,  // payload word width in bits
    parameter int unsigned LEN_WIDTH  = 8    // byte-count field width (max DATA_WIDTH/8)
) ();

  // Write channel
  logic                  wr_valid;
  logic                  wr_ready;
  logic [DATA_WIDTH-1:0] wr_data;
  logic [LEN_WIDTH-1:0]  wr_len;   // valid bytes in wr_data

  // Read channel
  logic                  rd_valid;
  logic                  rd_ready;
  logic [DATA_WIDTH-1:0] rd_data;
  logic [LEN_WIDTH-1:0]  rd_len;   // valid bytes in rd_data

  // core is master: drives writes, consumes reads
  modport master (
      output wr_valid, input  wr_ready, output wr_data, output wr_len,
      input  rd_valid, output rd_ready, input  rd_data, input  rd_len
  );

  // engine is slave: consumes writes, drives reads
  modport slave (
      input  wr_valid, output wr_ready, input  wr_data, input  wr_len,
      output rd_valid, input  rd_ready, output rd_data, output rd_len
  );

endinterface
