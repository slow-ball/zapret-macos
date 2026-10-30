# shellcheck shell=bash
# zapret.sh: the app. Sourced by src/zapret.sh, which defines the constants.

# installs zapret.app into /Applications: from the release, checked against the pinned checksum,
# or built from the project's sources (needs Command Line Tools)
cmd_app()
{
	if [ "$(id -u)" = 0 ]; then
		as_user "$SELF" app "$@"
		return
	fi
	local tmp ok=1 have
	if [ "$1" = --if-outdated ]; then
		have=$(defaults read /Applications/zapret.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null)
		[ "$have" = "$VERSION" ] && return 0
		say "Обновляю приложение: %s → %s" "${have:-?}" "$VERSION"
	fi
	tmp=$(mktemp -d)
	if [ -n "$APPSHA256" ]; then
		say "%sСкачиваю приложение…%s" "${B}" "${N}"
		if curl -fL --retry 3 --retry-delay 3 --retry-connrefused --progress-bar -o "$tmp/app.zip" "https://github.com/$REPO/releases/download/$APPTAG/zapret-app.zip" &&
			echo "$APPSHA256  $tmp/app.zip" | shasum -a 256 -c --status && ditto -x -k "$tmp/app.zip" "$tmp"; then
			ok=0
		else
			bad "Не удалось скачать приложение или контрольная сумма не совпала"
		fi
	elif xcrun --find swiftc >/dev/null 2>&1 && [ -x "$PROJECT/build/app.sh" ]; then
		say "%sСобираю приложение из исходников (около 20 секунд)…%s" "${B}" "${N}"
		if "$PROJECT/build/app.sh" "$tmp" >/dev/null 2>&1; then ok=0; else bad "Сборка не удалась"; fi
	else
		bad "Нужны Command Line Tools: выполнить xcode-select --install"
	fi
	if [ $ok = 0 ]; then
		osascript -e 'quit app "zapret"' >/dev/null 2>&1
		pkill -x zapret 2>/dev/null
		rm -rf /Applications/zapret.app
		ditto "$tmp/zapret.app" /Applications/zapret.app && xattr -dr com.apple.quarantine /Applications/zapret.app 2>/dev/null
		open /Applications/zapret.app
		ok "приложение zapret установлено и открыто — иконка в строке меню"
	fi
	rm -rf "$tmp"
	return $ok
}
