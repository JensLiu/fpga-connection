#pragma once
#include <stdbool.h>
#include "protocol.h"

#define TX_BUF_CAPACITY  512
#define TX_HIGH_WATER    384
#define TX_LOW_WATER     128

typedef enum { SDR_PENDING, SDR_RX, SDR_TX } sdr_state_t;

// Callbacks the FSM uses to send packets; return 0 on success, -1 on error.
// forward_to_peer may be NULL (standalone mode — no peer exists).
typedef struct {
    int (*send_to_fpga)(void *ctx, const packet_t *pkt);
    int (*forward_to_peer)(void *ctx, const packet_t *pkt);
} sdr_fsm_ops_t;

typedef struct {
    sdr_state_t   state;
    int           tx_buf_used;
    bool          paused;
    sdr_fsm_ops_t ops;
    void         *ops_ctx;
    const char   *label;
} sdr_fsm_t;

void sdr_fsm_init(sdr_fsm_t *fsm, const sdr_fsm_ops_t *ops, void *ops_ctx,
                  const char *label);

// Called when a packet arrives from the FPGA (TCP).
// Returns 0 on success, -1 if the transport reported an error.
int sdr_fsm_handle_fpga_pkt(sdr_fsm_t *fsm, const packet_t *pkt);

// Called when a packet arrives from the peer SDR (UDP) or from a local
// generator (standalone fake-RX).  Only forwarded to the FPGA when in SDR_RX;
// otherwise silently queued in the kernel UDP buffer.
// Returns 0 on success, -1 on error.
int sdr_fsm_handle_peer_pkt(sdr_fsm_t *fsm, const packet_t *pkt);
