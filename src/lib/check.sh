# shellcheck shell=bash
# zapret.sh: check (strategy search). Sourced by src/zapret.sh, which defines the constants.

# true if a strategy ($1 name, $2 bytes/s, $3 voice 0/1) beats the best one so far ($4 name, $5, $6).
# voice wins; speeds are noisy, so among equals the earlier stays unless another is clearly faster,
# and the Windows version's strategies beat our own unless ours is clearly faster
better()
{
	[ -z "$4" ] && return 0
	[ "$3" -gt "$6" ] && return 0
	[ "$3" = "$6" ] || return 1
	[ "$2" -gt $(($5 * 3 / 2)) ] && return 0
	is_windows "$1" && ! is_windows "$4" && [ $(($2 * 3 / 2)) -ge "$5" ]
}

# the order of a check: the running strategy, then the ones that passed last time, then the rest.
# $1: the names to order, one per line
check_order()
{
	local cur all
	cur=$(current)
	all=$(cat)
	{
		[ -n "$cur" ] && printf '%s\n' "$cur"
		[ -f "$WORKED" ] && cat "$WORKED"
		printf '%s\n' "$all"
	} | ALL=$all awk 'BEGIN { n = split(ENVIRON["ALL"], a, "\n"); for (i = 1; i <= n; i++) ok[a[i]] = 1 }
		$0 != "" && ok[$0] && !seen[$0]++'
}

# good enough to stop looking: everything opens, voice works, YouTube faster than 1 MB/s.
# $1 passed/total, $2 bytes/s, $3 voice
good_enough() { [ "${1%/*}" = "${1#*/}" ] && [ "$3" = 1 ] && [ "$2" -ge 1048576 ]; }

# every strategy runs for real, one by one, and is tested as nobody through pf: the running zapret is
# stopped for that time and comes back afterwards. the likely ones go first and the search stops at
# a good one (good_enough), usually in seconds. --all: every strategy, the fastest wins.
# --quick: only the Windows version's strategies
cmd_check()
{
	need_root check "$@"
	installed || die "zapret не установлен. Запустить zapret.command"
	local auto=0 quiet=0 quick=0 json=0 full=0 a
	for a in "$@"; do
		case "$a" in
			--auto) auto=1 ;;
			--quiet) quiet=1; auto=1 ;;
			--quick) quick=1 ;;
			--all) full=1 ;;
			# events for the app instead of text; applies the best strategy itself
			--json) json=1; quiet=1; auto=1 ;;
		esac
	done
	if vpn_active; then
		event error message "$(msg "Включён VPN — его нужно выключить")"
		[ $quiet = 1 ] && return 1
		die "Включён VPN — его нужно выключить, иначе проверка покажет не провайдера, а VPN."
	fi

	local tmp names=() name base vbase=0 voice
	if [ $quick = 1 ]; then
		while IFS= read -r name; do names+=("$name"); done < <(windows_names | check_order)
	else
		while IFS= read -r name; do names+=("$name"); done < <(strategy_names | check_order)
	fi
	event start total "${#names[@]}"
	[ $quiet = 1 ] || say "%sПроверка без zapret…%s" "${B}" "${N}"
	tmp=$(mktemp -d)
	( stun_ok "" && touch "$tmp/voice" ) &
	base=$(probe_base)
	wait
	[ -f "$tmp/voice" ] && vbase=1
	[ $quiet = 1 ] || say "  открылось %s, голос Discord %s" "$base" "$([ $vbase = 1 ] && echo ✓ || echo ✗)"
	event base pass "$base" voice "$vbase"

	local best="" best_speed=-1 best_voice=-1 res pass yt worked=() failed=()
	consider()
	{
		local v
		[ "$4" = 1 ] && v="$(msg "голос ✓")" || v="$(msg "голос ✗")"
		[ $quiet = 1 ] || ok "%-36s %s  %5s КБ/с  %s" "$1" "$2" $(($3 / 1024)) "$v"
		event result name "$1" ok 1 pass "$2" kbps "$(($3 / 1024))" voice "$4"
		worked+=("$3 $1")
		if better "$1" "$3" "$4" "$best" "$best_speed" "$best_voice"; then
			best=$1; best_speed=$3; best_voice=$4
		fi
	}

	local was was_running=0
	was=$(current)
	running && was_running=1
	sync_runtime
	write_lists >/dev/null
	if [ $quiet = 1 ]; then nfqws_install >/dev/null; else nfqws_install; fi || die "Движок nfqws не установлен"
	[ $quiet = 1 ] || { echo; say "%sСтратегии проверяются по очереди, интернет на это время может пропадать…%s" "${B}" "${N}"; }
	nfqws_stop
	# shellcheck disable=SC2064
	trap "nfqws_untry; rm -rf '$tmp'; [ $was_running = 1 ] && '$SELF' start '$was' >/dev/null; exit 130" INT TERM
	for name in "${names[@]}"; do
		nfqws_conf "$name" "$tmp/nq.conf" || continue
		if nfqws_try "$tmp/nq.conf"; then
			sleep 0.3
			res=$(probe user 1)
		else
			res="0/0 0"
		fi
		pass=${res% *}; yt=${res#* }
		voice=0
		if [ "${pass%/*}" = "${pass#*/}" ] && [ "${pass%/*}" != 0 ]; then
			stun_ok user && voice=1
		fi
		if [ "${pass%/*}" = "${pass#*/}" ] && [ "${pass%/*}" != 0 ]; then
			consider "$name" "$pass" "$yt" $voice
			if [ $full = 0 ] && good_enough "$pass" "$yt" $voice; then
				[ $quiet = 1 ] || say "  %s· подходит — дальше не ищу (все стратегии: check --all)%s" "${D}" "${N}"
				break
			fi
		else
			[ $quiet = 1 ] || echo "  ${D}✗ $(printf '%-36s %s' "$name" "$pass")${N}"
			event result name "$name" ok 0 pass "$pass"
			failed+=("$name")
		fi
	done
	nfqws_untry
	trap - INT TERM
	rm -rf "$tmp"
	# the next check starts with these, the fastest first. what failed now is out; a full check
	# forgets the rest
	{
		[ ${#worked[@]} -gt 0 ] && printf '%s\n' "${worked[@]}" | sort -rn | cut -d' ' -f2-
		[ $full = 0 ] && [ -f "$WORKED" ] && cat "$WORKED"
	} | FAILED=$(printf '%s\n' "${failed[@]}") awk 'BEGIN { n = split(ENVIRON["FAILED"], a, "\n"); for (i = 1; i <= n; i++) bad[a[i]] = 1 }
		$0 != "" && !bad[$0] && !seen[$0]++' > "$tmp.w"
	mv -f "$tmp.w" "$WORKED"

	if [ -z "$best" ]; then
		event finish best ""
		[ $quiet = 1 ] || { echo; bad "Ни одна стратегия не прошла все проверки."; say "  Можно создать Issue на GitHub и приложить этот вывод и вывод диагностики."; }
		[ $was_running = 1 ] && cmd_start "$was" >/dev/null
		return 1
	fi
	[ $quiet = 1 ] || { echo; say "Лучшая: %s%s%s (%s КБ/с, голос Discord %s)" "${B}" "$best" "${N}" "$((best_speed / 1024))" "$([ "$best_voice" = 1 ] && echo ✓ || echo ✗)"; }
	if [ $auto = 0 ]; then
		read -r -p "$(msg "Применить? [Y/n] ")" a
		case "$a" in
			n|N) [ $was_running = 1 ] && cmd_start "$was"; return 0 ;;
		esac
	fi
	if [ $quiet = 1 ]; then cmd_start "$best" >/dev/null; else cmd_start "$best"; fi
	log "check: $best"
	event finish best "$best" kbps "$((best_speed / 1024))" voice "$best_voice"
	# watchdog reads the chosen name from the last line
	[ $quiet = 1 ] && [ $json = 0 ] && echo "$best"
	return 0
}
