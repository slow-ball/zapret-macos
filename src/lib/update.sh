# shellcheck shell=bash
# zapret.sh: update / rollback / uninstall. Sourced by src/zapret.sh, which defines the constants.

# a version number, nothing else: it goes into a URL
valid_version() { [[ $1 =~ ^[0-9]+(\.[0-9]+){1,3}$ ]]; }

# the version that was installed before the last update: the app offers to go back to it
previous_version()
{
	local p
	p=$(cat "$RT/previous" 2>/dev/null)
	valid_version "$p" && [ "$p" != "$VERSION" ] && echo "$p"
}

# true if $2 is a signature of the file $1 made with a release key (build/release.sh)
verify_release()
{
	local keys r
	keys=$(mktemp)
	printf 'zapret %s\n' "$RELEASE_KEY" ${RELEASE_KEY_BACKUP:+"$RELEASE_KEY_BACKUP"} > "$keys"
	ssh-keygen -Y verify -f "$keys" -I zapret -n zapret-release -s "$2" < "$1" >/dev/null 2>&1
	r=$?
	rm -f "$keys"
	return $r
}

# installs the latest release; --to: the previous version (going back) or this one again (the files
# of /opt/zapret-macos differ from the release, see the integrity check of the app). no password is
# asked (sudoers): whoever runs it gets only a signed release, and no older one than the previous.
# a release is the archive build/release.sh attached to it, signed with the release key: whoever gets
# hold of the GitHub account still can't push code to the macs. tests set ZAPRET_UPDATE_REF to a
# commit and get its unsigned archive: only root can pass it, the sudoers rule allows no variables
cmd_update()
{
	need_root update "$@"
	local rv="" ref tmp src back=0 again=0
	if [ "$1" = --to ]; then
		valid_version "$2" || die "Не похоже на номер версии: %s" "$2"
		if [ "$2" = "$VERSION" ]; then
			again=1
		elif [ "$2" = "$(previous_version)" ]; then
			back=1
		else
			die "Вернуть можно только предыдущую версию"
		fi
		rv=$2
	elif [ -n "$ZAPRET_UPDATE_REF" ]; then
		rv=$(curl -fsSL -m 8 "https://raw.githubusercontent.com/$REPO/$ZAPRET_UPDATE_REF/src/VERSION" | head -1)
	else
		rv=$(remote_version)
	fi
	[ -n "$rv" ] || die "Не удалось проверить обновления (GitHub недоступен?)"
	if [ $back = 0 ] && [ $again = 0 ] && ! newer "$rv" "$VERSION"; then
		# the files are new but the root copy the app and services use may not be: the project
		# folder was replaced by hand, or an update stopped halfway
		if [ "$SRC" != "$RT" ] && [ "$(cat "$RT/VERSION" 2>/dev/null)" != "$VERSION" ]; then
			finish_update "$SELF"
			ok "Обновлено до %s" "$VERSION"
		else
			ok "Установлена последняя версия (%s)" "$VERSION"
		fi
		return
	fi
	if [ $again = 1 ]; then say "Переустанавливаю %s" "${B}$rv${N}"
	elif [ $back = 1 ]; then say "Возвращаю %s → %s" "$VERSION" "${B}$rv${N}"
	else say "Обновляю %s → %s" "$VERSION" "${B}$rv${N}"; fi
	# in /tmp: root's own temporary folder is closed to the user, who copies the files into the project
	tmp=$(mktemp -d /tmp/zapret-update.XXXXXX)
	if [ -n "$ZAPRET_UPDATE_REF" ]; then
		curl -fsSL -o "$tmp/u.tar.gz" "https://github.com/$REPO/archive/$ZAPRET_UPDATE_REF.tar.gz" || { rm -rf "$tmp"; die "Не удалось скачать %s" "$rv"; }
	else
		ref="https://github.com/$REPO/releases/download/v$rv/zapret-macos-$rv.tar.gz"
		if ! curl -fsSL -o "$tmp/u.tar.gz" "$ref" || ! curl -fsSL -o "$tmp/u.tar.gz.sig" "$ref.sig"; then
			rm -rf "$tmp"; die "Не удалось скачать %s" "$rv"
		fi
		if ! verify_release "$tmp/u.tar.gz" "$tmp/u.tar.gz.sig"; then
			rm -rf "$tmp"
			log "$(msg "update: подпись %s не совпала, обновление отменено" "$rv")"
			die "Подпись обновления %s не совпала — обновление отменено" "$rv"
		fi
	fi
	mkdir "$tmp/x"
	tar -xzf "$tmp/u.tar.gz" -C "$tmp/x" || { rm -rf "$tmp"; die "Не удалось распаковать"; }
	src=$(find "$tmp/x" -mindepth 1 -maxdepth 1 -type d | head -1)
	[ "$(cat "$src/src/VERSION" 2>/dev/null)" = "$rv" ] || { rm -rf "$tmp"; die "В загрузке не та версия"; }
	chmod -R go+rX "$tmp"
	if [ -d "$PROJECT/.git" ]; then
		as_user git -C "$PROJECT" pull --ff-only || die "git pull не удался"
	else
		# the user's own lists stay
		as_user rsync -a --exclude lists/list-user.txt --exclude lists/list-exclude-user.txt \
			"$src/" "$PROJECT/" || die "Не удалось обновить файлы"
	fi
	ok "Файлы обновлены"
	if [ $again = 0 ]; then
		echo "$VERSION" > "$RT/previous"
		# after going back the daily autoupdate leaves the version it came from alone
		if [ $back = 1 ]; then echo "$VERSION" > "$RT/skip-version"; else rm -f "$RT/skip-version"; fi
	fi
	log "update: $VERSION → $rv"
	# the new script runs from this download, never from the project folder: any program of the user
	# can change that one
	finish_update "$src/src/zapret.sh"
	rm -rf "$tmp"
}

# after new files: the root copy, the running strategy and the app follow them.
# done by the new script ($1): it knows the new version
finish_update()
{
	local new=$1
	if running; then
		say "Перезапускаю zapret…"
		ZAPRET_PROJECT="$PROJECT" "$new" start
	else
		# the root copy the app and launchd use must be new too
		ZAPRET_PROJECT="$PROJECT" "$new" sync
	fi
	app_installed && ZAPRET_PROJECT="$PROJECT" "$new" app --if-outdated
}

cmd_uninstall()
{
	need_root uninstall "$@"
	local a=y
	# --yes: confirmed elsewhere (the app asks itself)
	[ "$1" = --yes ] || read -r -p "$(msg "Удалить zapret полностью (службы, правила файрвола, %s)? [y/N] " "$RT")" a
	case "$a" in y|Y) ;; *) return ;; esac
	rm -f "$RT/autofix" "$RT/autoupdate"
	background_job off
	nfqws_stop
	rm -f "$NQ_PLIST" "$NQ_READY"
	launchctl bootout system/$TG_LABEL 2>/dev/null
	rm -f "$TG_PLIST"
	# the DNS for neural networks would stay in the system without the app that switches it off
	dns_remove_ours
	rm -f /etc/sudoers.d/zapret-macos
	rm -rf "$RT"
	ok "zapret удалён. Папку проекта можно удалить вручную."
}
