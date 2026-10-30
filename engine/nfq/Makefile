CC ?= cc
OPTIMIZE ?= -Os
CFLAGS += -std=gnu99 $(OPTIMIZE) -flto=auto -ffunction-sections -fdata-sections -Wno-address-of-packed-member
LDFLAGS += -flto=auto -Wl,-dead_strip
LIBS = -lz
LIBS_MAC = -lpcap
SRC_FILES = *.c crypto/*.c

.PHONY: mac clean

mac: $(SRC_FILES)
	$(CC) $(CFLAGS) -isysroot "$(SDKROOT)" -o utunwsa $(SRC_FILES) -target arm64-apple-macos14.0 $(LIBS) $(LIBS_MAC) $(LDFLAGS)
	$(CC) $(CFLAGS) -isysroot "$(SDKROOT)" -o utunwsx $(SRC_FILES) -target x86_64-apple-macos14.0 $(LIBS) $(LIBS_MAC) $(LDFLAGS)
	strip utunwsa utunwsx
	lipo -create -output utunws utunwsx utunwsa
	rm -f utunwsx utunwsa

clean:
	rm -f utunws utunwsa utunwsx
