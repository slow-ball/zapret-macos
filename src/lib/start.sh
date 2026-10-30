# shellcheck shell=bash
# zapret.sh: install / apply. Sourced by src/zapret.sh, which defines the constants.

cmd_install()
{
	need_root install "$@"
	# files from a browser-downloaded ZIP are quarantined; one approval of zapret.command is enough
	xattr -dr com.apple.quarantine "$PROJECT" 2>/dev/null
	sync_runtime
	nfqws_install || die "Не удалось установить движок nfqws"
	ok "zapret установлен в %s" "$RT"
	cmd_start "$DEFAULT_STRATEGY" || exit 1
	set_autostart on
	# it looks after itself from the start: both can be turned off in Settings
	touch "$RT/autofix" "$RT/autoupdate"
	# --no-app: the installation runs from the app itself
	[ "$1" = --no-app ] && return 0
	cmd_app || say "  %sПриложение можно поставить позже, пункт меню 7.%s" "${D}" "${N}"
}

cmd_start()
{
	need_root start "$@"
	installed || [ "$SRC" != "$RT" ] || die "zapret не установлен. Запустить zapret.command"
	local name=$1 auto=off
	sync_runtime
	background_job
	trim_logs
	[ -n "$name" ] || name=$(current)
	# a strategy that is gone (a new Windows version dropped it) gives way to the default one
	if ! known_name "$name"; then
		[ -n "$name" ] && warn "стратегии «%s» больше нет — включаю «%s»" "$name" "$DEFAULT_STRATEGY"
		name=$DEFAULT_STRATEGY
	fi
	autostart_on && auto=on
	write_lists
	nfqws_install || die "Движок nfqws не установлен"
	nfqws_conf "$name" "$RT/nfqws.conf" || die "Нет стратегии «%s»" "$name"
	local r=0
	nfqws_dry_run "$RT/nfqws.conf" || r=$?
	# killed by macOS (137): the binary was overwritten while it ran, a fresh copy starts again
	if [ $r = 137 ]; then
		log "$(msg "start: движок убит системой, ставлю заново")"
		rm -f "$RT/nfqws/bin/VERSION"
		nfqws_install >/dev/null && { nfqws_dry_run "$RT/nfqws.conf"; r=$?; }
	fi
	[ $r = 0 ] || die "nfqws не принимает стратегию «%s»" "$name"
	# one line, even if a name had more: the app and the scripts read the first
	printf '%s\n' "$name" | head -1 > "$CURRENT"
	rm -f "$RT/stopped"

	local started=1
	if nfqws_reload; then
		started=0
	else
		nfqws_stop
		nfqws_launch && running && started=0
	fi
	set_autostart $auto
	# the Telegram proxy is on but its service is gone: bring it back
	if telegram_on && ! telegram_running; then cmd_telegram on >/dev/null; fi
	if [ $started = 0 ]; then
		ok "zapret запущен: %s%s%s" "${B}" "$name" "${N}"
		say "  %sПерезапустить браузер (Cmd+Q), чтобы сбросились старые соединения.%s" "${D}" "${N}"
		notify "$(msg "Запущен: %s" "$name")"
		log "start $name"
	else
		bad "zapret не запустился. Подробности — в диагностике."
		notify "$(msg "Не удалось запустить")"
		log "$(msg "start %s: не запустился" "$name")"
		return 1
	fi
}

cmd_stop()
{
	need_root stop
	nfqws_stop
	touch "$RT/stopped"
	if running; then
		bad "zapret всё ещё работает"
	else
		ok "zapret остановлен"
		notify "$(msg "Остановлен")"
		log stop
	fi
}

# all sites, smart (lists + sites found blocked) or only YouTube, Discord and the user's list
cmd_scope()
{
	need_root scope "$@"
	local s=$1 c
	if [ -z "$s" ]; then
		say "  1) Все сайты, кроме исключений"
		say "  2) Умный: YouTube, Discord, свои списки и сайты, которые не открылись без обхода"
		say "  3) Только YouTube, Discord и свои списки"
		read -r -p "$(msg "Номер: ")" c
		case "$c" in 1) s=all ;; 2) s=smart ;; 3) s=lists ;; *) return 0 ;; esac
	fi
	case "$s" in
		all)   rm -f "$RT/scope"; ok "zapret обрабатывает все сайты (кроме исключений)" ;;
		smart) mkdir -p "$RT"; echo smart > "$RT/scope"
		       ok "умный режим: сайт, который дважды не открылся, сам попадает в обработку" ;;
		lists) mkdir -p "$RT"; echo lists > "$RT/scope"; ok "zapret обрабатывает только YouTube, Discord и свои списки" ;;
		*)     die "scope: all, smart или lists" ;;
	esac
	if running; then cmd_start; fi
}

# the adaptive strategy: YouTube video over TCP (default) or QUIC. the speed of QUIC can't be measured (curl
# of macOS has none), over TCP the ladder measures and tunes it: QUIC to the video servers is dropped, the
# browser falls back to TCP at once
video_quic() { [ -f "$RT/video-quic" ]; }
cmd_video()
{
	case "$1" in
		tcp) need_root video "$@"; rm -f "$RT/video-quic" ;;
		quic) need_root video "$@"; mkdir -p "$RT"; touch "$RT/video-quic" ;;
		status | "") if video_quic; then say "видео YouTube: QUIC"; else say "видео YouTube: TCP"; fi; return 0 ;;
		*) die "video: tcp или quic" ;;
	esac
	if video_quic; then ok "видео YouTube: QUIC"; else ok "видео YouTube: TCP"; fi
	if running && adaptive_on; then cmd_start; fi
}

cmd_game()
{
	need_root game "$@"
	local g=$1 c
	if [ -z "$g" ]; then
		say "  Обход для игр, как Game Filter в Windows-версии: порты 1024–65535 серверов игр и облаков."
			say "  1) Выключить   2) TCP   3) UDP   4) TCP и UDP"
		read -r -p "$(msg "Номер: ")" c
		case "$c" in 1) g=off ;; 2) g=tcp ;; 3) g=udp ;; 4) g=all ;; *) return 0 ;; esac
	fi
	case "$g" in
		off) rm -f "$RT/game" ;;
		tcp|udp|all) mkdir -p "$RT"; echo "$g" > "$RT/game" ;;
		*) die "game: off, tcp, udp или all" ;;
	esac
	ok "игровой фильтр: %s" "$(game_name)"
	if running; then cmd_start; fi
}
