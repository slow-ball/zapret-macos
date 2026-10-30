#pragma once

#ifdef __APPLE__

#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

// Incoming packets of the physical interface that nfqws needs to see the other side of a connection:
// servers' answers to connection setup (SYN+ACK), resets and the first HTTP replies. The port of
// Flowseal reads only outgoing packets from utun; with these the auto hostlist of nfqws works as on Linux.
// The packets are copies: the system delivers the originals, nothing is sent back.

// opens the capture on ifname; returns a descriptor to wait on with select(), or -1 with the reason in why
int macrecv_open(const char *ifname, char *why, size_t why_size);
// the next waiting IP packet without its Ethernet header into buf: its length, 0 if none is waiting, -1 on error
ssize_t macrecv_packet(uint8_t *buf, size_t size);
void macrecv_close(void);

#endif
