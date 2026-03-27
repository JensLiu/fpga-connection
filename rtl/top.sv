`default_nettype none

module top (
    input  wire i_clk,
    input  wire i_reset,
    input  wire i_uart_rx,
    output wire o_uart_tx
);

    // Internal signals
    iter_if core_output ();
    iter_if core_input ();

    // Instantiate UART Top Module
    uart_top u_uart_top (
        .i_clk(i_clk),
        .i_reset(i_reset),
        .i_uart_rx(i_uart_rx),
        .o_uart_tx(o_uart_tx),
        .from_core(core_output.slave),
        .to_core(core_input.master)
    );

    repeat_source_iter #(
        .DATA_STR("Hello, World!\n")
    ) u_repeat_iter (
        .i_clk(i_clk),
        .iter(core_output.master)
    );

    display_sink_iter u_sink_iter (
        .i_clk(i_clk),
        .iter(core_input.slave)
    );

endmodule
