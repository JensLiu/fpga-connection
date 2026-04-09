interface iter_if #(
    parameter int unsigned ITER_ELEM_SIZE = 8
) ();
  logic valid;
  logic [ITER_ELEM_SIZE-1:0] data;
  logic ready;

    modport master(
        output valid,
        output data,
        input ready
    );

    modport slave(
        input valid,
        input data,
        output ready
    );

endinterface
