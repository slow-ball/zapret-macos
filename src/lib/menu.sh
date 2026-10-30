# shellcheck shell=bash
# zapret.sh: status / menu. Sourced by src/zapret.sh, which defines the constants.

# entries in a list file (no comments and empty lines), 0 if there is no file
count_entries() { awk '!/^[[:space:]]*(#|$)/ { n++ } END { print n + 0 }' "$1" 2>/dev/null || echo 0; }

# JSON string: "value" with quotes and backslashes escaped
jstr() { local v=${1//\\/\\\\}; v=${v//\"/\\\"}; printf '"%s"' "$v"; }
jbool() { if "$@"; then echo true; else echo false; fi; }

cmd_status()
{
	if [ "$1" = --json ]; then
		local cur tr tc=false ta=true
		cur=$(current)
		tr=$(jbool telegram_running)
		[ "$tr" = true ] && tc=$(jbool telegram_connected) ta=$(jbool telegram_reachable)
		printf '{"version":%s,"previous":%s,"installed":%s,"running":%s,"strategy":%s,"engine":"nfqws","scope":%s,"game":%s,' \
			"$(jstr "$VERSION")" "$(jstr "$(previous_version)")" "$(jbool installed)" "$(jbool running)" "$(jstr "$cur")" \
			"$(jstr "$(scope)")" "$(jstr "$(game_mode)")"
		printf '"telegram":%s,"telegramRunning":%s,"telegramConnected":%s,"telegramReachable":%s,"telegramLink":%s,"flowsealTelegram":%s,' \
			"$(jbool telegram_on)" "$tr" "$tc" "$ta" "$(jstr "$(telegram_on && telegram_link)")" \
			"$(jbool flowseal_tg_running)"
		printf '"pack":%s,"packOn":%s,"ladder":%s,"videoQuic":%s,' "$(jstr "$(pack_active && pack_stamp)")" "$(jbool packs_on)" \
			"$(count_entries "$LADDER_STATE")" "$(jbool video_quic)"
		printf '"autostart":%s,"autofix":%s,"autoupdate":%s,"vpn":%s,"ipv6":%s,"found":%s,"sites":%s,"project":%s}\n' \
			"$(jbool autostart_on)" "$(jbool watchdog_on)" "$(jbool autoupdate_on)" "$(jbool vpn_active)" \
			"$(jbool [ "$(cat /var/run/zapret-macos.nfqws-ipv6 2>/dev/null)" = 1 ])" \
			"$(count_entries "$AUTO_LIST")" "$(count_entries "$SITES")" "$(jstr "$PROJECT")"
		return
	fi
	local on off
	on=$(msg "вкл"); off=$(msg "выкл")
	if running; then say "%s●%s работает: %s" "${G}" "${N}" "${B}$(current)${N}"; else say "%s●%s остановлен" "${R}" "${N}"; fi
	if telegram_on; then
		if telegram_running && ! telegram_reachable; then say "  Telegram: прокси не достаёт до Telegram"
		elif telegram_running && telegram_connected; then say "  Telegram: подключён через прокси"
		elif telegram_running; then say "  Telegram: прокси работает"; else say "  Telegram: прокси не отвечает"; fi
	fi
	say "  сайты: %s · игры: %s · автозапуск: %s · автопочинка: %s · автообновление: %s · приложение: %s" \
		"$(scope_name)" "$(game_name)" \
		"$(autostart_on && echo "$on" || echo "$off")" \
		"$(watchdog_on && echo "$on" || echo "$off")" "$(autoupdate_on && echo "$on" || echo "$off")" \
		"$(app_installed && msg "есть" || msg "нет")"
}

pick_strategy()
{
	local names=() n i=0 c cur first_own
	cur=$(current)
	first_own=$(own_names | head -1)
	while IFS= read -r n; do names+=("$n"); done < <(strategy_names)
	for n in "${names[@]}"; do
		i=$((i + 1))
		[ $i = 1 ] && say "  %sWindows-версия%s %s— стратегии Flowseal%s" "${B}" "${N}" "${D}" "${N}"
		[ "$n" = "$first_own" ] && say "  %smacOS%s %s— свои стратегии и найденные глубоким подбором%s" "${B}" "${N}" "${D}" "${N}"
		if [ "$n" = "$cur" ]; then say "  %2d) %s %s(сейчас)%s" $i "$n" "${G}" "${N}"; else printf "  %2d) %s\n" $i "$n"; fi
	done
	read -r -p "$(msg "Номер: ")" c
	[[ "$c" =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le ${#names[@]} ] && cmd_start "${names[$((c - 1))]}"
}

lists_menu()
{
	local c
	say "  1) Открыть мои списки (list-user.txt, list-exclude-user.txt)"
	say "  2) Показать найденные сайты"
	say "  3) Подобрать стратегии для найденных сайтов"
	say "  4) Очистить найденные сайты"
	read -r -p "$(msg "Номер: ")" c
	echo
	case "$c" in
		1) as_user open -t "$PROJECT/lists/list-user.txt" "$PROJECT/lists/list-exclude-user.txt"
		   say "Открыты list-user.txt и list-exclude-user.txt. После правки — перезапустить стратегию (пункт 1)." ;;
		2) cmd_found ;;
		3) cmd_learn ;;
		4) cmd_found clear ;;
	esac
}

cmd_menu()
{
	need_root
	local rv c upd=""
	rv=$(remote_version)
	newer "$rv" "$VERSION" && upd=" ${Y}$(msg "(доступно обновление %s)" "$rv")${N}"
	while true; do
		echo
		echo "${B}zapret-macos $VERSION${N}$upd"
		cmd_status
		echo
		say "  1) Запустить / сменить стратегию"
		say "  2) Остановить"
		say "  3) Подобрать стратегию автоматически"
		say "  4) Диагностика"
		say "  5) Автозапуск при загрузке: вкл/выкл"
		say "  6) Автопочинка (сама меняет стратегию, если YouTube отвалился): вкл/выкл"
		say "  7) Приложение zapret (иконка в строке меню): установить или обновить"
		say "  8) Сайты: все / умный / только YouTube, Discord и свои списки"
		say "  9) Списки доменов и найденные сайты"
		say " 10) Обновить"
		say " 11) Вернуть предыдущую версию%s" "$(p=$(previous_version) && echo " ($p)")"
		say " 12) Удалить zapret"
		say " 13) Игровой фильтр: %s" "$(game_name)"
		say " 14) Автообновление (раз в сутки): вкл/выкл"
		say " 15) Прокси для Telegram: %s" "$(telegram_on && msg "вкл" || msg "выкл")"
		say "  0) Выход"
		read -r -p "> " c
		echo
		case "$c" in
			1) pick_strategy ;;
			2) cmd_stop ;;
			3) cmd_check ;;
			4) cmd_diag ;;
			5) cmd_autostart ;;
			6) cmd_watchdog ;;
			7) cmd_app ;;
			8) cmd_scope ;;
			9) lists_menu ;;
			10) cmd_update; upd="" ;;
			11) if p=$(previous_version); then cmd_update --to "$p"; else say "Предыдущей версии нет"; fi ;;
			12) cmd_uninstall; installed || exit 0 ;;
			13) cmd_game ;;
			14) cmd_autoupdate ;;
			15) cmd_telegram ;;
			0|"") exit 0 ;;
		esac
	done
}

usage()
{
	if [ "$UI" = en ]; then
		cat <<EOF
zapret-macos $VERSION

  zapret.sh                      the menu (installs on the first run)
  zapret.sh install              install zapret and start nfqws general
  zapret.sh start [name]         start a strategy (the current one by default)
  zapret.sh stop                 stop
  zapret.sh status               the state
  zapret.sh list                 the strategies
  zapret.sh check [--auto] [--all] [--quick]
                                 find a strategy: the likely ones first, up to a good one
                                 (--all — check them all and take the fastest,
                                 --auto — apply without asking, --quick — only the Windows version's)
  zapret.sh diag                 diagnostics
  zapret.sh dns                  use DNS 1.1.1.1 / 8.8.8.8 for the active connection
  zapret.sh dns webshift|dnsai|off|status
                                 encrypted DNS for neural networks and services closed to Russia
  zapret.sh autostart [on|off]   start at boot
  zapret.sh watchdog [on|off]    self-repair
  zapret.sh autoupdate [on|off]  update once a day
  zapret.sh telegram [on|off|restart|link|test]
                                 the proxy for Telegram Desktop; link — the link to connect,
                                 test — check that Telegram answers through the proxy
  zapret.sh app                  install the zapret app into Applications
  zapret.sh scope [all|smart|lists]
                                 all sites, smart mode, or only YouTube, Discord and your lists
  zapret.sh found [clear]        the sites smart mode found
  zapret.sh site <address>       a site doesn't open: why, its own strategy, a check
  zapret.sh sites-check          why your own and the found sites don't open — all at once
  zapret.sh deep [address]       deep search for a site (5–15 minutes), YouTube by default
  zapret.sh game [off|tcp|udp|all]
                                 the game filter (ports 1024–65535)
  zapret.sh learn [--all|site…]  find strategies for the found sites
  zapret.sh ladder               sites the adaptive strategy moved and their tricks
  zapret.sh video tcp|quic       YouTube video over TCP (the adaptive strategy tunes its speed) or QUIC
  zapret.sh update [--to version] update to the latest release or go back to the previous one
  zapret.sh repair               restore the services, rules and sudo (after a macOS update)
  zapret.sh reset                reset the strategy, modes and what was found (your lists and settings stay)
  zapret.sh pack [update|on|off|status]
                                 fresh strategies of the Windows version without updating zapret (a signed pack)
  zapret.sh uninstall [--yes]    remove zapret (--yes — without asking)
EOF
		return
	fi
	cat <<EOF
zapret-macos $VERSION

  zapret.sh                      меню (при первом запуске — установка)
  zapret.sh install              установить zapret и запустить nfqws general
  zapret.sh start [имя]          запустить стратегию (по умолчанию — текущую)
  zapret.sh stop                 остановить
  zapret.sh status               состояние
  zapret.sh list                 список стратегий
  zapret.sh check [--auto] [--all] [--quick]
                                 подобрать стратегию: сначала вероятные, до первой хорошей
                                 (--all — проверить все и выбрать самую быструю,
                                 --auto — применить без вопроса, --quick — только Windows-версии)
  zapret.sh diag                 диагностика
  zapret.sh dns                  поставить DNS 1.1.1.1 / 8.8.8.8 для активного подключения
  zapret.sh dns webshift|dnsai|off|status
                                 зашифрованный DNS для нейросетей и закрытых для России сервисов
  zapret.sh autostart [on|off]   автозапуск при загрузке
  zapret.sh watchdog [on|off]    автопочинка
  zapret.sh autoupdate [on|off]  автообновление раз в сутки
  zapret.sh telegram [on|off|restart|link|test]
                                 прокси для Telegram Desktop; link — ссылка для подключения,
                                 test — проверить, что Telegram отвечает через прокси
  zapret.sh app                  установить приложение zapret в «Программы»
  zapret.sh scope [all|smart|lists]
                                 все сайты, умный режим или только YouTube, Discord и свои списки
  zapret.sh found [clear]        сайты, найденные умным режимом
  zapret.sh site <адрес>         сайт не открывается: почему, своя стратегия, проверка
  zapret.sh sites-check          почему не открываются свои и найденные сайты — все разом
  zapret.sh deep [адрес]         глубокий подбор для сайта (5–15 минут), по умолчанию YouTube
  zapret.sh game [off|tcp|udp|all]
                                 игровой фильтр (порты 1024–65535)
  zapret.sh learn [--all|сайт…]  подобрать стратегию для найденных сайтов
  zapret.sh ladder               сайты, которые адаптивная перевела на другой приём
  zapret.sh video tcp|quic       видео YouTube по TCP (адаптивная подбирает скорость) или по QUIC
  zapret.sh update [--to версия] обновить до последнего релиза или вернуть предыдущую
  zapret.sh repair               восстановить службы, правила и sudo (после обновления macOS)
  zapret.sh reset                сбросить стратегию, режимы и найденное (свои списки и настройки остаются)
  zapret.sh pack [update|on|off|status]
                                 свежие стратегии Windows-версии без обновления zapret (подписанный пакет)
  zapret.sh uninstall [--yes]    удалить zapret (--yes — без вопроса)
EOF
}
