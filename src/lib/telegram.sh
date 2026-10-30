# shellcheck shell=bash
# zapret.sh: Telegram: local MTProto proxy (our zapret-tg, engine/tg). Sourced by src/zapret.sh, which defines the constants.

# Telegram Desktop connects to it as to an MTProto proxy, and it carries the traffic over WebSocket
# to Telegram's web servers. it runs as nobody: it needs neither root nor anything of the user
telegram_on()      { [ -f "$RT/telegram/on" ]; }
telegram_port()    { local p; p=$(cat "$RT/telegram/port" 2>/dev/null); echo "${p:-1443}"; }
telegram_running() { pgrep -qf -- "zapret-tg serve $(telegram_port) "; }
telegram_link()    { echo "tg://proxy?server=127.0.0.1&port=$(telegram_port)&secret=dd$(cat "$RT/telegram/secret" 2>/dev/null)"; }
# Telegram (Desktop or the App Store one) holds a connection to the proxy: it is already set up there.
# the caller knows the proxy runs; lsof only while Telegram does: the app asks every few seconds
telegram_connected() { pgrep -qx Telegram && lsof -a -nP -c Telegram -iTCP:"$(telegram_port)" -sTCP:ESTABLISHED -t >/dev/null 2>&1; }
# 32 hex digits from the id of this Mac: the same after a reinstall, different on every Mac
telegram_secret()
{
	local id
	id=$(ioreg -rd1 -c IOPlatformExpertDevice 2>/dev/null | awk -F'"' '/IOPlatformUUID/ { print $4 }')
	[ -n "$id" ] || id=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
	printf 'zapret-macos telegram %s' "$id" | shasum -a 256 | cut -c1-32
}

# Telegram answers through the proxy, as the proxy itself saw it last (State in engine/tg): a failure newer than
# the last success and of the last five minutes is "no" — Telegram Desktop may well be connected to a proxy
# that can't reach Telegram. nothing seen yet is "yes"
telegram_reachable()
{
	[ -s "$TG_STATE" ] || return 0
	awk -v now="$(date +%s)" '$1 == "ok" { ok = $2 } $1 == "fail" { fail = $2 }
		END { exit !(fail + 0 <= ok + 0 || now - fail > 300) }' "$TG_STATE"
}
# Flowseal's own app listens on 1443 too
flowseal_tg_running() { pgrep -qx TgWsProxy; }

# the whole path: a handshake like Telegram Desktop's through the proxy, an answer from Telegram
telegram_test()
{
	"$TG_BIN" check 127.0.0.1 "$(telegram_port)" "$(cat "$RT/telegram/secret")" 2
}

# the proxy is our own (engine/tg, zapret-tg): it comes with the engine, checked by the same pinned checksum
telegram_install()
{
	nfqws_install || return 1
	[ -x "$TG_BIN" ] || { bad "в движке нет прокси для Telegram"; return 1; }
	telegram_relays
	return 0
}

# the proxy runs but doesn't reach Telegram (telegram_reachable) and a test agrees: once more with a fresh list of
# relays. a failure that stays is told once an hour, with where to look
telegram_repair()
{
	telegram_on && telegram_running && ! telegram_reachable || return 0
	telegram_test >/dev/null 2>&1 && return 0
	log "$(msg "watchdog: прокси не достаёт до Telegram — обновляю посредников и перезапускаю")"
	telegram_relays
	if running; then write_lists; nfqws_reload >/dev/null; fi
	launchctl kickstart -k system/$TG_LABEL >/dev/null 2>&1
	sleep 3
	telegram_test >/dev/null 2>&1 && return 0
	[ -n "$(find "$RT/telegram/notified" -mmin -60 2>/dev/null)" ] && return 0
	touch "$RT/telegram/notified"
	notify "$(msg "Telegram не отвечает через прокси — подробности в «Проверке»")"
}

# where the way to Telegram breaks, for diagnostics: every way of the proxy, tried as the proxy goes (as nobody,
# through the engine) — Telegram's own addresses, the relays, the data center itself
telegram_paths()
{
	local out d r n c
	out=$(sudo -u nobody "$TG_BIN" paths 2 2>/dev/null)
	d=$(grep -c '^ok direct' <<<"$out")
	r=$(grep -c '^ok relay' <<<"$out")
	n=$(grep -c ' relay ' <<<"$out")
	c=$(grep -c '^ok dc' <<<"$out")
	say "    %sадреса Telegram: %s · посредники: %s из %s · дата-центр напрямую: %s%s" "${D}" \
		"$(if [ "$d" -gt 0 ]; then msg "открыты"; else msg "закрыты"; fi)" "$r" "$n" \
		"$(if [ "$c" -gt 0 ]; then msg "открыт"; else msg "закрыт"; fi)" "${N}"
}

# the relays of tg-ws-proxy's community on Cloudflare, fresh: where a provider blocks the addresses of Telegram
# they are the way there. kept next to the proxy; the proxy has its own list if this one can't be had
telegram_relays()
{
	local tmp
	tmp=$(mktemp)
	if curl -fsSL -m 15 -o "$tmp" "https://raw.githubusercontent.com/Flowseal/tg-ws-proxy/main/.github/cfproxy-domains.txt" &&
		[ "$(grep -cxE '[a-z0-9.-]+\.com' "$tmp")" -ge 3 ] && ! grep -vqxE '[a-z0-9.-]+\.com|#.*|' "$tmp"; then
		cp "$tmp" "$(dirname "$TG_BIN")/cf-domains.txt"
		chmod 644 "$(dirname "$TG_BIN")/cf-domains.txt"
	fi
	rm -f "$tmp"
	return 0
}

cmd_telegram()
{
	local d=$RT/telegram
	case "$1" in
		on)
			need_root telegram on
			# one at a time: two runs at once unload each other's service
			mkdir /var/run/zapret-macos.telegram.lock 2>/dev/null || die "Прокси для Telegram уже включается"
			trap 'rmdir /var/run/zapret-macos.telegram.lock 2>/dev/null' EXIT
			sync_runtime
			# a service of an older release has no state file: it is set up again
			if telegram_on && telegram_running && launchctl print system/$TG_LABEL >/dev/null 2>&1 &&
				grep -qF "$TG_STATE" "$TG_PLIST" 2>/dev/null; then
				ok "прокси для Telegram уже работает: 127.0.0.1:%s" "$(telegram_port)"
				return 0
			fi
			telegram_install || die "Прокси для Telegram не установлен"
			# the engine leaves the relays alone (write_lists): a fresh list of them is read again
			if running; then write_lists; nfqws_reload >/dev/null; fi
			# one secret for good: Telegram keeps the proxy it was given. made from this Mac's own id, so a
			# reinstall gives the same one and the proxy Telegram has keeps working
			[ -s "$d/secret" ] || telegram_secret > "$d/secret"
			chmod 644 "$d/secret"
			# the first free port of 1443-1453: another proxy (Flowseal's app) may hold 1443.
			# bootout returns before the job is gone, and bootstrap of a job still there fails
			launchctl bootout system/$TG_LABEL 2>/dev/null
			local p i
			for i in $(seq 25); do launchctl print system/$TG_LABEL >/dev/null 2>&1 || break; sleep 0.2; done
			for p in $(seq 1443 1453); do
				lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1 || break
			done
			echo "$p" > "$d/port"
			[ "$p" != 1443 ] && warn "порт 1443 занят%s — прокси на порту %s" "$(flowseal_tg_running && say " приложением TG WS Proxy")" "$p"
			touch /var/log/zapret-macos-telegram.log "$TG_STATE"
			chown nobody /var/log/zapret-macos-telegram.log "$TG_STATE"
			cat > "$TG_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$TG_LABEL</string>
	<key>ProgramArguments</key><array>
		<string>$TG_BIN</string><string>serve</string><string>$(cat "$d/port")</string><string>$(cat "$d/secret")</string>
		<string>$TG_STATE</string>
	</array>
	<key>UserName</key><string>nobody</string>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><true/>
	<key>ThrottleInterval</key><integer>5</integer>
	<key>StandardErrorPath</key><string>/var/log/zapret-macos-telegram.log</string>
</dict>
</plist>
EOF
			launchctl bootstrap system "$TG_PLIST" || die "Не удалось запустить прокси"
			touch "$d/on"
			# the process appears before it listens on the port
			for i in $(seq 50); do
				telegram_running && nc -z 127.0.0.1 "$(telegram_port)" 2>/dev/null && break
				sleep 0.2
			done
			if telegram_running; then
				ok "прокси для Telegram работает: 127.0.0.1:%s" "$(telegram_port)"
				say "  Подключить Telegram Desktop — открыть ссылку (или кнопка в приложении):"
				echo "  $(telegram_link)"
				log "telegram on"
			else
				bad "прокси не запустился, подробности: /var/log/zapret-macos-telegram.log"
				return 1
			fi
			;;
		off)
			need_root telegram off
			launchctl bootout system/$TG_LABEL 2>/dev/null
			rm -f "$TG_PLIST" "$d/on"
			ok "прокси для Telegram выключен"
			log "telegram off"
			;;
		restart)
			# a running proxy that doesn't reach Telegram: a fresh list of relays, the service from scratch
			need_root telegram restart
			local i
			telegram_on || die "Прокси для Telegram выключен"
			launchctl print system/$TG_LABEL >/dev/null 2>&1 || { cmd_telegram on; return; }
			telegram_relays
			if running; then write_lists; nfqws_reload >/dev/null; fi
			launchctl kickstart -k system/$TG_LABEL >/dev/null 2>&1
			for i in $(seq 50); do nc -z 127.0.0.1 "$(telegram_port)" 2>/dev/null && break; sleep 0.2; done
			if telegram_test >/dev/null 2>&1; then
				ok "Telegram отвечает через прокси"
			else
				bad "Telegram не ответил через прокси"
				return 1
			fi
			log "telegram restart"
			;;
		link)
			telegram_link
			;;
		test)
			telegram_running || die "Прокси для Telegram не запущен"
			if telegram_test; then
				ok "Telegram отвечает через прокси"
			else
				bad "Telegram не ответил через прокси"
				vpn_active || running || say "  zapret остановлен: без него провайдер может резать соединения прокси"
				return 1
			fi
			;;
		*)
			if telegram_on; then cmd_telegram off; else cmd_telegram on; fi
			;;
	esac
}
