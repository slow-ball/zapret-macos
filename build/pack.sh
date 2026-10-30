#!/bin/bash
# shellcheck source-path=SCRIPTDIR/..
# shellcheck disable=SC2034,SC2329  # the sourced code reads these and calls the stubs
# Пакет свежих стратегий (src/lib/pack.sh): build/pack.sh <папка> — pack.tar.gz, а с ключом
# (ZAPRET_PACK_KEY — путь к файлу) ещё и подпись pack.tar.gz.sig. Его собирает и выкладывает в релиз
# «pack» workflow Strategy pack (pack.yml) после зелёного Check на main.
# Метка — версия Windows-версии и время последнего изменения стратегий и списков, а не сборки:
# один и тот же пакет не скачивается заново.

# no -e and -u: the sourced zapret.sh is not written for them; the steps check themselves
set -o pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$(mkdir -p "${1:?папка}" && cd "$1" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
d=$TMP/pack
mkdir -p "$d/nfqws/strategies" "$d/nfqws/bin" "$d/lists"
cd "$ROOT" || exit 1
cp src/nfqws/strategies/*.conf.in "$d/nfqws/strategies/" &&
	cp src/nfqws/strategies.tsv src/nfqws/windows-version src/nfqws/ipset-game.txt "$d/nfqws/" &&
	cp src/nfqws/bin/*.bin "$d/nfqws/bin/" &&
	cp src/list-general.txt src/list-google.txt src/list-exclude.txt src/ipset-exclude.txt "$d/lists/" || exit 1
when=$(TZ=UTC git log -1 --date=format-local:%Y%m%d.%H%M --format=%cd -- \
	src/nfqws/strategies src/nfqws/strategies.tsv src/nfqws/windows-version src/nfqws/bin src/nfqws/ipset-game.txt \
	src/list-general.txt src/list-google.txt src/list-exclude.txt src/ipset-exclude.txt)
[ -n "$when" ] || { echo "нет истории git" >&2; exit 1; }
echo "$(cat src/nfqws/windows-version)+$when" > "$d/STAMP"

# the same check the macs do before they take a pack
export ZAPRET_LIB_ONLY=1 ZAPRET_TEST_RT="$TMP/rt"
# shellcheck source=src/zapret.sh
. src/zapret.sh
pack_valid "$d" || { echo "пакет не прошёл проверку" >&2; exit 1; }

tar -czf "$OUT/pack.tar.gz" -C "$d" STAMP nfqws lists || exit 1
if [ -n "${ZAPRET_PACK_KEY:-}" ]; then
	rm -f "$OUT/pack.tar.gz.sig"
	ssh-keygen -q -Y sign -f "$ZAPRET_PACK_KEY" -n zapret-pack "$OUT/pack.tar.gz" </dev/null || exit 1
	verify_pack "$OUT/pack.tar.gz" "$OUT/pack.tar.gz.sig" || { echo "подпись не сходится с PACK_KEY" >&2; exit 1; }
fi
echo "пакет $(cat "$d/STAMP")"
