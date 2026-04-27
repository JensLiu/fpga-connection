CC      = gcc
CFLAGS  = -Wall -Wextra -std=c11 -g

all: sdr_sim

OBJS = sdr_sim.o sdr_fsm.o

sdr_sim: $(OBJS)
	$(CC) $(CFLAGS) -o $@ $(OBJS)

sdr_sim.o: sdr_sim.c protocol.h sdr_fsm.h
sdr_fsm.o: sdr_fsm.c sdr_fsm.h protocol.h

clean:
	rm -f sdr_sim $(OBJS)

.PHONY: all clean
