module display_sink_iter (
    input wire i_clk,
    iter_if.slave iter
);
    always_ff @(posedge i_clk) begin
        if (iter.valid) begin
            $write("%c", iter.data);
        end
        // Always ready to receive data
        iter.ready <= 1'b1;
    end
endmodule
