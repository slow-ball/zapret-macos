# shellcheck shell=bash
# zapret.sh: diagnostics. Sourced by src/zapret.sh, which defines the constants.

# with diag --tags: a fix for the line above, as a button in the app (see fixes in Model.swift)
hint() { [ "$DIAG_TAGS" = 1 ] && echo "    @fix $1"; return 0; }

# a big upload to a site that isn't blocked, through the running engine (as nobody, like any app): the provider
# freezes a connection to foreign hosting it can't name after its first ~16 KB — what a trick on every site does
upload_ok()
{
	local f code
	f=$(mktemp /tmp/zapret-upload.XXXXXX)
	head -c 262144 /dev/urandom > "$f"
	chmod 644 "$f"
	code=$(sudo -u nobody curl -s -o /dev/null -m 10 -X POST --data-binary @"$f" -w '%{http_code}' https://speed.cloudflare.com/__up)
	rm -f "$f"
	[ "$code" = 200 ]
}

cmd_diag()
{
	need_root diag "$@"
	[ "$1" = --tags ] && DIAG_TAGS=1
	local u p rv
	echo "${B}zapret-macos $VERSION${N}, macOS $(sw_vers -productVersion), $(uname -m)"
	echo

	echo "${B}zapret${N}"
	if installed; then ok "установлен"; else bad "не установлен — запустить zapret.command"; fi
	if running; then ok "работает, стратегия: %s" "$(current)"; else bad "не запущен"; hint start; fi
	if nfqws_installed; then ok "движок nfqws (%s)" "$NQ_TAG"; else bad "движок nfqws не установлен — перезапустить стратегию"; hint restart; fi
	if autostart_on; then ok "автозапуск включён"; else warn "автозапуск выключен"; fi
	if watchdog_on; then ok "автопочинка включена"; else say "  %s· автопочинка выключена%s" "${D}" "${N}"; fi
	if autoupdate_on; then ok "автообновление включено"; else say "  %s· автообновление выключено%s" "${D}" "${N}"; fi
	if telegram_on; then
		if ! telegram_running; then
			bad "прокси для Telegram не запущен — включить заново"; hint telegram
		elif telegram_test >/dev/null 2>&1; then
			ok "Telegram отвечает через прокси (127.0.0.1:%s)" "$(telegram_port)"
		else
			bad "прокси для Telegram запущен, но Telegram через него не отвечает"; hint telegram
			telegram_paths
		fi
		flowseal_tg_running && { warn "запущено приложение TG WS Proxy — его лучше закрыть, прокси уже встроен"; hint quit-flowseal; }
	fi
	case "$(scope)" in
		all)   ok "обрабатываются все сайты" ;;
		smart) ok "умный режим: найдено сайтов %s, своих стратегий %s" "$(count_entries "$AUTO_LIST")" "$(count_entries "$SITES")" ;;
		*)     ok "обрабатываются YouTube, Discord и свои списки" ;;
	esac
	if pfctl -s info 2>/dev/null | grep -q 'Status: Enabled'; then ok "файрвол pf включён"; else bad "файрвол pf выключен — перезапустить стратегию"; hint restart; fi
	if pfctl -a $NQ_ANCHOR -s rules 2>/dev/null | grep -q route-to; then
		ok "трафик заворачивается в nfqws (utun50)"
	elif running; then
		bad "правила pf для nfqws не загружены — перезапустить стратегию"; hint restart
	fi
	echo

	say "%sСеть%s" "${B}" "${N}"
	if vpn_active; then warn "включён VPN — пока он работает, zapret не участвует"; else ok "VPN не обнаружен"; fi
	if scutil --proxy | grep -qE '(HTTP|HTTPS|SOCKS)Enable : 1'; then
		warn "в системе настроен прокси — трафик может идти мимо zapret"; hint proxy-settings
	else
		ok "системный прокси не настроен"
	fi
	if running && ! vpn_active; then
		if upload_ok; then
			ok "большие загрузки на зарубежные сайты проходят"
		elif [ "$(scope)" = all ]; then
			bad "загрузки на зарубежные сайты зависают: режим «Все сайты» прячет и незаблокированные сайты"; hint smart
		else
			bad "загрузки на зарубежные сайты зависают"
		fi
	fi
	for p in spoofdpi ciadpi byedpi goodbyedpi warp-svc sing-box xray v2ray mihomo clash hiddify nekoray; do
		pgrep -qix "$p" && { warn "запущен %s — может конфликтовать с zapret" "$p"; hint monitor; }
	done
	if ifconfig | grep -q 'inet6 2[0-9a-f]*:'; then
		if [ "$(cat /var/run/zapret-macos.nfqws-ipv6 2>/dev/null)" = 1 ]; then
			ok "есть IPv6 — nfqws обрабатывает и его"
		else
			ok "есть IPv6 — nfqws его не обрабатывает, сайты открываются по IPv4"
		fi
	fi
	u=$(dig +short +time=2 +tries=1 www.youtube.com 2>/dev/null | grep -E '^[0-9.]+$' | tail -1)
	case "$u" in
		"") warn "DNS не ответил на www.youtube.com" ;;
		0.0.0.0|127.*|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) bad "DNS подменяет YouTube (%s) — указать 1.1.1.1 / 8.8.8.8 в настройках сети" "$u"; hint dns ;;
		*) ok "DNS отвечает нормально (%s)" "$u" ;;
	esac
	echo

	say "%sДоступность (как в браузере)%s" "${B}" "${N}"
	for p in https://www.youtube.com/ https://redirector.googlevideo.com/generate_204 https://discord.com/; do
		if as_user curl -s -o /dev/null -m 8 "$p"; then ok "%s" "$p"; else bad "%s" "$p"; hint check; fi
	done
	if stun_ok user; then ok "голос Discord (UDP, STUN)"; else bad "голос Discord (UDP, STUN) — подобрать стратегию"; hint check; fi
	echo

	rv=$(remote_version)
	if newer "$rv" "$VERSION"; then warn "доступно обновление: %s" "$rv"; hint update; elif [ -n "$rv" ]; then ok "последняя версия"; fi
	echo

	say "%sБраузеры%s %s(если YouTube всё равно тормозит — и перезапустить браузер)%s" "${B}" "${N}" "${D}" "${N}"
	if [ -d "/Applications/Google Chrome.app" ]; then
		say "  · Chrome: выключить «Безопасный DNS» (Настройки → Конфиденциальность → Безопасность)"; hint chrome-dns
		say "  · Chrome: выключить QUIC (chrome://flags/#enable-quic → Disabled)"; hint chrome-quic
	fi
	say "  · Safari: выключить iCloud Private Relay"; hint relay
}
