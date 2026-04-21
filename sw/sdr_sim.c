#define _POSIX_C_SOURCE 200809L
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <time.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <sys/select.h>
#include "protocol.h"

// Simulated TX buffer limits
#define TX_BUF_CAPACITY  512
#define TX_HIGH_WATER    384  // 75% — send PAUSE
#define TX_LOW_WATER     128  // 25% — send RESUME

// Ticks (1 ms each) between fake RX sample emissions in standalone mode
#define RX_EMIT_TICKS  5

typedef enum { SDR_PENDING, SDR_RX, SDR_TX } sdr_state_t;

static const char *state_name(sdr_state_t s) {
    switch (s) {
    case SDR_PENDING: return "PENDING";
    case SDR_RX:      return "RX";
    case SDR_TX:      return "TX";
    }
    return "?";
}

static char lbl[16];

// --- FPGA link (TCP) ---

static int write_all(int sock, const void *buf, size_t n) {
    const uint8_t *p = buf;
    while (n > 0) {
        ssize_t w = write(sock, p, n);
        if (w <= 0) return -1;
        p += w; n -= w;
    }
    return 0;
}

static int read_all(int sock, void *buf, size_t n) {
    uint8_t *p = buf;
    while (n > 0) {
        ssize_t r = read(sock, p, n);
        if (r <= 0) return -1;
        p += r; n -= r;
    }
    return 0;
}

static int fpga_write_pkt(int fd, const packet_t *pkt) {
    uint8_t hdr[2] = { (uint8_t)pkt->opcode, pkt->len };
    if (write_all(fd, hdr, 2) < 0) return -1;
    if (pkt->len > 0 && write_all(fd, pkt->payload, pkt->len) < 0) return -1;
    printf("%s [fpga tx] %-8s len=%d\n", lbl, opcode_name(pkt->opcode), pkt->len);
    return 0;
}

// Blocking read — call only after select confirms data is available
static int fpga_read_pkt(int fd, packet_t *pkt) {
    uint8_t hdr[2];
    if (read_all(fd, hdr, 2) < 0) return -1;
    pkt->opcode = (opcode_t)hdr[0];
    pkt->len    = hdr[1];
    if (pkt->len > MAX_PAYLOAD_BYTES) {
        fprintf(stderr, "%s oversized packet len=%d\n", lbl, pkt->len);
        return -1;
    }
    if (pkt->len > 0 && read_all(fd, pkt->payload, pkt->len) < 0) return -1;
    printf("%s [fpga rx] %-8s len=%d\n", lbl, opcode_name(pkt->opcode), pkt->len);
    return 0;
}

static int tcp_connect(const char *host, int port) {
    int s = socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) { perror("socket"); exit(1); }
    struct sockaddr_in addr = {
        .sin_family = AF_INET,
        .sin_port   = htons((uint16_t)port),
    };
    inet_pton(AF_INET, host, &addr.sin_addr);
    while (connect(s, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        printf("%s retrying connect to %s:%d...\n", lbl, host, port);
        sleep(1);
    }
    return s;
}

// --- OTA link (UDP, symmetric) ---

static int                ota_fd   = -1;
static struct sockaddr_in ota_peer;

static void ota_setup(int my_port, int peer_port) {
    ota_fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (ota_fd < 0) { perror("ota socket"); exit(1); }

    struct sockaddr_in my_addr = {
        .sin_family      = AF_INET,
        .sin_port        = htons((uint16_t)my_port),
        .sin_addr.s_addr = INADDR_ANY,
    };
    if (bind(ota_fd, (struct sockaddr *)&my_addr, sizeof(my_addr)) < 0) {
        perror("ota bind"); exit(1);
    }

    ota_peer.sin_family = AF_INET;
    ota_peer.sin_port   = htons((uint16_t)peer_port);
    inet_pton(AF_INET, "127.0.0.1", &ota_peer.sin_addr);
}

static int ota_send_pkt(const packet_t *pkt) {
    uint8_t buf[2 + MAX_PAYLOAD_BYTES];
    buf[0] = (uint8_t)pkt->opcode;
    buf[1] = pkt->len;
    if (pkt->len > 0) memcpy(buf + 2, pkt->payload, pkt->len);
    if (sendto(ota_fd, buf, (size_t)(2 + pkt->len), 0,
               (struct sockaddr *)&ota_peer, sizeof(ota_peer)) < 0) return -1;
    printf("%s [ota tx] %-8s len=%d\n", lbl, opcode_name(pkt->opcode), pkt->len);
    return 0;
}

// Non-blocking — returns 0 if packet read, 1 if nothing available, -1 on error
static int ota_recv_pkt_nb(packet_t *pkt) {
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
    printf("%s [ota rx] %-8s len=%d\n", lbl, opcode_name(pkt->opcode), pkt->len);
    return 0;
}

// --- main ---

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);  // flush on every newline even when piped

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
    snprintf(lbl, sizeof(lbl), standalone ? "[SDR]" : "[SDR@%d]", atoi(argv[2]));

    printf("%s connecting to FPGA at 127.0.0.1:%d...\n", lbl, fpga_port);
    int fd = tcp_connect("127.0.0.1", fpga_port);
    printf("%s FPGA link up\n", lbl);

    if (!standalone) {
        if (argc < 4) {
            fprintf(stderr, "OTA mode requires both my_ota_port and peer_ota_port\n");
            return 1;
        }
        int my_port   = atoi(argv[2]);
        int peer_port = atoi(argv[3]);
        ota_setup(my_port, peer_port);
        printf("%s OTA link: my_port=%d peer_port=%d\n", lbl, my_port, peer_port);
    }

    sdr_state_t state    = SDR_PENDING;
    int  tx_buf_used     = 0;
    bool paused          = false;
    int  rx_tick         = 0;
    uint8_t rx_counter   = 0;

    for (;;) {
        // Wait up to 1 ms for activity on FPGA socket (and OTA when in RX)
        fd_set rfds;
        FD_ZERO(&rfds);
        FD_SET(fd, &rfds);
        int maxfd = fd;
        struct timeval tv = {0, 1000};
        select(maxfd + 1, &rfds, NULL, NULL, &tv);

        // --- FPGA → SDR ---
        if (FD_ISSET(fd, &rfds)) {
            packet_t pkt;
            if (fpga_read_pkt(fd, &pkt) < 0) {
                fprintf(stderr, "%s FPGA link error\n", lbl);
                break;
            }
            sdr_state_t prev = state;

            switch (state) {
            case SDR_PENDING:
                if (pkt.opcode == OP_POLL) {
                    packet_t rsp = make_ctrl(OP_READY);
                    if (fpga_write_pkt(fd, &rsp) < 0) goto done;
                    state = SDR_RX;
                }
                break;

            case SDR_RX:
                if (pkt.opcode == OP_POLL) {
                    packet_t rsp = make_ctrl(OP_READY);
                    if (fpga_write_pkt(fd, &rsp) < 0) goto done;
                } else if (pkt.opcode == OP_REQ_TX) {
                    packet_t rsp = make_ctrl(OP_ACK_TX);
                    if (fpga_write_pkt(fd, &rsp) < 0) goto done;
                    state       = SDR_TX;
                    tx_buf_used = 0;
                    paused      = false;
                }
                break;

            case SDR_TX:
                if (pkt.opcode == OP_DATA) {
                    tx_buf_used += pkt.len;
                    printf("%s TX buf: %d/%d bytes\n", lbl, tx_buf_used, TX_BUF_CAPACITY);

                    if (ota_fd >= 0 && ota_send_pkt(&pkt) < 0) goto done;

                    if (!paused && tx_buf_used >= TX_HIGH_WATER) {
                        packet_t rsp = make_ctrl(OP_PAUSE);
                        if (fpga_write_pkt(fd, &rsp) < 0) goto done;
                        paused = true;
                    }
                    if (tx_buf_used > TX_LOW_WATER)
                        tx_buf_used /= 2;
                    if (paused && tx_buf_used <= TX_LOW_WATER) {
                        packet_t rsp = make_ctrl(OP_RESUME);
                        if (fpga_write_pkt(fd, &rsp) < 0) goto done;
                        paused = false;
                    }
                } else if (pkt.opcode == OP_END_TX) {
                    tx_buf_used = 0;
                    paused      = false;
                    packet_t rsp = make_ctrl(OP_ACK_RX);
                    if (fpga_write_pkt(fd, &rsp) < 0) goto done;
                    state = SDR_RX;
                }
                break;
            }

            if (state != prev)
                printf("%s %s -> %s\n", lbl, state_name(prev), state_name(state));
        }

        // --- OTA → FPGA ---
        // Only drain the UDP socket when in SDR_RX. While in SDR_TX the
        // kernel buffers incoming datagrams; we leave them unread so nothing
        // is dropped before we can forward them.
        if (ota_fd >= 0 && state == SDR_RX) {
            packet_t pkt;
            int rc = ota_recv_pkt_nb(&pkt);
            if (rc == 0 && pkt.opcode == OP_DATA) {
                printf("%s forwarding OTA->FPGA %d bytes\n", lbl, pkt.len);
                if (fpga_write_pkt(fd, &pkt) < 0) goto done;
            } else if (rc < 0) {
                fprintf(stderr, "%s OTA receive error\n", lbl);
                break;
            }
        }

        // --- Fake RX sample emission (standalone only) ---
        if (standalone && state == SDR_RX && ++rx_tick >= RX_EMIT_TICKS) {
            rx_tick = 0;
            packet_t data;
            data.opcode = OP_DATA;
            data.len    = MAX_PAYLOAD_BYTES;
            for (int i = 0; i < MAX_PAYLOAD_BYTES; i++)
                data.payload[i] = rx_counter++;
            if (fpga_write_pkt(fd, &data) < 0) break;
        }
    }

done:
    close(fd);
    if (ota_fd >= 0) close(ota_fd);
    return 0;
}
