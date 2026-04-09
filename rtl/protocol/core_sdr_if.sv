`timescale 1ns / 1ps

interface core_sdr_if #(
    parameter int unsigned DATA_WIDTH = 32
) ();
  localparam int unsigned DATA_SIZE_BITS = $clog2(DATA_WIDTH);
  // currently the interface is synchronous
  logic                      valid;  // < We should serve the pipeline request
  logic                      ready;  // < The pipeline request is served
  logic                      is_read;  // < 0: write through SDR, 1: read from SDR
  logic [DATA_SIZE_BITS-1:0] rd_data_size;  // < write data size
  logic [DATA_SIZE_BITS-1:0] wr_data_size;  // < read data size
  logic [    DATA_WIDTH-1:0] wr_data;  // < data to write
  logic [    DATA_WIDTH-1:0] rd_data;  // < data to read modport master(

  modport master(
      input valid,
      output ready,
      input is_read,
      output wr_data_size,
      input rd_data_size,
      input wr_data,
      output rd_data
  );

  modport slave(
      input valid,
      output ready,
      input is_read,
      input wr_data_size,
      output rd_data_size,
      input wr_data,
      output rd_data
  );

endinterface

