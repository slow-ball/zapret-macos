#!/bin/bash
# A release in one command: build/ship.sh 1.2.0 — from the current branch, where the finished work is.
# build/ship.sh 1.2.0 --check — only the checks before a release, nothing is published.
# Sets the version, waits for Check and E2E, builds the engine and the app (workflow Build, utunws.yml), pins
# them, waits for the checks again, moves the branch to main, publishes the release with zapret.dmg, signs
# the archive (build/release.sh) and updates Homebrew. It stops on any error: run it again and it goes on
# from the step where it stopped.
# Needs: gh logged in to the project's account, the signing key (build/release.sh), a section of the
# version in CHANGELOG.md and CHANGELOG.en.md.

set -euo pipefail

v=${1:?версия, например 3.3.0}
R=slow-ball/zapret-macos
TAP=slow-ball/homebrew-tap
ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

# GitHub from some networks drops connections now and then: every call gets a few tries
retry()
{
	local i
	for i in 1 2 3 4 5 6; do "$@" && return 0; sleep $((i * 5)); done
	return 1
}

# waits for a workflow on a commit; a job GitHub cancelled for lack of runners is started again
wait_ci()
{
	local wf=$1 sha=$2 id st reruns=0
	while true; do
		id=$(retry gh run list -R $R --workflow "$wf" --commit "$sha" --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null || true)
		if [ -z "$id" ]; then sleep 20; continue; fi
		st=$(retry gh run view "$id" -R $R --json status,conclusion -q '.status+" "+.conclusion')
		case "$st" in
			"completed success") echo "  ✓ $wf"; return 0 ;;
			completed*)
				jobs=$(retry gh run view "$id" -R $R --json jobs -q '.jobs[] | .name+"="+.conclusion')
				if printf '%s\n' "$jobs" | grep -q '=failure$'; then
					die "$wf не прошёл: https://github.com/$R/actions/runs/$id"
				fi
				# Apple Silicon jobs GitHub never started don't hold a release: the rest must have passed
				if ! printf '%s\n' "$jobs" | grep -vE '^e2e \(macos-(14|15|26)\)=' | grep -vq '=success$'; then
					echo "  ✓ $wf (без Apple Silicon: GitHub не дал раннеры)"
					return 0
				fi
				# macOS runners of GitHub are scarce at times: a few tries, a minute apart
				[ $reruns -lt 8 ] || die "$wf: GitHub восемь раз не дал раннер, запустить позже"
				reruns=$((reruns + 1))
				echo "  · $wf: GitHub отменил задачу без раннера, перезапускаю ($reruns)"
				retry gh run rerun "$id" -R $R --failed >/dev/null
				sleep 60
				;;
			*) sleep 30 ;;
		esac
	done
}

push_and_wait()
{
	retry git push -q origin HEAD
	local sha
	sha=$(git rev-parse HEAD)
	wait_ci check.yml "$sha"
	wait_ci e2e.yml "$sha"
}

# the mac must not sleep halfway: the signing key is here (on battery a closed lid still wins)
caffeinate -ims -w $$ &

say "Проверки перед релизом"
[[ $v =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "не похоже на версию: $v"
branch=$(git rev-parse --abbrev-ref HEAD)
[ "$branch" != main ] || die "запускать из ветки с работой, не из main"
if ! git diff --quiet || ! git diff --cached --quiet; then die "есть незакоммиченные изменения"; fi
[ "$(git config user.email)" = "346082081+slow-ball@users.noreply.github.com" ] || die "git: не та учётная запись"
retry gh auth status 2>&1 | grep -A1 "account slow-ball" | grep -q "Active account: true" || die "gh: активен не slow-ball"
[ -f "${ZAPRET_RELEASE_KEY:-$HOME/.config/zapret-release/key}" ] || die "нет ключа подписи"
retry gh secret list -R $R | grep -q '^PACK_KEY' || die "в репозитории нет секрета PACK_KEY для свежих стратегий"
grep -qx "## $v" CHANGELOG.md || die "в CHANGELOG.md нет раздела ## $v"
grep -qx "## $v" CHANGELOG.en.md || die "в CHANGELOG.en.md нет раздела ## $v"
retry git fetch -q origin
# nothing personal in what goes out: no local paths, no foreign co-author lines
if git log origin/main..HEAD --format='%B' | grep -qi '^co-authored-by:' ||
	git diff origin/main..HEAD | grep -qF "$HOME"; then
	die "в коммитах ветки есть Co-Authored-By или локальный путь"
fi
tests/unit.sh </dev/null >/dev/null || die "модульные тесты не прошли"
python3 -I -m unittest discover -s tests >/dev/null 2>&1 || die "тесты Python не прошли"
# shellcheck source=build/sdk.sh
. build/sdk.sh
if ! xcrun swiftc -sdk "$(app_sdk)" -parse-as-library -swift-version 5 -D TESTING app/Sources/*.swift tests/AppTests.swift -o "$TMP/apptests" 2>/dev/null ||
	! "$TMP/apptests" >/dev/null; then
	die "тесты приложения не прошли"
fi
echo "  ✓ всё готово к $v"
[ "${2:-}" = --check ] && exit 0

say "1. Версия $v"
if [ "$(cat src/VERSION)" != "$v" ]; then
	echo "$v" > src/VERSION
	git commit -qam "$v"
fi
push_and_wait

say "2. Приложение"
last=$(retry gh release list -R $R --limit 100 --json tagName -q '.[].tagName' | sed -n 's/^utunws-//p' | sort -n | tail -1)
tag=$(sed -n 's/^APPTAG=\([^ ]*\).*/\1/p' src/zapret.sh)
built=""
# a build of this very commit may be there from a stopped run
if [ "$tag" = "utunws-$last" ] && git log -1 --format=%s | grep -qx "Приложение $v"; then
	built=1
fi
if [ -z "$built" ]; then
	n=$((last + 1))
	retry gh workflow run utunws.yml -R $R --ref "$branch" -f number=$n
	sleep 20
	id=$(retry gh run list -R $R --workflow utunws.yml --limit 1 --json databaseId -q '.[0].databaseId')
	until st=$(retry gh run view "$id" -R $R --json status,conclusion -q '.status+" "+.conclusion') && [[ $st == completed* ]]; do sleep 30; done
	[ "$st" = "completed success" ] || die "сборка приложения не прошла: https://github.com/$R/actions/runs/$id"
	retry gh run view "$id" -R $R --log > "$TMP/build.log"
	sha=$(sed -n 's/.*Z APP_SHA256=\([0-9a-f]\{64\}\).*/\1/p' "$TMP/build.log" | head -1)
	nsha=$(sed -n 's/.*Z NQ_SHA256=\([0-9a-f]\{64\}\).*/\1/p' "$TMP/build.log" | head -1)
	[ -n "$sha" ] && [ -n "$nsha" ] || die "не нашёл NQ_SHA256 и APP_SHA256 в логе сборки"
	# the engine of engine/ and the app of this very commit
	sed -i '' -e "s/^APPTAG=utunws-[0-9]* /APPTAG=utunws-$n /" -e "s/^APPSHA256=.*/APPSHA256=$sha/" \
		-e "s/^NQ_TAG=utunws-[0-9]* /NQ_TAG=utunws-$n /" -e "s/^NQ_SHA256=.*/NQ_SHA256=$nsha/" src/zapret.sh
	git commit -qam "Приложение $v"
	echo "  ✓ utunws-$n"
	push_and_wait
fi
tag=$(sed -n 's/^APPTAG=\([^ ]*\).*/\1/p' src/zapret.sh)

say "3. main"
# straight from the branch: main may be checked out in another worktree
retry git fetch -q origin main
git merge-base --is-ancestor origin/main HEAD || die "в main есть коммиты, которых нет в $branch: сначала влить main"
retry git push -q origin HEAD:main
git fetch -q origin main:main 2>/dev/null || true
echo "  ✓ main = $(git rev-parse --short HEAD)"

say "4. Релиз v$v"
retry gh release download "$tag" -R $R -p zapret.dmg -D "$TMP"
dmg=$(shasum -a 256 "$TMP/zapret.dmg" | cut -d' ' -f1)
# a draft first, everything into it, published last: nobody sees a release without its dmg or signature.
# a stopped run finds its draft and goes on
state=$(retry gh release list -R $R --limit 100 --json tagName,isDraft \
	-q ".[] | select(.tagName == \"v$v\") | if .isDraft then \"draft\" else \"published\" end")
if [ -z "$state" ]; then
	git tag -f "v$v"
	retry git push -q origin "refs/tags/v$v"
	awk -v h="## $v" '$0 == h { f = 1; next } /^## / { f = 0 } f' CHANGELOG.md > "$TMP/notes.md"
	retry gh release create "v$v" -R $R -t "$v" -F "$TMP/notes.md" --draft >/dev/null
	state=draft
fi
# a draft from a stopped run is resumed only for this very commit: anything else would publish old files
if [ "$state" = draft ] && [ "$(git ls-remote origin "refs/tags/v$v" | cut -f1)" != "$(git rev-parse HEAD)" ]; then
	die "черновик v$v — от другого коммита: удалить его и тег v$v на GitHub, затем запустить снова"
fi
if [ "$state" = draft ]; then
	has() { gh release view "v$v" -R $R --json assets -q ".assets[] | select(.name == \"$1\" and .state == \"uploaded\") | .name" | grep -q .; }
	# a slow uplink takes minutes for the dmg: gh is given the time, retries only start it again
	has zapret.dmg || retry gh release upload "v$v" -R $R "$TMP/zapret.dmg" --clobber
	{ has "zapret-macos-$v.tar.gz" && has "zapret-macos-$v.tar.gz.sig"; } || retry build/release.sh "$v" </dev/null
	retry gh release edit "v$v" -R $R --draft=false --latest >/dev/null
	echo "  ✓ опубликован"
fi
say "5. Homebrew"
retry gh repo clone $TAP "$TMP/tap" -- -q
(
	cd "$TMP/tap"
	git config user.name slow-ball
	git config user.email 346082081+slow-ball@users.noreply.github.com
	sed -i '' -E -e "s/version \"[^\"]+\"/version \"$v\"/" -e "s/sha256 \"[0-9a-f]{64}\"/sha256 \"$dmg\"/" Casks/zapret.rb
	if ! git diff --quiet; then
		git commit -qam "zapret $v"
		retry git push -q
	fi
)
sleep 15
until st=$(retry gh run list -R $TAP --limit 1 --json status,conclusion -q '.[0] | .status+" "+.conclusion') && [[ $st == completed* ]]; do sleep 20; done
[ "$st" = "completed success" ] || die "проверка Homebrew не прошла: https://github.com/$TAP/actions"

say "Готово: https://github.com/$R/releases/tag/v$v"
echo "Ветку $branch можно удалить (из папки проекта): cd \"$ROOT\" && git push origin --delete $branch"
