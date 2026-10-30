// The fakes of build/fakes.swift as the engine's own parsers read them (protocol.c, the same as a filter's):
// a ClientHello with its site, a QUIC Initial that decrypts to a hello with its site, a STUN message.
// build: xcrun clang -I engine/nfq -o fk tests/engine_fakes.c engine/nfq/protocol.c engine/nfq/helpers.c engine/nfq/crypto/*.c
// run: ./fk src/nfqws/bin/*.bin

#include <stdio.h>
#include <string.h>

#include "crypto/aes.h"
#include "protocol.h"

static int check(const char *path)
{
	static uint8_t data[4096];
	char host[256] = "";
	const char *name = strrchr(path, '/') ? strrchr(path, '/') + 1 : path;
	FILE *f = fopen(path, "rb");
	size_t len;
	bool ok;
	if (!f) return printf("FAIL %s: не открывается\n", name), 0;
	len = fread(data, 1, sizeof(data), f);
	fclose(f);
	if (!strncmp(name, "tls_clienthello_", 16))
		ok = IsTLSClientHello(data, len, false) && TLSHelloExtractHost(data, len, host, sizeof(host), false);
	else if (!strncmp(name, "stun", 4))
		ok = IsStunMessage(data, len);
	else
	{
		// decrypted as a filter does, the CRYPTO frames put together, the hello in them
		static uint8_t clean[1500], defrag[1500];
		size_t clean_len = sizeof(clean), defrag_len = sizeof(defrag), off, hlen;
		bool full;
		ok = IsQUICInitial(data, len) && QUICDecryptInitial(data, len, clean, &clean_len) &&
			QUICDefragCrypto(clean, clean_len, defrag, &defrag_len, &full) && full &&
			IsQUICCryptoHello(defrag, defrag_len, &off, &hlen) &&
			TLSHelloExtractHostFromHandshake(defrag + off, hlen, host, sizeof(host), false);
	}
	printf("%s %s (%zu байт)%s%s\n", ok ? "ok  " : "FAIL", name, len, *host ? ": " : "", host);
	return ok;
}

int main(int argc, char **argv)
{
	int i, bad = 0;
	aes_init_keygen_tables(); // as the engine does at start
	for (i = 1; i < argc; i++) bad += !check(argv[i]);
	return bad != 0;
}
