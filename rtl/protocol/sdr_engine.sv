`timescale 1ns / 1ps

`include "core_sdr_if.sv"

module sdr_protocol_engine
  import pkg_sdr_ctrl_protocol::*;
#(
    parameter int unsigned PAYLOAD_WORD_SIZE = 2
) (
    logic clk,
    core_sdr_if.slave core,
    sdr_ctrl_protocol_if.master req,
    sdr_ctrl_protocol_if.slave rsp
);

  typedef enum {
    S_SDR_PENDING,          // < The SDR is not ready
    S_IDLE,                 // < The SDR is ready, no in-flight core request
    S_TX_IDLE,              // < The SDR is in TX mode, no core request
    S_RX_IDLE,              // < The SDR is in RX mode, no core request
    S_TX_STREAMING,         // < SDR transmitting
    S_TX_STREAMING_PAUSED,  // < SDR paused, NOT IMPLEMENTED
    S_RX_STREAMING,         // < SDR receiving
    S_RX_STREAMING_PAUSED   // SDR paused, NOT IMPLEMENTED
  } state_t;

  state_t state, state_n;

  // TODO: support multi-packet SOP and EOP
  logic sdr_is_ctl = rsp.valid && rsp.data.is_control;
  logic sdr_is_data = rsp.valid && ~rsp.data.is_control;
  logic sdr_ctl_ready = sdr_is_ctl && rsp.data.payload.control.sdr_ready;
  logic sdr_ctl_stop = sdr_is_ctl && ~rsp.data.payload.control.sdr_ready;
  logic sdr_ctl_tx_ack = sdr_is_ctl && rsp.data.is_ack && rsp.data.sdr_tx;
  logic sdr_ctl_rx_ack = sdr_is_ctl && rsp.data.is_ack && ~rsp.data.sdr_tx;
  logic sdr_data_ack = sdr_is_data && rsp.data.is_ack;
  // $assert(~req.valid || req.dasta.sop && req.data.eop);
  // $assert(~rsp.valid || rsp.data.sop && rsp.data.eop);

  // TODO: support different core and sdr data sizes
  logic core_is_read = core.valid && core.is_read;
  logic core_is_write = core.valid && ~core.is_read;

  always_comb begin
    case (state)
      S_SDR_PENDING: begin
        if (sdr_ctl_ready) begin
          state_n = S_IDLE;
        end
      end
      S_IDLE: begin
        if (core_is_read) begin
          // Send SDR TX control request
          req.valid = 1;
          req.data.is_control = 1;
          req.data.payload.control.sdr_tx = 1;
          if (sdr_ctl_tx_ack) begin
            // $assert(req.ready);  // < Blocking interface, send before receiving
            state_n = S_TX_IDLE;
          end
        end else if (core_is_write) begin
          // send SDR RX control request
          req.valid = 1;
          req.data.is_control = 1;
          req.data.payload.control.sdr_rx = 1;
          if (sdr_ctl_rx_ack) begin
            // $assert(req.ready);
            state_n = S_RX_IDLE;
          end
        end
      end
      S_RX_IDLE: begin
        if (core_is_read) begin
          state_n = S_RX_STREAMING;
        end else if (core_is_write) begin
          state_n = S_IDLE;  // TODO: optimisation: send TX request here
        end
      end
      S_TX_IDLE: begin
        if (core_is_write) begin
          state_n = S_TX_STREAMING;
        end else if (core_is_read) begin
          state_n = S_IDLE;
        end
      end
      S_RX_STREAMING: begin
        // TODO: if we want to keep receiving, we need a way to tell the 
        core.rd_data_size = rsp.data.payload.data.payload_size;
        core.rd_data = rsp.data.payload.data.payload_data;
        if (~core_is_read) begin
          state_n = (core_is_write) ? S_IDLE : S_RX_IDLE;
        end
      end
      S_TX_STREAMING: begin
        req.valid = 1;
        req.data.is_control = 0;
        req.data.data.payload_size = core.wr_data_size;
        req.data.data.payload = core.wr_data;
        if (sdr_data_ack) begin
          core.ready = 1;
          if (~core_is_write) begin
            state_n = (core_is_read) ? S_IDLE : S_TX_IDLE;
          end
        end
      end
      default: begin
        // $assert(false, "Unreachable sdr protocol engine state");
      end
    endcase
  end

  always_ff @(clk) begin
    state <= state_n;
  end


endmodule
