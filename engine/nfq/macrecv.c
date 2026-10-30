#ifdef __APPLE__

#include "macrecv.h"

#include <net/ethernet.h>
#include <pcap/pcap.h>
#include <stdio.h>
#include <string.h>

static pcap_t *capture = NULL;

// only what the auto hostlist looks at, from the ports of the web: SYN+ACK and RST of 80 and 443,
// HTTP data of 80. IPv6: next header TCP right after the fixed header. "from port 443" is already the
// incoming direction: the computer's own connections go to these ports, not from them
static const char *filter =
	"(ip and tcp and (src port 443 or src port 80) and "
	"(tcp[tcpflags] & (tcp-syn|tcp-rst) != 0 or (src port 80 and tcp[tcpflags] & tcp-push != 0))) or "
	"(ip6 and ip6[6] == 6 and (ip6[40:2] == 443 or ip6[40:2] == 80) and "
	"(ip6[53] & 0x06 != 0 or (ip6[40:2] == 80 and ip6[53] & 0x08 != 0)))";

static int fail(char *why, size_t why_size, const char *step, const char *detail)
{
	snprintf(why, why_size, "%s: %s", step, detail && *detail ? detail : "?");
	macrecv_close();
	return -1;
}

int macrecv_open(const char *ifname, char *why, size_t why_size)
{
	char err[PCAP_ERRBUF_SIZE] = "";
	struct bpf_program program;

	if (!ifname || !*ifname) return fail(why, why_size, "interface", "none");
	capture = pcap_create(ifname, err);
	if (!capture) return fail(why, why_size, "pcap_create", err);
	if (pcap_set_snaplen(capture, 2048) || pcap_set_immediate_mode(capture, 1))
		return fail(why, why_size, "pcap_set", pcap_geterr(capture));
	int r = pcap_activate(capture);
	if (r < 0) return fail(why, why_size, "pcap_activate", r == PCAP_ERROR ? pcap_geterr(capture) : pcap_statustostr(r));
	if (pcap_datalink(capture) != DLT_EN10MB) return fail(why, why_size, "datalink", "not Ethernet");
	if (pcap_compile(capture, &program, filter, 1, PCAP_NETMASK_UNKNOWN) < 0)
		return fail(why, why_size, "pcap_compile", pcap_geterr(capture));
	r = pcap_setfilter(capture, &program);
	pcap_freecode(&program);
	if (r < 0) return fail(why, why_size, "pcap_setfilter", pcap_geterr(capture));
	if (pcap_setnonblock(capture, 1, err) < 0) return fail(why, why_size, "pcap_setnonblock", err);
	int fd = pcap_get_selectable_fd(capture);
	if (fd < 0) return fail(why, why_size, "pcap_get_selectable_fd", "none");
	return fd;
}

ssize_t macrecv_packet(uint8_t *buf, size_t size)
{
	struct pcap_pkthdr *header;
	const u_char *data;

	if (!capture) return -1;
	int r = pcap_next_ex(capture, &header, &data);
	if (r == 0) return 0;
	if (r < 0) return -1;
	if (header->caplen <= ETHER_HDR_LEN) return 0;
	uint16_t type = (uint16_t)(data[12] << 8 | data[13]);
	if (type != ETHERTYPE_IP && type != ETHERTYPE_IPV6) return 0;
	size_t len = header->caplen - ETHER_HDR_LEN;
	if (len > size) len = size;
	memcpy(buf, data + ETHER_HDR_LEN, len);
	return (ssize_t)len;
}

void macrecv_close(void)
{
	if (capture) pcap_close(capture);
	capture = NULL;
}

#endif
