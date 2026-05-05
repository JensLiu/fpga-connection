CC      = gcc
CFLAGS  = -Wall -Wextra -std=c11 -g

all: sdr_sim sdr_hub

SIM_OBJS = sdr_sim.o sdr_fsm.o
HUB_OBJS = sdr_hub.o

sdr_sim: $(SIM_OBJS)
	$(CC) $(CFLAGS) -o $@ $(SIM_OBJS)

sdr_hub: $(HUB_OBJS)
	$(CC) $(CFLAGS) -o $@ $(HUB_OBJS)

sdr_sim.o: sdr_sim.c protocol.h sdr_fsm.h
sdr_fsm.o: sdr_fsm.c sdr_fsm.h protocol.h
sdr_hub.o: sdr_hub.c protocol.h

clean:
	rm -f sdr_sim sdr_hub $(SIM_OBJS) $(HUB_OBJS)

.PHONY: all clean
