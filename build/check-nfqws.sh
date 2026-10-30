#!/bin/bash
# shellcheck source-path=SCRIPTDIR/..
# shellcheck disable=SC2034,SC2329  # the sourced code reads PROJECT and LOG and calls the stubs
# Checks that utunws takes every strategy in its fullest form (the auto list of smart mode, the game
# filter for TCP and UDP, all addresses, a profile of a site's own) and every option of the deep search.
# The configs are made by the same code as on the user's Mac. Used by CI and the import of strategies.
# Run: build/check-nfqws.sh <path to utunws>

set -o pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
UTUNWS=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/rt" "$TMP/project/lists"

export ZAPRET_LIB_ONLY=1 ZAPRET_TEST_RT="$TMP/rt"
# shellcheck source=src/zapret.sh
. "$ROOT/src/zapret.sh"
PROJECT="$TMP/project"
LOG="$TMP/log"
chown() { :; }
install_sudoers() { :; }
launchctl() { :; }
sync_runtime
write_lists
echo smart > "$RT/scope"
echo all > "$RT/game"
printf 'example.com\tmacos (ALT3)\n' > "$SITES"

failed=0
try() {
	if "$UTUNWS" "@$TMP/t.conf" >/dev/null 2>&1; then
		echo "ok   $1"
	else
		echo "FAIL $1"
		"$UTUNWS" "@$TMP/t.conf" 2>&1 | tail -3
		failed=1
	fi
}

while IFS= read -r name; do
	nfqws_conf "$name" "$TMP/c.conf" || { echo "FAIL $name: нет конфига"; failed=1; continue; }
	{ echo --dry-run; cat "$TMP/c.conf"; } > "$TMP/t.conf"
	try "$name"
done < <(strategy_names)

n=0
while IFS= read -r o; do
	n=$((n + 1))
	nfqws_site_conf "$o" "$RT/lists/list-general.txt" "$TMP/c.conf"
	{ echo --dry-run; cat "$TMP/c.conf"; } > "$TMP/t.conf"
	try "глубокий подбор $n: $o"
done < <(deep_candidates)
exit $failed
