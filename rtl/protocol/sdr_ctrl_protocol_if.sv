interface sdr_ctrl_protocol_if
  import pkg_sdr_ctrl_protocol::*;
#(
    parameter int unsigned PAYLOAD_WORD_SIZE = 2
) ();

  logic valid;
  logic ready;
  pkg_sdr_ctrl_protocol::protocol_t data;

  modport master(
      output valid,
      input ready,
      output data
  );

  modport slave(
      input valid,
      output ready,
      input data
  );

endinterface
