module sdr_ctrl_protocol_parser
  import pkg_sdr_ctrl_protocol::*;
#(
    parameter int unsigned ITER_ELEM_SIZE = 8
) (
    input logic clk,
    // protocol interface
    sdr_ctrl_protocol_if.master core,
    // FIFO iterator interface
    iter_if.slave iter
);

  typedef enum {
    S_IDLE,
    S_HEADER,
    S_PAYLOAD,
    S_FINISHED
  } state_t;

  state_t state, state_n;
  union {
    pkg_sdr_ctrl_protocol::protocol_t as_protocol;
    logic [$bits(pkg_sdr_ctrl_protocol::protocol_t)-1:0] as_bits;
  }
      prot_buf, prot_buf_n;

  logic iter_has_data = iter.valid;
  logic [ITER_ELEM_SIZE-1:0] iter_data = iter.data;
  logic [ITER_ELEM_SIZE-1:0] buf_val_idx, buf_val_idx_n;
  logic [PAYLOAD_SIZE_BITS-1:0] payload_rem_size, payload_rem_size_n;
  always_comb begin
    core.valid = 0;
    core.data  = prot_buf_n.as_protocol;  // < the reader should NOT read when not valid
    iter.ready = 0; // < by default do NOT consume data from the iterator
    case (state)
      S_IDLE: begin
        if (iter_has_data) begin
          state_n = S_HEADER;
          buf_val_idx_n = 0;
        end
      end
      S_HEADER: begin
        iter.ready = 1;
        prot_buf_n.as_bits[buf_val_idx+ITER_ELEM_SIZE-1:0] = {
          iter_data, prot_buf.as_bits[buf_val_idx-1:0]
        };
        buf_val_idx_n += ITER_ELEM_SIZE;  // < beginning index of the next chunk
        if (buf_val_idx_n >= PAYLOAD_SIZE_START_BIT) begin
          state_n = S_PAYLOAD;  // < we now know the total size of the payload
          // remaining payload size = total payload size - partial payload in the current chunk
          payload_rem_size_n = prot_buf_n.as_protocol.payload.data.payload_size -
                              (buf_val_idx_n - PAYLOAD_DATA_START_BIT);
        end
      end
      S_PAYLOAD: begin
        iter.ready = 1;
        prot_buf_n.as_bits[buf_val_idx+ITER_ELEM_SIZE-1:0] = {
          iter_data, prot_buf.as_bits[buf_val_idx-1:0]
        };
        buf_val_idx_n += ITER_ELEM_SIZE;
        payload_rem_size_n = payload_rem_size - PAYLOAD_SIZE;  // < all payload is used for data
        if (payload_rem_size_n <= 0) begin
          state_n = S_FINISHED;
        end
      end
      S_FINISHED: begin
        // We are now able to send the protocol data
        core.valid = 1;
        if (core.ready) begin
          // The reader has processed the data
          state_n = S_IDLE;
        end
      end
      default: begin
        $fatal(1, "Unrechable sdr protocol parser state");
      end
    endcase
  end

  always_ff @(posedge clk) begin
    state <= state_n;
    prot_buf <= prot_buf_n;
    buf_val_idx <= buf_val_idx_n;
    payload_rem_size <= payload_rem_size_n;
  end

endmodule

