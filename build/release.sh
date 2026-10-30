#!/bin/bash
# The signed archive of a release: build/release.sh 1.2.0 — the archive of tag v1.2.0 and its signature
# (zapret-macos-1.2.0.tar.gz and .sig) go to release v1.2.0. Only these are installed by an update.
# The key: $ZAPRET_RELEASE_KEY or ~/.config/zapret-release/key (the backup one is kept off the computer).
# Keys are never in the repository.

set -euo pipefail

v=${1:?версия, например 3.1.0}
key=${ZAPRET_RELEASE_KEY:-$HOME/.config/zapret-release/key}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
a=$TMP/zapret-macos-$v.tar.gz

git -C "$ROOT" archive --format=tar.gz --prefix=zapret-macos/ -o "$a" "v$v"
[ "$(tar -xzOf "$a" zapret-macos/src/VERSION)" = "$v" ] || { echo "в теге v$v другая версия" >&2; exit 1; }
ssh-keygen -q -Y sign -f "$key" -n zapret-release "$a"

# the same check the macs do, with the key of the archive itself
tar -xzOf "$a" zapret-macos/src/zapret.sh | sed -n 's/^RELEASE_KEY\(_BACKUP\)\{0,1\}="\(.*\)"$/zapret \2/p' > "$TMP/keys"
ssh-keygen -Y verify -f "$TMP/keys" -I zapret -n zapret-release -s "$a.sig" < "$a"

gh release upload "v$v" "$a" "$a.sig" --clobber -R slow-ball/zapret-macos
echo "подписано и прикреплено: $(basename "$a")"
