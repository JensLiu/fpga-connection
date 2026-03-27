module repeat_source_iter #(
    parameter string DATA_STR = "Hello, World!\n"
) (
    input wire i_clk,
    iter_if.master iter
);
    parameter int unsigned DATA_LEN = DATA_STR.len();
    localparam int unsigned COUNTER_WIDTH = (DATA_LEN > 1) ? $clog2(DATA_LEN) : 1;
    localparam logic [COUNTER_WIDTH-1:0] LAST_IDX = COUNTER_WIDTH'(DATA_LEN - 1);
    logic [COUNTER_WIDTH-1:0] counter;

    logic [DATA_LEN*8-1:0] data_buffer;
    for (genvar i = 0; i < DATA_LEN; i++) begin: g_copy
        assign data_buffer[i*8 +: 8] = DATA_STR.getc(i);
    end

    always_ff @(posedge i_clk) begin
        // Always provide valid data
        iter.valid <= 1'b1;
        iter.data  <= data_buffer[counter*8 +: 8];

        // Advance counter on ready (handshake complete)
        if (iter.ready) begin
            counter <= counter + 1;
            if (counter == LAST_IDX) begin
                counter <= '0;
            end
        end
    end

endmodule
