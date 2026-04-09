package pkg_sdr_ctrl_protocol;
  parameter int unsigned PAYLOAD_SIZE = 64;
  parameter int unsigned PAYLOAD_SIZE_BITS = $clog2(PAYLOAD_SIZE);
  parameter int unsigned PAYLOAD_SIZE_START_BIT = 5;
  parameter int unsigned PAYLOAD_DATA_START_BIT = PAYLOAD_SIZE_START_BIT + PAYLOAD_SIZE_BITS;
  parameter int unsigned PAYLOAD_DATA_WIDTH = PAYLOAD_SIZE_BITS + PAYLOAD_SIZE;
  parameter int unsigned CONTROL_PAYLOAD_PADDING_WIDTH = PAYLOAD_DATA_WIDTH - 2; // < NOTE: should be updated to reflect fields in controlflow
  typedef struct {
    // logic [UUID_BITS-1:0] uuid;
    logic is_control;
    logic is_ack;
    logic sop;
    logic eop;
    union packed {
      struct packed {
        logic [PAYLOAD_SIZE_BITS-1:0] payload_size;
        logic [PAYLOAD_SIZE-1:0] payload_data;
      } data;
      struct packed {
        logic sdr_tx;
        logic sdr_rx;
        // logic [?-1:0] sdr_tx_buf_rem;
        logic [CONTROL_PAYLOAD_PADDING_WIDTH-1:0] padding;
      } control;
    } payload;
  } protocol_t;
endpackage
