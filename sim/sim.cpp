#include "Vtop.h"
#include "uartsim.h"
#include <fcntl.h>
#include <iostream>
#include <memory>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>
#include <verilated.h>

int main(int argc, char **argv) {
  // Line-buffer stdout so $display output is flushed immediately even when
  // the process is redirected to a file and later killed.
  setvbuf(stdout, nullptr, _IOLBF, 0);

  Verilated::commandArgs(argc, argv);
  auto top = std::make_unique<Vtop>();

  int port = (argc > 1) ? std::atoi(argv[1]) : 12345;
  std::cout << "[FPGA sim] port=" << port
            << "  pass +fpga_id=N to tag output\n";
  auto uart = std::make_unique<UARTSIM>(port);
  // Configure UART simulator to match the RTL (868 divisor for 115200 baud @
  // 100MHz)
  uart->setup(868);

  // Initialize inputs
  top->i_clk = 0;
  top->i_reset = 1;
  top->i_uart_rx = 1; // Idle high

  uint32_t read_data = 0;

  // Simulation loop
  while (!Verilated::gotFinish()) {
    // Toggle clock
    top->i_clk = !top->i_clk;

    // Release reset after a few cycles
    if (Verilated::time() > 100) {
      top->i_reset = 0;
    }

    // Evaluate model
    top->eval();

    // On positive edge, update UART
    if (top->i_clk) {
      // UARTSIM operator() takes the TX value to transmit
      top->i_uart_rx = (*uart)(top->o_uart_tx);
    }

    Verilated::timeInc(1);
  }
  return 0;
}
