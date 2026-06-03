#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/select.h>
#include "protocol.h"

#define MAX_SDRS 16

typedef struct {
    int     fd;
    uint8_t rbuf[2 + MAX_PAYLOAD_BYTES];
    int     rlen;
} sdr_conn_t;

static sdr_conn_t conns[MAX_SDRS];
static int        n_sdrs;
static int        active_tx = -1;
static int        tx_queue[MAX_SDRS];
static int        tx_q_head, tx_q_tail;

static void q_push(int idx) { tx_queue[tx_q_tail++ % MAX_SDRS] = idx; }
static int  q_pop(void)     { return tx_queue[tx_q_head++ % MAX_SDRS]; }
static int  q_empty(void)   { return tx_q_head == tx_q_tail; }

static int send_pkt(int fd, const packet_t *pkt) {
    uint8_t buf[2 + MAX_PAYLOAD_BYTES];
    buf[0] = (uint8_t)pkt->opcode;
    buf[1] = pkt->len;
    if (pkt->len > 0) memcpy(buf + 2, pkt->payload, pkt->len);
    size_t total = (size_t)(2 + pkt->len);
    const uint8_t *p = buf;
    while (total > 0) {
        ssize_t w = write(fd, p, total);
        if (w <= 0) return -1;
        p += w; total -= (size_t)w;
    }
    return 0;
}

static int try_read_pkt(sdr_conn_t *c, packet_t *out) {
    int needed = (c->rlen >= 2) ? (2 + c->rbuf[1]) : 2;
    ssize_t r = read(c->fd, c->rbuf + c->rlen, (size_t)(needed - c->rlen));
    if (r <= 0) return -1;
    c->rlen += (int)r;

    if (c->rlen < 2) return 0;
    needed = 2 + c->rbuf[1];
    if (c->rlen < needed) return 0;

    out->opcode = (opcode_t)c->rbuf[0];
    out->len    = c->rbuf[1];
    if (out->len > MAX_PAYLOAD_BYTES) return -1;
    if (out->len > 0) memcpy(out->payload, c->rbuf + 2, out->len);
    c->rlen = 0;
    return 1;
}

static void grant_slot(int idx) {
    active_tx = idx;
    printf("[HUB] SDR%d granted slot\n", idx);
    packet_t g = make_ctrl(OP_GRANT);
    send_pkt(conns[idx].fd, &g);
}

static void hub_handle(int from, const packet_t *pkt) {
    if (pkt->opcode == OP_DATA && pkt->len >= 4) {
        uint32_t word;
        memcpy(&word, pkt->payload, 4);
        printf("[HUB] SDR%d %-8s len=%d  data=0x%08x (%u)\n",
               from, opcode_name(pkt->opcode), pkt->len, word, word);
    } else {
        printf("[HUB] SDR%d %-8s len=%d\n", from, opcode_name(pkt->opcode), pkt->len);
    }

    switch (pkt->opcode) {

    case OP_REQ_SLOT:
        if (active_tx == -1) {
            grant_slot(from);
        } else {
            printf("[HUB] SDR%d queued (SDR%d holds slot)\n", from, active_tx);
            q_push(from);
        }
        break;

    case OP_DATA:
        if (active_tx != from) break;
        for (int j = 0; j < n_sdrs; j++) {
            if (j != from && conns[j].fd >= 0)
                send_pkt(conns[j].fd, pkt);
        }
        break;

    case OP_DONE:
        if (active_tx != from) break;
        printf("[HUB] SDR%d slot done\n", from);
        active_tx = -1;
        if (!q_empty()) grant_slot(q_pop());
        break;

    default:
        break;
    }
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);

    if (argc != 3) {
        fprintf(stderr, "Usage: %s <port> <num_sdrs>\n", argv[0]);
        return 1;
    }

    int port = atoi(argv[1]);
    n_sdrs   = atoi(argv[2]);

    if (n_sdrs < 1 || n_sdrs > MAX_SDRS) {
        fprintf(stderr, "num_sdrs must be 1..%d\n", MAX_SDRS);
        return 1;
    }

    int srv = socket(AF_INET, SOCK_STREAM, 0);
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = {
        .sin_family      = AF_INET,
        .sin_port        = htons((uint16_t)port),
        .sin_addr.s_addr = INADDR_ANY,
    };
    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind"); return 1;
    }
    listen(srv, n_sdrs);
    printf("[HUB] listening on port %d, waiting for %d SDRs\n", port, n_sdrs);

    for (int i = 0; i < n_sdrs; i++) {
        conns[i].fd   = accept(srv, NULL, NULL);
        conns[i].rlen = 0;
        printf("[HUB] SDR%d connected\n", i);
    }
    close(srv);
    printf("[HUB] all %d SDRs connected, running\n", n_sdrs);

    for (;;) {
        fd_set rfds;
        FD_ZERO(&rfds);
        int maxfd = -1;
        for (int i = 0; i < n_sdrs; i++) {
            if (conns[i].fd >= 0) {
                FD_SET(conns[i].fd, &rfds);
                if (conns[i].fd > maxfd) maxfd = conns[i].fd;
            }
        }
        if (maxfd < 0) break;
        if (select(maxfd + 1, &rfds, NULL, NULL, NULL) < 0) break;

        for (int i = 0; i < n_sdrs; i++) {
            if (conns[i].fd < 0 || !FD_ISSET(conns[i].fd, &rfds)) continue;
            packet_t pkt;
            int rc = try_read_pkt(&conns[i], &pkt);
            if (rc < 0) {
                printf("[HUB] SDR%d disconnected\n", i);
                close(conns[i].fd);
                conns[i].fd = -1;
                if (active_tx == i) {
                    active_tx = -1;
                    if (!q_empty()) grant_slot(q_pop());
                }
            } else if (rc == 1) {
                hub_handle(i, &pkt);
            }
        }
    }
    return 0;
}
