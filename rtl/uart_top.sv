`default_nettype none

module uart_top (
    input wire i_clk,
    input wire i_reset,
    input wire i_uart_rx,
    output wire o_uart_tx,
    iter_if.master to_core,
    iter_if.slave from_core
);

    // AXI Lite Interface
    /* verilator lint_off UNUSEDSIGNAL */
    logic        s_axi_awvalid;
    wire         s_axi_awready;
    logic [ 3:0] s_axi_awaddr;
    logic [ 2:0] s_axi_awprot;
    logic        s_axi_wvalid;
    wire         s_axi_wready;
    logic [31:0] s_axi_wdata;
    logic [ 3:0] s_axi_wstrb;
    wire         s_axi_bvalid;
    logic        s_axi_bready;
    wire  [ 1:0] s_axi_bresp;
    logic        s_axi_arvalid;
    wire         s_axi_arready;
    logic [ 3:0] s_axi_araddr;
    logic [ 2:0] s_axi_arprot;
    wire         s_axi_rvalid;
    logic        s_axi_rready;
    wire  [31:0] s_axi_rdata;
    wire  [ 1:0] s_axi_rresp;
    /* verilator lint_on UNUSEDSIGNAL */

    // Setup for 115200 baud at 100MHz (868)
    // Calculate as: Clock_Freq / Baud_Rate
    localparam logic [30:0] SetupVal = 31'd868;

    // UART Interrupts
    /* verilator lint_off UNUSEDSIGNAL */
    wire uart_rx_int;
    wire uart_tx_int;
    wire uart_rxfifo_int;
    wire uart_txfifo_int;
    /* verilator lint_on UNUSEDSIGNAL */

    /* verilator lint_off PINMISSING */
    /* verilator lint_off PINCONNECTEMPTY */
    axiluart #(
        .INITIAL_SETUP(SetupVal),
        .HARDWARE_FLOW_CONTROL_PRESENT(1'b1)
    ) u_axiluart (
        .S_AXI_ACLK(i_clk),
        .S_AXI_ARESETN(!i_reset),  // AXI uses active low reset

        // AXI Lite Interface
        .S_AXI_AWVALID(s_axi_awvalid),
        .S_AXI_AWREADY(s_axi_awready),
        .S_AXI_AWADDR (s_axi_awaddr),
        .S_AXI_AWPROT (s_axi_awprot),
        .S_AXI_WVALID (s_axi_wvalid),
        .S_AXI_WREADY (s_axi_wready),
        .S_AXI_WDATA  (s_axi_wdata),
        .S_AXI_WSTRB  (s_axi_wstrb),
        .S_AXI_BVALID (s_axi_bvalid),
        .S_AXI_BREADY (s_axi_bready),
        .S_AXI_BRESP  (s_axi_bresp),
        .S_AXI_ARVALID(s_axi_arvalid),
        .S_AXI_ARREADY(s_axi_arready),
        .S_AXI_ARADDR (s_axi_araddr),
        .S_AXI_ARPROT (s_axi_arprot),
        .S_AXI_RVALID (s_axi_rvalid),
        .S_AXI_RREADY (s_axi_rready),
        .S_AXI_RDATA  (s_axi_rdata),
        .S_AXI_RRESP  (s_axi_rresp),

        // UART Signals
        .i_uart_rx(i_uart_rx),
        .o_uart_tx(o_uart_tx),
        .i_cts_n  (1'b0),
        .o_rts_n  (),

        // Interrupts
        .o_uart_rx_int(uart_rx_int),
        .o_uart_tx_int(uart_tx_int),
        .o_uart_rxfifo_int(uart_rxfifo_int),
        .o_uart_txfifo_int(uart_txfifo_int)
    );
    /* verilator lint_on PINCONNECTEMPTY */
    /* verilator lint_on PINMISSING */

    assign s_axi_awprot = 3'h0;
    assign s_axi_arprot = 3'h0;

    // TX State Machine - receives data from from_core handshake and sends via UART (byte by byte)
    typedef enum logic [1:0] {
        ST_TX_IDLE,
        ST_TX_WRITE,
        ST_TX_RESP
    } tx_state_t;

    tx_state_t tx_state;

    always @(posedge i_clk) begin
        if (i_reset) begin
            tx_state <= ST_TX_IDLE;
            s_axi_awvalid <= 1'b0;
            s_axi_awaddr <= 4'h0;
            s_axi_wvalid <= 1'b0;
            s_axi_wdata <= 32'h0;
            s_axi_wstrb <= 4'h0;
            s_axi_bready <= 1'b0;
            from_core.ready <= 1'b0;
        end else begin
            case (tx_state)
                ST_TX_IDLE: begin
                    // Assert ready when UART TX FIFO has space (uart_tx_int = !fifo_full)
                    from_core.ready <= uart_tx_int;

                    if (from_core.valid && from_core.ready) begin
                        s_axi_awvalid <= 1'b1;
                        s_axi_awaddr <= 4'hC;  // UART_TXREG
                        s_axi_wvalid <= 1'b1;
                        s_axi_wdata <= {24'h0, from_core.data[7:0]};
                        s_axi_wstrb <= 4'h1;
                        s_axi_bready <= 1'b1;
                        from_core.ready <= 1'b0;
                        tx_state <= ST_TX_WRITE;
                    end
                end

                ST_TX_WRITE: begin
                    if (s_axi_awready && s_axi_wready) begin
                        s_axi_awvalid <= 1'b0;
                        s_axi_wvalid <= 1'b0;
                        s_axi_wstrb <= 4'h0;
                        tx_state <= ST_TX_RESP;
                    end
                end

                ST_TX_RESP: begin
                    if (s_axi_bvalid) begin
                        s_axi_bready <= 1'b0;
                        tx_state <= ST_TX_IDLE;
                    end
                end
                default: tx_state <= ST_TX_IDLE;
            endcase
        end
    end

    // RX State Machine - reads from UART (byte by byte) and sends via to_core handshake
    typedef enum logic [2:0] {
        ST_IDLE,
        ST_READ_ADDR,
        ST_READ_DATA,
        ST_OUTPUT
    } rx_state_t;

    rx_state_t state;
    logic [31:0] rx_data_accum;
    logic [4:0] rx_byte_count;
    logic [4:0] rx_bytes_needed;
    logic [4:0] rx_output_idx;

    always @(posedge i_clk) begin
        if (i_reset) begin
            state <= ST_IDLE;
            s_axi_arvalid <= 1'b0;
            s_axi_araddr <= 4'h0;
            s_axi_rready <= 1'b0;
            to_core.valid <= 1'b0;
            to_core.data <= 8'h0;
            rx_byte_count <= 5'h0;
            rx_bytes_needed <= 5'd1;  // Default 1 byte, adjust for wider data
            rx_data_accum <= 32'h0;
            rx_output_idx <= 5'h0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (to_core.valid && to_core.ready) begin
                        // Data accepted by downstream
                        to_core.valid <= 1'b0;
                    end

                    if (uart_rx_int && !to_core.valid) begin  // Data available and not transmitting
                        s_axi_arvalid <= 1'b1;
                        s_axi_araddr <= 4'h8;  // UART_RXREG
                        state <= ST_READ_ADDR;
                    end
                end

                ST_READ_ADDR: begin
                    if (s_axi_arready) begin
                        s_axi_arvalid <= 1'b0;
                        s_axi_rready <= 1'b1;
                        state <= ST_READ_DATA;
                    end
                end

                ST_READ_DATA: begin
                    if (s_axi_rvalid) begin
                        s_axi_rready <= 1'b0;
                        // Check if data is valid (bit 8 is 0 for valid data)
                        if (s_axi_rdata[8] == 1'b0) begin
                            rx_data_accum[rx_byte_count*8+:8] <= s_axi_rdata[7:0];
                            rx_byte_count <= rx_byte_count + 1;

                            // Check if we've accumulated enough bytes
                            if (rx_byte_count + 1 >= rx_bytes_needed) begin
                                rx_output_idx <= 5'h0;
                                state <= ST_OUTPUT;
                            end else begin
                                state <= ST_IDLE;
                            end
                        end else begin
                            state <= ST_IDLE;
                        end
                    end
                end

                ST_OUTPUT: begin
                    if (!to_core.valid || to_core.ready) begin
                        // Output next byte
                        to_core.data  <= rx_data_accum[rx_output_idx*8+:8];
                        to_core.valid <= 1'b1;

                        // Check if more bytes to output
                        if (rx_output_idx + 1 < rx_byte_count) begin
                            rx_output_idx <= rx_output_idx + 1;
                        end else begin
                            // All bytes sent, return to IDLE
                            rx_byte_count <= 5'h0;
                            rx_data_accum <= 32'h0;
                            state <= ST_IDLE;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end



endmodule
