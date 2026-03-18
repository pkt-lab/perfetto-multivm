# vsock-proxy Makefile for QNX SDP 8.0
#
# Usage:
#   source ~/qnx800/qnxsdp-env.sh
#   make            # builds for aarch64
#   make clean

CC ?= qcc
CFLAGS = -Vgcc_ntoaarch64le -O2 -Wall -Werror
LDFLAGS = -lsocket -lpthread

TARGET = vsock-proxy
SRCS = vsock_proxy.c

all: $(TARGET)

$(TARGET): $(SRCS)
	$(CC) $(CFLAGS) -o $@ $^ $(LDFLAGS)

clean:
	rm -f $(TARGET)

.PHONY: all clean
