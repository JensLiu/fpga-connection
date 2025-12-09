`default_nettype none

module top (
    input  wire i_clk,
    input  wire i_reset,
    input  wire i_uart_rx,
    output wire o_uart_tx
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

    // Write State Machine
    typedef enum logic [1:0] {
        ST_TX_IDLE,
        ST_TX_WRITE,
        ST_TX_RESP
    } tx_state_t;

    tx_state_t tx_state;
    localparam TX_DELAY = 1000000;
    localparam MAX_DATA_LEN = 12;
    logic [7:0] tx_data[MAX_DATA_LEN] = '{"H", "e", "l", "l", "o", " ", "W", "o", "r", "l", "d", "\n"};
    logic [3:0] tx_index;

    logic [31:0] delay_cnt;

    always @(posedge i_clk) begin
        if (i_reset) begin
            tx_state <= ST_TX_IDLE;
            s_axi_awvalid <= 1'b0;
            s_axi_awaddr <= 4'h0;
            s_axi_wvalid <= 1'b0;
            s_axi_wdata <= 32'h0;
            s_axi_wstrb <= 4'h0;
            s_axi_bready <= 1'b0;
            tx_index <= 0;
            delay_cnt <= 0;
        end else begin
            case (tx_state)
                ST_TX_IDLE: begin
                    if (delay_cnt < TX_DELAY) begin
                        delay_cnt <= delay_cnt + 1;
                    end else if (tx_index < MAX_DATA_LEN) begin
                        s_axi_awvalid <= 1'b1;
                        s_axi_awaddr <= 4'hC;  // UART_TXREG
                        s_axi_wvalid <= 1'b1;
                        s_axi_wdata <= {24'h0, tx_data[tx_index]};
                        s_axi_wstrb <= 4'h1;
                        s_axi_bready <= 1'b1;
                        tx_state <= ST_TX_WRITE;
                    end
                    // Else: Do nothing, stay in IDLE (stop sending)
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
                        tx_index <= tx_index + 1;
                        delay_cnt <= 0;
                        tx_state <= ST_TX_IDLE;
                    end
                end
                default: tx_state <= ST_TX_IDLE;
            endcase
        end
        if (tx_index == MAX_DATA_LEN) begin
            tx_index <= 0;
        end
    end

    // State machine for reading
    typedef enum logic [1:0] {
        ST_IDLE,
        ST_READ_ADDR,
        ST_READ_DATA
    } rx_state_t;

    rx_state_t state;

    always @(posedge i_clk) begin
        if (i_reset) begin
            state <= ST_IDLE;
            s_axi_arvalid <= 1'b0;
            s_axi_araddr <= 4'h0;
            s_axi_rready <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    if (uart_rx_int) begin  // Data available
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
                            $write("%c", s_axi_rdata[7:0]);
                            $fflush();
                        end
                        state <= ST_IDLE;
                    end
                end
                default: state <= ST_IDLE;
            endcase
        end
    end



endmodule
