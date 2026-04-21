CC      = gcc
CFLAGS  = -Wall -Wextra -std=c11 -g

all: sdr_sim

sdr_sim: sdr_sim.c protocol.h
	$(CC) $(CFLAGS) -o $@ sdr_sim.c

clean:
	rm -f sdr_sim

.PHONY: all clean
