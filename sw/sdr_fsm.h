#pragma once
#include <stdbool.h>
#include "protocol.h"

// Pull/credit protocol (see PROTOCOL_DESIGN.md §12).
//
// The SDR holds a single fixed TX buffer: EMPTY or OCCUPIED. When EMPTY it
// polls the FPGA once (one-buffer credit) and waits. The FPGA replies with one
// OP_DATA chunk that fills the buffer; the SDR then requests a hub slot, drains
// the buffer over the air on GRANT, and polls again (pre-fill).

typedef enum {
    SDR_PENDING,  // awaiting OP_READY boot handshake
    SDR_ACTIVE,   // operational; single TX buffer, poll-on-empty
} sdr_state_t;

typedef struct {
    int (*send_to_fpga)(void *ctx, const packet_t *pkt);
    int (*send_to_hub)(void *ctx, const packet_t *pkt);
} sdr_fsm_ops_t;

typedef struct {
    sdr_state_t   state;
    packet_t      tx_buf;          // the single TX buffer (one FPGA chunk)
    bool          buf_occupied;    // tx_buf holds data awaiting a hub slot
    bool          slot_requested;  // REQ_SLOT sent, awaiting GRANT
    sdr_fsm_ops_t ops;
    void         *ops_ctx;
    const char   *label;
} sdr_fsm_t;

void sdr_fsm_init(sdr_fsm_t *fsm, const sdr_fsm_ops_t *ops, void *ops_ctx,
                  const char *label);

int sdr_fsm_handle_fpga_pkt(sdr_fsm_t *fsm, const packet_t *pkt);
int sdr_fsm_handle_hub_pkt(sdr_fsm_t *fsm, const packet_t *pkt);
