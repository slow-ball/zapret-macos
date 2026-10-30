// The filter of the engine's incoming packets (engine/nfq/macrecv.c): compiled with the same libpcap and run
// over sample frames — answers to a connection setup, resets and HTTP answers pass, video and other
// streams don't.
//   xcrun clang -o /tmp/ft tests/engine_filter.c -lpcap && /tmp/ft "$(tests/engine_filter.sh)"
#include <pcap/pcap.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>
static unsigned char frame[200];
static int run(struct bpf_program *p, int len) { return bpf_filter(p->bf_insns, frame, len, len) != 0; }
static void eth(unsigned short type) { memset(frame, 0, sizeof frame); frame[12] = type >> 8; frame[13] = type & 0xff; }
static void ip4(int sport, unsigned char flags) {
	eth(0x0800); unsigned char *ip = frame + 14;
	ip[0] = 0x45; ip[2] = 0; ip[3] = 40; ip[9] = 6; unsigned char *t = ip + 20;
	t[0] = sport >> 8; t[1] = sport & 0xff; t[2] = 0xc3; t[3] = 0x50; t[12] = 0x50; t[13] = flags; }
static void ip6(int sport, unsigned char flags) {
	eth(0x86dd); unsigned char *ip = frame + 14;
	ip[0] = 0x60; ip[6] = 6; unsigned char *t = ip + 40;
	t[0] = sport >> 8; t[1] = sport & 0xff; t[12] = 0x50; t[13] = flags; }
int main(int argc, char **argv) {
	pcap_t *p = pcap_open_dead(DLT_EN10MB, 2048);
	struct bpf_program prog;
	if (pcap_compile(p, &prog, argv[1], 1, PCAP_NETMASK_UNKNOWN) < 0) { printf("compile: %s\n", pcap_geterr(p)); return 1; }
	int bad = 0;
#define T(what, want) do { int got = run(&prog, 94); if (got != want) { printf("FAIL %s\n", what); bad++; } else printf("ok   %s\n", what); } while (0)
	ip4(443, 0x12); T("v4 SYN+ACK 443", 1);
	ip4(443, 0x14); T("v4 RST 443", 1);
	ip4(443, 0x18); T("v4 data 443 (video)", 0);
	ip4(80, 0x18);  T("v4 HTTP data 80", 1);
	ip4(53, 0x14);  T("v4 RST 53", 0);
	ip6(443, 0x12); T("v6 SYN+ACK 443", 1);
	ip6(443, 0x04); T("v6 RST 443", 1);
	ip6(443, 0x10); T("v6 ACK 443", 0);
	ip6(80, 0x18);  T("v6 HTTP data 80", 1);
	return bad;
}
