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
			if telegram_on && telegram_running && launchctl print system/$TG_LABEL >/dev/null 2>&1; then
				ok "прокси для Telegram уже работает: 127.0.0.1:%s" "$(telegram_port)"
				return 0
			fi
			telegram_install || die "Прокси для Telegram не установлен"
			# one secret for good: Telegram keeps the proxy it was given
			[ -s "$d/secret" ] || od -An -N16 -tx1 /dev/urandom | tr -d ' \n' > "$d/secret"
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
			touch /var/log/zapret-macos-telegram.log
			chown nobody /var/log/zapret-macos-telegram.log
			cat > "$TG_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$TG_LABEL</string>
	<key>ProgramArguments</key><array>
		<string>$TG_BIN</string><string>serve</string><string>$(cat "$d/port")</string><string>$(cat "$d/secret")</string>
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
