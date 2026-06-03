#define _POSIX_C_SOURCE 200809L
#include "sdr_fsm.h"
#include <stdio.h>
#include <string.h>

static const char *state_name(sdr_state_t s) {
    switch (s) {
    case SDR_PENDING: return "PENDING";
    case SDR_ACTIVE:  return "ACTIVE";
    }
    return "?";
}

void sdr_fsm_init(sdr_fsm_t *fsm, const sdr_fsm_ops_t *ops, void *ops_ctx,
                  const char *label) {
    fsm->state          = SDR_PENDING;
    fsm->buf_occupied   = false;
    fsm->slot_requested = false;
    memset(&fsm->tx_buf, 0, sizeof(fsm->tx_buf));
    fsm->ops            = *ops;
    fsm->ops_ctx        = ops_ctx;
    fsm->label          = label;
}

static void log_transition(const sdr_fsm_t *fsm, sdr_state_t prev) {
    if (fsm->state != prev)
        printf("%s %s -> %s\n", fsm->label, state_name(prev),
               state_name(fsm->state));
}

// Buffer is empty — grant the FPGA one buffer-fill.
static int send_poll(sdr_fsm_t *fsm) {
    packet_t poll = make_ctrl(OP_POLL);
    return fsm->ops.send_to_fpga(fsm->ops_ctx, &poll);
}

// Latch one FPGA chunk into the TX buffer and ask the hub for a slot.
static int occupy_buffer(sdr_fsm_t *fsm, const packet_t *pkt) {
    if (fsm->buf_occupied) {
        // Should not happen: the FPGA only sends after a poll, and we only poll
        // when empty. Drop to stay safe.
        printf("%s unexpected DATA while buffer occupied, dropping\n",
               fsm->label);
        return 0;
    }
    fsm->tx_buf       = *pkt;
    fsm->buf_occupied = true;
    printf("%s TX buf <- %d bytes\n", fsm->label, pkt->len);

    if (!fsm->slot_requested) {
        packet_t req = make_ctrl(OP_REQ_SLOT);
        if (fsm->ops.send_to_hub(fsm->ops_ctx, &req) < 0) return -1;
        fsm->slot_requested = true;
    }
    return 0;
}

int sdr_fsm_handle_fpga_pkt(sdr_fsm_t *fsm, const packet_t *pkt) {
    sdr_state_t prev = fsm->state;

    switch (fsm->state) {

    case SDR_PENDING:
        if (pkt->opcode == OP_READY) {
            fsm->state = SDR_ACTIVE;
            if (!fsm->buf_occupied && send_poll(fsm) < 0) return -1;
        } else if (pkt->opcode == OP_DATA) {
            // FPGA already ACTIVE on reconnect (it had a credit and sent data).
            // Skip the boot handshake and rejoin at ACTIVE.
            printf("%s FPGA already ACTIVE on reconnect, skipping handshake\n",
                   fsm->label);
            fsm->state = SDR_ACTIVE;
            log_transition(fsm, prev);
            return occupy_buffer(fsm, pkt);
        }
        break;

    case SDR_ACTIVE:
        if (pkt->opcode == OP_READY) {
            // FPGA rebooted — flush stale buffer state and re-poll.
            fsm->buf_occupied   = false;
            fsm->slot_requested = false;
            if (send_poll(fsm) < 0) return -1;
        } else if (pkt->opcode == OP_DATA) {
            if (occupy_buffer(fsm, pkt) < 0) return -1;
        }
        break;
    }

    log_transition(fsm, prev);
    return 0;
}

int sdr_fsm_handle_hub_pkt(sdr_fsm_t *fsm, const packet_t *pkt) {
    if (fsm->state != SDR_ACTIVE)
        return 0;

    switch (pkt->opcode) {

    case OP_GRANT:
        // Drain the one buffer over the air, release the slot, then re-poll so
        // the buffer refills before the next token (pre-fill).
        if (fsm->buf_occupied) {
            if (fsm->ops.send_to_hub(fsm->ops_ctx, &fsm->tx_buf) < 0) return -1;
            fsm->buf_occupied = false;
        }
        fsm->slot_requested = false;
        {
            packet_t done = make_ctrl(OP_DONE);
            if (fsm->ops.send_to_hub(fsm->ops_ctx, &done) < 0) return -1;
        }
        if (send_poll(fsm) < 0) return -1;
        break;

    case OP_DATA:
        // Hub broadcast from another SDR — forward straight to the FPGA (RX).
        if (fsm->ops.send_to_fpga(fsm->ops_ctx, pkt) < 0) return -1;
        break;

    default:
        break;
    }

    return 0;
}
