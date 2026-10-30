#!/bin/bash
# Builds the engine (utunws, engine/nfq) and the Telegram proxy (zapret-tg, engine/tg) for Intel and Apple
# Silicon. The result: <output folder>/utunws.tar.gz — bin/utunws, bin/zapret-tg, LICENSE, SOURCE.
# The fake payloads are in the project (src/nfqws/bin, build/fakes.swift), next to the strategies.
# Run: build/utunws.sh [output folder, dist by default]

set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(mkdir -p "${1:-dist}" && cd "${1:-dist}" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
SRC="$TMP/engine"
cp -R "$ROOT/engine" "$SRC"

make -C "$SRC/nfq" mac CC="$(xcrun -f clang)" SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
# strip and lipo leave the x86_64 part unsigned, and Apple Silicon runs only signed code
codesign --force -s - -i utunws "$SRC/nfq/utunws"
codesign -v "$SRC/nfq/utunws"

# the Telegram proxy (engine/tg), for both kinds of Mac
# shellcheck source=build/sdk.sh
. "$ROOT/build/sdk.sh"
for arch in arm64 x86_64; do
	xcrun swiftc -O -swift-version 5 -sdk "$(app_sdk)" -target "$arch-apple-macos14.0" "$ROOT/engine/tg/main.swift" -o "$TMP/zapret-tg-$arch"
done
lipo -create -output "$TMP/zapret-tg" "$TMP/zapret-tg-arm64" "$TMP/zapret-tg-x86_64"
codesign --force -s - -i zapret-tg "$TMP/zapret-tg"
codesign -v "$TMP/zapret-tg"

mkdir -p "$TMP/pkg/bin"
cp "$SRC/nfq/utunws" "$TMP/zapret-tg" "$TMP/pkg/bin/"
cp "$SRC/LICENSE" "$TMP/pkg/"
{
	echo "zapret-macos engine $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo local)"
	echo "upstream Flowseal/zapret-mac-discord-youtube $(cat "$ROOT/engine/UPSTREAM")"
} > "$TMP/pkg/SOURCE"
tar -czf "$OUT/utunws.tar.gz" -C "$TMP/pkg" .
shasum -a 256 "$OUT/utunws.tar.gz"
