.PHONY: all clean run

VERILATOR = verilator

RTL_DIR     = ../rtl
PROTO_DIR   = $(RTL_DIR)/protocol
LIB_RTL_DIR = ../libs/wbuart32/rtl
LIB_CPP_DIR = ../libs/wbuart32/cpp

VERILOG_SOURCES = \
  $(PROTO_DIR)/pkg_sdr_ctrl_protocol.sv \
  $(PROTO_DIR)/core_sdr_if.sv \
  $(PROTO_DIR)/iter_if.sv \
  $(PROTO_DIR)/sdr_ctrl_protocol_if.sv \
  $(PROTO_DIR)/sdr_ctrl_protocol_byte_decoder.sv \
  $(PROTO_DIR)/sdr_ctrl_protocol_byte_serialiser.sv \
  $(PROTO_DIR)/sdr_ctrl_protocol_engine.sv \
  $(RTL_DIR)/uart_top.sv \
  $(RTL_DIR)/test_core.sv \
  $(RTL_DIR)/top.sv \
  $(LIB_RTL_DIR)/axiluart.v \
  $(LIB_RTL_DIR)/rxuart.v \
  $(LIB_RTL_DIR)/txuart.v \
  $(LIB_RTL_DIR)/ufifo.v \
  $(LIB_RTL_DIR)/skidbuffer.v

CPP_SOURCES = sim.cpp $(LIB_CPP_DIR)/uartsim.cpp

VERILATOR_FLAGS  = --cc --exe --build -j 0 --trace
VERILATOR_FLAGS += --top-module top
VERILATOR_FLAGS += -Wall -Wno-UNUSEDSIGNAL -Wno-UNUSEDPARAM -Wno-SYNCASYNCNET -Wno-UNOPTFLAT
VERILATOR_FLAGS += -I$(LIB_RTL_DIR) -I$(RTL_DIR) -I$(PROTO_DIR)
VERILATOR_FLAGS += -CFLAGS "-I$(abspath $(LIB_CPP_DIR))"

OBJ_DIR = obj_dir
EXE     = $(OBJ_DIR)/Vtop

all: $(EXE)

$(EXE): $(VERILOG_SOURCES) $(CPP_SOURCES)
	$(VERILATOR) $(VERILATOR_FLAGS) $(VERILOG_SOURCES) $(CPP_SOURCES)

run: $(EXE)
	./$(EXE)

clean:
	rm -rf $(OBJ_DIR)
