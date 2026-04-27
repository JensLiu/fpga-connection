#define _POSIX_C_SOURCE 200809L
#include "sdr_fsm.h"
#include <stdio.h>
#include <string.h>

static const char *state_name(sdr_state_t s) {
    switch (s) {
    case SDR_PENDING: return "PENDING";
    case SDR_RX:      return "RX";
    case SDR_TX:      return "TX";
    }
    return "?";
}

void sdr_fsm_init(sdr_fsm_t *fsm, const sdr_fsm_ops_t *ops, void *ops_ctx,
                  const char *label) {
    fsm->state       = SDR_PENDING;
    fsm->tx_buf_used = 0;
    fsm->paused      = false;
    fsm->ops         = *ops;
    fsm->ops_ctx     = ops_ctx;
    fsm->label       = label;
}

int sdr_fsm_handle_fpga_pkt(sdr_fsm_t *fsm, const packet_t *pkt) {
    sdr_state_t prev = fsm->state;

    switch (fsm->state) {
    case SDR_PENDING:
        if (pkt->opcode == OP_POLL) {
            packet_t rsp = make_ctrl(OP_READY);
            if (fsm->ops.send_to_fpga(fsm->ops_ctx, &rsp) < 0) return -1;
            fsm->state = SDR_RX;
        }
        break;

    case SDR_RX:
        if (pkt->opcode == OP_POLL) {
            packet_t rsp = make_ctrl(OP_READY);
            if (fsm->ops.send_to_fpga(fsm->ops_ctx, &rsp) < 0) return -1;
        } else if (pkt->opcode == OP_REQ_TX) {
            packet_t rsp = make_ctrl(OP_ACK_TX);
            if (fsm->ops.send_to_fpga(fsm->ops_ctx, &rsp) < 0) return -1;
            fsm->state       = SDR_TX;
            fsm->tx_buf_used = 0;
            fsm->paused      = false;
        }
        break;

    case SDR_TX:
        if (pkt->opcode == OP_DATA) {
            fsm->tx_buf_used += pkt->len;
            printf("%s TX buf: %d/%d bytes\n", fsm->label, fsm->tx_buf_used,
                   TX_BUF_CAPACITY);

            if (fsm->ops.forward_to_peer)
                if (fsm->ops.forward_to_peer(fsm->ops_ctx, pkt) < 0) return -1;

            if (!fsm->paused && fsm->tx_buf_used >= TX_HIGH_WATER) {
                packet_t rsp = make_ctrl(OP_PAUSE);
                if (fsm->ops.send_to_fpga(fsm->ops_ctx, &rsp) < 0) return -1;
                fsm->paused = true;
            }
            if (fsm->tx_buf_used > TX_LOW_WATER)
                fsm->tx_buf_used /= 2;
            if (fsm->paused && fsm->tx_buf_used <= TX_LOW_WATER) {
                packet_t rsp = make_ctrl(OP_RESUME);
                if (fsm->ops.send_to_fpga(fsm->ops_ctx, &rsp) < 0) return -1;
                fsm->paused = false;
            }
        } else if (pkt->opcode == OP_END_TX) {
            fsm->tx_buf_used = 0;
            fsm->paused      = false;
            packet_t rsp = make_ctrl(OP_ACK_RX);
            if (fsm->ops.send_to_fpga(fsm->ops_ctx, &rsp) < 0) return -1;
            fsm->state = SDR_RX;
        }
        break;
    }

    if (fsm->state != prev)
        printf("%s %s -> %s\n", fsm->label, state_name(prev),
               state_name(fsm->state));
    return 0;
}

int sdr_fsm_handle_peer_pkt(sdr_fsm_t *fsm, const packet_t *pkt) {
    // While in SDR_TX the kernel UDP buffer holds incoming datagrams; only
    // drain and forward when the FPGA is ready to receive.
    if (fsm->state != SDR_RX) return 0;
    if (pkt->opcode != OP_DATA) return 0;
    printf("%s forwarding peer->FPGA %d bytes\n", fsm->label, pkt->len);
    return fsm->ops.send_to_fpga(fsm->ops_ctx, pkt);
}
