#pragma once
#include <stdbool.h>
#include "protocol.h"

#define TX_BUF_CAPACITY  512
#define TX_HIGH_WATER    384
#define TX_LOW_WATER     128

typedef enum {
    SDR_PENDING,   // awaiting POLL/READY handshake with FPGA
    SDR_RX,        // idle; can receive DATA from hub, can request TX
    SDR_WAIT_TX,   // sent REQ_TX to hub, waiting for hub's ACK_TX
    SDR_TX,        // transmitting DATA from FPGA to hub
} sdr_state_t;

typedef struct {
    int (*send_to_fpga)(void *ctx, const packet_t *pkt);
    int (*send_to_hub)(void *ctx, const packet_t *pkt);
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

int sdr_fsm_handle_fpga_pkt(sdr_fsm_t *fsm, const packet_t *pkt);
int sdr_fsm_handle_hub_pkt(sdr_fsm_t *fsm, const packet_t *pkt);
