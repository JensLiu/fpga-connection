module sdr_protocol_serialiser
  import pkg_sdr_ctrl_protocol::*;
#(
    parameter int unsigned ITER_ELEM_SIZE = 8
) (
    input logic clk,
    // protocol interface
    sdr_ctrl_protocol_if.slave core,
    // FIFO iterator interface
    iter_if.master iter
);

    localparam PROT_SIZE = $bits(pkg_sdr_ctrl_protocol::protocol_t);

    typedef enum {
        S_IDLE
    } state_t;

    state_t state, state_n;


endmodule
