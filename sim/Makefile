.PHONY: all clean run

# Tools
VERILATOR = verilator

# Directories
RTL_DIR = ../rtl
LIB_RTL_DIR = ../libs/wbuart32/rtl
LIB_CPP_DIR = ../libs/wbuart32/cpp

# Files
# Explicitly list Verilog sources. 
# top.sv instantiates rxuart, so we need rxuart.v
VERILOG_SOURCES = $(RTL_DIR)/top.sv \
	$(RTL_DIR)/iter_if.sv \
	$(RTL_DIR)/uart_top.sv \
	$(RTL_DIR)/repeat_source_iter.sv \
	$(RTL_DIR)/display_sink_iter.sv \
	$(LIB_RTL_DIR)/axiluart.v \
	$(LIB_RTL_DIR)/rxuart.v \
	$(LIB_RTL_DIR)/txuart.v \
	$(LIB_RTL_DIR)/ufifo.v \
	$(LIB_RTL_DIR)/skidbuffer.v

# C++ sources for the simulation harness and the UART model
CPP_SOURCES = sim.cpp $(LIB_CPP_DIR)/uartsim.cpp

# Verilator Flags
# --cc: Create C++ output
# --exe: Link with executable
# --build: Build the executable automatically
# --trace: Enable waveform tracing (optional but good to have)
# -j 0: Use all cores
# -Wall: Enable warnings
VERILATOR_FLAGS = --cc --exe --build -j 0 -Wall --trace
VERILATOR_FLAGS += --top-module top
VERILATOR_FLAGS += -Wno-UNUSEDSIGNAL

# Include paths for Verilog (if needed)
VERILATOR_FLAGS += -I$(LIB_RTL_DIR)
VERILATOR_FLAGS += -I$(RTL_DIR)

# Include paths for C++ compiler (to find uartsim.h)
# We pass this via -CFLAGS to the underlying C++ compiler
VERILATOR_FLAGS += -CFLAGS "-I$(abspath $(LIB_CPP_DIR))"

# Output executable will be in obj_dir/Vtop
OBJ_DIR = obj_dir
EXE = $(OBJ_DIR)/Vtop

all: $(EXE)

$(EXE): $(VERILOG_SOURCES) $(CPP_SOURCES)
	$(VERILATOR) $(VERILATOR_FLAGS) $(VERILOG_SOURCES) $(CPP_SOURCES)

run: $(EXE)
	./$(EXE)

clean:
	rm -rf $(OBJ_DIR)
