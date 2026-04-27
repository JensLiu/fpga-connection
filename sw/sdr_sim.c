#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/select.h>
#include "protocol.h"
#include "sdr_fsm.h"

// Ticks (1 ms each) between fake RX sample emissions in standalone mode
#define RX_EMIT_TICKS  5

// --- server context (owns all socket fds) ---

typedef struct {
    int                fpga_fd;
    int                ota_fd;    // -1 in standalone
    struct sockaddr_in ota_peer;
    const char        *label;
} server_ctx_t;

// --- transport helpers ---

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

static int fpga_write_pkt(int fd, const char *label, const packet_t *pkt) {
    uint8_t hdr[2] = { (uint8_t)pkt->opcode, pkt->len };
    if (write_all(fd, hdr, 2) < 0) return -1;
    if (pkt->len > 0 && write_all(fd, pkt->payload, pkt->len) < 0) return -1;
    printf("%s [fpga tx] %-8s len=%d\n", label, opcode_name(pkt->opcode), pkt->len);
    return 0;
}

static int fpga_read_pkt(int fd, const char *label, packet_t *pkt) {
    uint8_t hdr[2];
    if (read_all(fd, hdr, 2) < 0) return -1;
    pkt->opcode = (opcode_t)hdr[0];
    pkt->len    = hdr[1];
    if (pkt->len > MAX_PAYLOAD_BYTES) {
        fprintf(stderr, "%s oversized packet len=%d\n", label, pkt->len);
        return -1;
    }
    if (pkt->len > 0 && read_all(fd, pkt->payload, pkt->len) < 0) return -1;
    printf("%s [fpga rx] %-8s len=%d\n", label, opcode_name(pkt->opcode), pkt->len);
    return 0;
}

// --- FSM callbacks ---

static int cb_send_to_fpga(void *ctx, const packet_t *pkt) {
    server_ctx_t *s = ctx;
    return fpga_write_pkt(s->fpga_fd, s->label, pkt);
}

static int cb_forward_to_peer(void *ctx, const packet_t *pkt) {
    server_ctx_t *s = ctx;
    uint8_t buf[2 + MAX_PAYLOAD_BYTES];
    buf[0] = (uint8_t)pkt->opcode;
    buf[1] = pkt->len;
    if (pkt->len > 0) memcpy(buf + 2, pkt->payload, pkt->len);
    if (sendto(s->ota_fd, buf, (size_t)(2 + pkt->len), 0,
               (struct sockaddr *)&s->ota_peer, sizeof(s->ota_peer)) < 0)
        return -1;
    printf("%s [ota tx] %-8s len=%d\n", s->label, opcode_name(pkt->opcode), pkt->len);
    return 0;
}

// --- OTA receive (non-blocking) ---
// Returns 0 if a packet was placed in *pkt, 1 if nothing available, -1 on error.

static int ota_recv_nb(int ota_fd, const char *label, packet_t *pkt) {
    fd_set rfds;
    FD_ZERO(&rfds);
    FD_SET(ota_fd, &rfds);
    struct timeval tv = {0, 0};
    if (select(ota_fd + 1, &rfds, NULL, NULL, &tv) <= 0) return 1;

    uint8_t buf[2 + MAX_PAYLOAD_BYTES];
    ssize_t n = recvfrom(ota_fd, buf, sizeof(buf), 0, NULL, NULL);
    if (n < 2) return -1;
    pkt->opcode = (opcode_t)buf[0];
    pkt->len    = buf[1];
    if (pkt->len > MAX_PAYLOAD_BYTES) return -1;
    if (pkt->len > 0) memcpy(pkt->payload, buf + 2, pkt->len);
    printf("%s [ota rx] %-8s len=%d\n", label, opcode_name(pkt->opcode), pkt->len);
    return 0;
}

// --- TCP connect with retry ---

static int tcp_connect(const char *label, const char *host, int port) {
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

// --- UDP OTA socket setup ---

static int ota_setup(const char *label, int my_port, int peer_port,
                     struct sockaddr_in *peer_addr) {
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) { perror("ota socket"); exit(1); }
    struct sockaddr_in my_addr = {
        .sin_family      = AF_INET,
        .sin_port        = htons((uint16_t)my_port),
        .sin_addr.s_addr = INADDR_ANY,
    };
    if (bind(fd, (struct sockaddr *)&my_addr, sizeof(my_addr)) < 0) {
        perror("ota bind"); exit(1);
    }
    peer_addr->sin_family = AF_INET;
    peer_addr->sin_port   = htons((uint16_t)peer_port);
    inet_pton(AF_INET, "127.0.0.1", &peer_addr->sin_addr);
    printf("%s OTA link: my_port=%d peer_port=%d\n", label, my_port, peer_port);
    return fd;
}

// --- main ---

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);

    if (argc < 3) {
        fprintf(stderr,
            "Usage:\n"
            "  %s <fpga_port> standalone\n"
            "  %s <fpga_port> <my_ota_port> <peer_ota_port>\n",
            argv[0], argv[0]);
        return 1;
    }

    int  fpga_port  = atoi(argv[1]);
    bool standalone = (strcmp(argv[2], "standalone") == 0);

    char label[16];
    snprintf(label, sizeof(label), standalone ? "[SDR]" : "[SDR@%d]", atoi(argv[2]));

    printf("%s connecting to FPGA at 127.0.0.1:%d...\n", label, fpga_port);
    int fpga_fd = tcp_connect(label, "127.0.0.1", fpga_port);
    printf("%s FPGA link up\n", label);

    server_ctx_t srv = {
        .fpga_fd = fpga_fd,
        .ota_fd  = -1,
        .label   = label,
    };

    if (!standalone) {
        if (argc < 4) {
            fprintf(stderr, "OTA mode requires both my_ota_port and peer_ota_port\n");
            return 1;
        }
        srv.ota_fd = ota_setup(label, atoi(argv[2]), atoi(argv[3]), &srv.ota_peer);
    }

    sdr_fsm_ops_t ops = {
        .send_to_fpga    = cb_send_to_fpga,
        .forward_to_peer = standalone ? NULL : cb_forward_to_peer,
    };
    sdr_fsm_t fsm;
    sdr_fsm_init(&fsm, &ops, &srv, label);

    int     rx_tick    = 0;
    uint8_t rx_counter = 0;

    for (;;) {
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(fpga_fd, &rfds);
        struct timeval tv = {0, 1000};
        select(fpga_fd + 1, &rfds, NULL, NULL, &tv);

        // FPGA → FSM
        if (FD_ISSET(fpga_fd, &rfds)) {
            packet_t pkt;
            if (fpga_read_pkt(fpga_fd, label, &pkt) < 0) {
                fprintf(stderr, "%s FPGA link error\n", label);
                break;
            }
            if (sdr_fsm_handle_fpga_pkt(&fsm, &pkt) < 0) break;
        }

        // OTA peer → FSM (FSM gates forwarding to FPGA; kernel buffers while in TX)
        if (srv.ota_fd >= 0) {
            packet_t pkt;
            int rc = ota_recv_nb(srv.ota_fd, label, &pkt);
            if (rc == 0) {
                if (sdr_fsm_handle_peer_pkt(&fsm, &pkt) < 0) break;
            } else if (rc < 0) {
                fprintf(stderr, "%s OTA receive error\n", label);
                break;
            }
        }

        // Standalone: inject fake RX samples through the FSM every RX_EMIT_TICKS ms
        if (standalone && ++rx_tick >= RX_EMIT_TICKS) {
            rx_tick = 0;
            packet_t data;
            data.opcode = OP_DATA;
            data.len    = MAX_PAYLOAD_BYTES;
            for (int i = 0; i < MAX_PAYLOAD_BYTES; i++)
                data.payload[i] = rx_counter++;
            if (sdr_fsm_handle_peer_pkt(&fsm, &data) < 0) break;
        }
    }

    close(fpga_fd);
    if (srv.ota_fd >= 0) close(srv.ota_fd);
    return 0;
}
