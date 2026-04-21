`default_nettype none

module top (
    input  wire i_clk,
    input  wire i_reset,
    input  wire i_uart_rx,
    output wire o_uart_tx
);

  // Core ↔ protocol engine interface
  core_sdr_if sdr_core_if ();

  // UART byte streams
  iter_if uart_tx_stream ();  // engine/serialiser → UART TX
  iter_if uart_rx_stream ();  // UART RX → decoder

  uart_top u_uart_top (
      .i_clk     (i_clk),
      .i_reset   (i_reset),
      .i_uart_rx (i_uart_rx),
      .o_uart_tx (o_uart_tx),
      .from_core (uart_tx_stream.slave),
      .to_core   (uart_rx_stream.master)
  );

  // Protocol packet streams
  sdr_ctrl_protocol_if #() protocol_tx ();  // engine → serialiser → UART
  sdr_ctrl_protocol_if #() protocol_rx ();  // UART → decoder → engine

  sdr_ctrl_protocol_byte_serialiser u_serialiser (
      .clk   (i_clk),
      .rst_n (~i_reset),
      .core  (protocol_tx.slave),
      .iter  (uart_tx_stream.master)
  );

  sdr_ctrl_protocol_byte_decoder u_decoder (
      .clk  (i_clk),
      .core (protocol_rx.master),
      .iter (uart_rx_stream.slave)
  );

  sdr_ctrl_protocol_engine u_engine (
      .clk   (i_clk),
      .rst_n (~i_reset),
      .core  (sdr_core_if.slave),
      .req   (protocol_tx.master),
      .rsp   (protocol_rx.slave)
  );

  // Simulation-only core stimulus — replace with real core
  test_core u_test_core (
      .clk   (i_clk),
      .rst_n (~i_reset),
      .core  (sdr_core_if.master)
  );

endmodule
