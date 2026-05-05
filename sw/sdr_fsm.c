#define _POSIX_C_SOURCE 200809L
#include "sdr_fsm.h"
#include <stdio.h>

static const char *state_name(sdr_state_t s) {
    switch (s) {
    case SDR_PENDING: return "PENDING";
    case SDR_RX:      return "RX";
    case SDR_WAIT_TX: return "WAIT_TX";
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

static void log_transition(const sdr_fsm_t *fsm, sdr_state_t prev) {
    if (fsm->state != prev)
        printf("%s %s -> %s\n", fsm->label, state_name(prev),
               state_name(fsm->state));
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
            packet_t req = make_ctrl(OP_REQ_TX);
            if (fsm->ops.send_to_hub(fsm->ops_ctx, &req) < 0) return -1;
            // Tell FPGA hub is deciding; it should keep receiving (S_TX_DEFERRED).
            packet_t nack = make_ctrl(OP_NACK_TX);
            if (fsm->ops.send_to_fpga(fsm->ops_ctx, &nack) < 0) return -1;
            fsm->state = SDR_WAIT_TX;
        }
        break;

    case SDR_WAIT_TX:
        break;

    case SDR_TX:
        if (pkt->opcode == OP_DATA) {
            fsm->tx_buf_used += pkt->len;
            printf("%s TX buf: %d/%d bytes\n", fsm->label, fsm->tx_buf_used,
                   TX_BUF_CAPACITY);

            if (fsm->ops.send_to_hub(fsm->ops_ctx, pkt) < 0) return -1;

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
            packet_t req = make_ctrl(OP_END_TX);
            if (fsm->ops.send_to_hub(fsm->ops_ctx, &req) < 0) return -1;
        }
        break;
    }

    log_transition(fsm, prev);
    return 0;
}

int sdr_fsm_handle_hub_pkt(sdr_fsm_t *fsm, const packet_t *pkt) {
    sdr_state_t prev = fsm->state;

    switch (pkt->opcode) {
    case OP_ACK_TX:
        if (fsm->state == SDR_WAIT_TX) {
            packet_t rsp = make_ctrl(OP_ACK_TX);
            if (fsm->ops.send_to_fpga(fsm->ops_ctx, &rsp) < 0) return -1;
            fsm->state       = SDR_TX;
            fsm->tx_buf_used = 0;
            fsm->paused      = false;
        }
        break;

    case OP_ACK_RX:
        if (fsm->state == SDR_TX) {
            packet_t rsp = make_ctrl(OP_ACK_RX);
            if (fsm->ops.send_to_fpga(fsm->ops_ctx, &rsp) < 0) return -1;
            fsm->state = SDR_RX;
        }
        break;

    case OP_DATA:
        if (fsm->state != SDR_TX) {
            printf("%s forwarding hub->FPGA %d bytes\n", fsm->label, pkt->len);
            if (fsm->ops.send_to_fpga(fsm->ops_ctx, pkt) < 0) return -1;
        }
        break;

    default:
        break;
    }

    log_transition(fsm, prev);
    return 0;
}
