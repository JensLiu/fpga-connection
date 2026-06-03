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
#include "sdr_fsm.h"

typedef struct {
    int         fpga_fd;
    int         hub_fd;
    const char *label;
} server_ctx_t;

static int write_all(int fd, const void *buf, size_t n) {
    const uint8_t *p = buf;
    while (n > 0) {
        ssize_t w = write(fd, p, n);
        if (w <= 0) return -1;
        p += w; n -= w;
    }
    return 0;
}

static int read_all(int fd, void *buf, size_t n) {
    uint8_t *p = buf;
    while (n > 0) {
        ssize_t r = read(fd, p, n);
        if (r <= 0) return -1;
        p += r; n -= r;
    }
    return 0;
}

static int send_pkt(int fd, const char *label, const char *dir,
                    const packet_t *pkt) {
    uint8_t hdr[2] = { (uint8_t)pkt->opcode, pkt->len };
    if (write_all(fd, hdr, 2) < 0) return -1;
    if (pkt->len > 0 && write_all(fd, pkt->payload, pkt->len) < 0) return -1;
    printf("%s [%s tx] %-8s len=%d\n", label, dir,
           opcode_name(pkt->opcode), pkt->len);
    return 0;
}

static bool known_opcode(uint8_t b) {
    switch (b) {
    case OP_READY: case OP_POLL: case OP_REQ_SLOT:
    case OP_GRANT: case OP_DONE:  case OP_DATA:
        return true;
    }
    return false;
}

static int recv_pkt(int fd, const char *label, const char *dir,
                    packet_t *pkt) {
    // Resync to a frame boundary: the byte stream has no delimiter, and on this
    // sim's UART link the socket can connect mid-frame (pre-connect bytes are
    // dropped). Skip bytes until a recognised opcode. During boot the FPGA only
    // emits zero-payload READY frames, so this realigns within a byte or two;
    // once aligned the (reliable) link stays aligned.
    uint8_t op;
    int skipped = 0;
    do {
        if (read_all(fd, &op, 1) < 0) return -1;
        if (!known_opcode(op)) skipped++;
    } while (!known_opcode(op));
    if (skipped)
        printf("%s [%s rx] resync: skipped %d byte(s)\n", label, dir, skipped);

    uint8_t len;
    if (read_all(fd, &len, 1) < 0) return -1;
    pkt->opcode = (opcode_t)op;
    pkt->len    = len;
    if (pkt->len > MAX_PAYLOAD_BYTES) {
        fprintf(stderr, "%s oversized packet len=%d\n", label, pkt->len);
        return -1;
    }
    if (pkt->len > 0 && read_all(fd, pkt->payload, pkt->len) < 0) return -1;
    printf("%s [%s rx] %-8s len=%d\n", label, dir,
           opcode_name(pkt->opcode), pkt->len);
    return 0;
}

static int cb_send_to_fpga(void *ctx, const packet_t *pkt) {
    server_ctx_t *s = ctx;
    return send_pkt(s->fpga_fd, s->label, "fpga", pkt);
}

static int cb_send_to_hub(void *ctx, const packet_t *pkt) {
    server_ctx_t *s = ctx;
    return send_pkt(s->hub_fd, s->label, "hub", pkt);
}

// Verilator mode: connect to Verilator's UARTSIM TCP server (retries until up).
static int fpga_connect(const char *label, const char *host, int port) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) { perror("socket"); exit(1); }
    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port   = htons((uint16_t)port),
    };
    inet_pton(AF_INET, host, &addr.sin_addr);
    while (connect(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        printf("%s retrying connect to %s:%d...\n", label, host, port);
        sleep(1);
    }
    return s;
}

// Real-FPGA mode: listen on a port and accept one connection.
static int fpga_listen(const char *label, int port) {
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) { perror("socket"); exit(1); }
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
    struct sockaddr_in addr = {
        .sin_family      = AF_INET,
        .sin_port        = htons((uint16_t)port),
        .sin_addr.s_addr = INADDR_ANY,
    };
    if (bind(srv, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind"); exit(1);
    }
    listen(srv, 1);
    printf("%s listening on port %d — connect with:  nc 127.0.0.1 %d\n",
           label, port, port);
    struct sockaddr_in peer;
    socklen_t plen = sizeof(peer);
    int fd = accept(srv, (struct sockaddr *)&peer, &plen);
    if (fd < 0) { perror("accept"); exit(1); }
    close(srv);
    printf("%s FPGA connected from %s\n", label, inet_ntoa(peer.sin_addr));
    return fd;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);

    if (argc != 4) {
        fprintf(stderr,
            "Usage:\n"
            "  %s sim <verilator_port> <hub_port>\n"
            "  %s hw  <listen_port>    <hub_port>\n",
            argv[0], argv[0]);
        return 1;
    }

    bool do_listen = (strcmp(argv[1], "hw") == 0);
    int  fpga_port = atoi(argv[2]);
    int  hub_port  = atoi(argv[3]);

    char label[16];
    snprintf(label, sizeof(label), "[SDR@%d]", fpga_port);

    int fpga_fd = do_listen ? fpga_listen(label, fpga_port)
                            : fpga_connect(label, "127.0.0.1", fpga_port);

    printf("%s connecting to hub at 127.0.0.1:%d...\n", label, hub_port);
    int hub_fd = fpga_connect(label, "127.0.0.1", hub_port);
    printf("%s hub link up\n", label);

    server_ctx_t srv = { .fpga_fd = fpga_fd, .hub_fd = hub_fd, .label = label };

    sdr_fsm_ops_t ops = { .send_to_fpga = cb_send_to_fpga,
                          .send_to_hub  = cb_send_to_hub };
    sdr_fsm_t fsm;
    sdr_fsm_init(&fsm, &ops, &srv, label);

    int maxfd = fpga_fd > hub_fd ? fpga_fd : hub_fd;

    for (;;) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(fpga_fd, &rfds);
        FD_SET(hub_fd,  &rfds);
        if (select(maxfd + 1, &rfds, NULL, NULL, NULL) < 0) break;

        if (FD_ISSET(fpga_fd, &rfds)) {
            packet_t pkt;
            if (recv_pkt(fpga_fd, label, "fpga", &pkt) < 0) {
                fprintf(stderr, "%s FPGA link error\n", label);
                break;
            }
            if (sdr_fsm_handle_fpga_pkt(&fsm, &pkt) < 0) break;
        }

        if (FD_ISSET(hub_fd, &rfds)) {
            packet_t pkt;
            if (recv_pkt(hub_fd, label, "hub", &pkt) < 0) {
                fprintf(stderr, "%s hub link error\n", label);
                break;
            }
            if (sdr_fsm_handle_hub_pkt(&fsm, &pkt) < 0) break;
        }
    }

    close(fpga_fd);
    close(hub_fd);
    return 0;
}
