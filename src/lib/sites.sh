# shellcheck shell=bash
# zapret.sh: smart mode: found sites and per-site strategies. Sourced by src/zapret.sh, which defines the constants.

# true if https://$2 answers at all; $1: empty — as root, past the engine, "user" — as nobody, through
# pf and the running engine. $3: seconds to wait
site_ok()
{
	local run=() code size rc=0
	[ "$1" = user ] && run=(sudo -u nobody)
	# the line of curl and its exit code after it
	read -r code size rc < <("${run[@]}" curl -s -o /dev/null -m "${3:-6}" -w "%{http_code} %{size_download}" "https://$2/"; echo " $?")
	[ "${code:-000}" != 000 ] || return 1
	# an answer that stopped halfway is a provider letting the first kilobytes through and then stalling
	# the connection (~16 KB): the page must come whole, or at least past that
	[ "$rc" = 0 ] || [ "${size%.*}" -gt 65536 ] 2>/dev/null
}

# tests of options on one site (learn, deep). while zapret runs, they go live: the option is a profile
# for that site in front of the running strategy, and the service reads it on the fly, so the rest of
# the internet keeps working. a stopped zapret is tested in a test engine of its own. either way the
# setup comes back when the tests end, even if they are interrupted
tests_live() { running && [ -f "$NQ_READY" ] && launchctl print system/$NQ_LABEL >/dev/null 2>&1; }

tests_begin()
{
	TESTS_WAS=$(current)
	TESTS_RUNNING=0
	TESTS_LIVE=0
	running && TESTS_RUNNING=1
	tests_live && TESTS_LIVE=1
	TESTS_TMP=$(mktemp -d)
	if [ $TESTS_LIVE = 1 ]; then
		cp "$RT/nfqws.conf" "$TESTS_TMP/main.conf"
	else
		nfqws_stop
	fi
	trap 'tests_end; exit 130' INT TERM
}

tests_end()
{
	trap - INT TERM
	nfqws_untry
	# live: the running strategy without the test profile, with what learn and deep found
	if [ "$TESTS_LIVE" = 1 ] || [ "$TESTS_RUNNING" = 1 ]; then cmd_start "$TESTS_WAS" >/dev/null; fi
	rm -rf "$TESTS_TMP"
	TESTS_RUNNING=0
	TESTS_LIVE=0
}

# true if options $1 open https://$2
try_opts()
{
	local ok=1
	printf '%s\n' "$2" > "$TESTS_TMP/site.txt"
	nfqws_site_conf "$1" "$TESTS_TMP/site.txt" "$TESTS_TMP/t.conf"
	if [ "$TESTS_LIVE" = 1 ]; then
		{ cat "$TESTS_TMP/t.conf"; echo --new; cat "$TESTS_TMP/main.conf"; } > "$TESTS_TMP/live.conf"
		nfqws_dry_run "$TESTS_TMP/live.conf" || return 1
		cp "$TESTS_TMP/live.conf" "$RT/nfqws.conf"
		nfqws_reload || return 1
	else
		nfqws_dry_run "$TESTS_TMP/t.conf" || return 1
		nfqws_try "$TESTS_TMP/t.conf" || return 1
	fi
	sleep 0.2
	site_ok user "$2" 5 && ok=0
	return $ok
}

# looks for a strategy for sites the main one doesn't open. a site that opens as it is costs nothing;
# for the others every strategy is tried on them (see tests_begin).
# no arguments: found sites and the user's list that were not looked at yet; --all: all of them again.
# --live-only: only with live tests, never stopping zapret for everyone (the background search)
cmd_learn()
{
	need_root learn "$@"
	installed || die "zapret не установлен. Запустить zapret.command"
	local quiet=0 all=0 norestart=0 liveonly=0 a domains=() d need=() tp changed=0 had n so res seen=()
	for a in "$@"; do
		case "$a" in --quiet) quiet=1 ;; --all) all=1 ;; --live-only) liveonly=1 ;; --no-restart) norestart=1 ;; *) domains+=("$a") ;; esac
	done
	vpn_active && { [ $quiet = 1 ] && return 1; die "Включён VPN — его нужно выключить."; }
	touch "$SITES" "$SITES_TESTED"
	if [ ${#domains[@]} = 0 ]; then
		while IFS= read -r d; do
			[ $all = 1 ] || ! grep -qxF "$d" "$SITES_TESTED" && domains+=("$d")
		done < <({ cat "$AUTO_LIST" 2>/dev/null; echo; user_cat "$PROJECT/lists/list-user.txt"; } |
			grep -vE '^[[:space:]]*(#|$)' | tr -d '\r' | sort -u)
	fi
	if [ ${#domains[@]} = 0 ]; then
		[ $quiet = 1 ] || ok "Новых сайтов для подбора нет"
		return 0
	fi
	tp=$(mktemp)
	for d in "${domains[@]}"; do
		# only host names: they go into curl and into the lists nfqws reads
		[ -n "$(host_of "$d")" ] || continue
		# the old choice is dropped: the site is looked at from scratch
		had=0
		if awk -F'\t' -v d="$d" '$1 == d { f = 1 } END { exit !f }' "$SITES"; then
			awk -F'\t' -v d="$d" '$1 != d' "$SITES" > "$tp"; cat "$tp" > "$SITES"
			changed=1; had=1
		fi
		grep -qxF "$d" "$SITES_TESTED" || echo "$d" >> "$SITES_TESTED"
		if site_ok "" "$d"; then
			[ $quiet = 1 ] || say "  %s· %s — открывается и без обхода%s" "${D}" "$d" "${N}"
		# the running engine still has the dropped profile of the site
		elif running && [ $had = 0 ] && site_ok user "$d"; then
			[ $quiet = 1 ] || ok "%s — работает с основной стратегией" "$d"
		else
			need+=("$d")
		fi
	done
	rm -f "$tp"
	if [ ${#need[@]} -gt 0 ]; then
		if [ $quiet = 0 ]; then
			if tests_live; then say "%sПодбираю стратегии для %s сайтов, остальной интернет работает как обычно…%s" "${B}" "${#need[@]}" "${N}"
			else say "%sПодбираю стратегии для %s сайтов, интернет может ненадолго пропадать…%s" "${B}" "${#need[@]}" "${N}"; fi
		fi
		# the network may have changed while the sites were probed
		[ $liveonly = 1 ] && ! tests_live && return 0
		tests_begin
		for d in "${need[@]}"; do
			res=""
			seen=()
			while IFS= read -r n; do
				so=$(site_opts "$n")
				# many strategies share the options for HTTPS: each set is tried once
				[ -n "$so" ] || continue
				[[ " ${seen[*]} " == *" |$so| "* ]] && continue
				seen+=("|$so|")
				if try_opts "$so" "$d"; then res=$n; break; fi
			done < <(strategy_names)
			if [ -z "$res" ]; then
				[ $quiet = 1 ] || bad "%s — ни одна стратегия не помогла, попробовать глубокий подбор" "$d"
			else
				printf '%s\t%s\n' "$d" "$res" >> "$SITES"
				changed=1
				[ $quiet = 1 ] || ok "%s — своя стратегия: %s%s%s" "$d" "${B}" "$res" "${N}"
				log "learn: $d → $res"
			fi
		done
		# the main strategy comes back with the sites' profiles (a stopped test engine: unless the caller
		# restarts it itself)
		[ $norestart = 1 ] && TESTS_RUNNING=0
		tests_end
		return 0
	fi
	[ $changed = 1 ] || return 0
	if running && [ $norestart = 0 ]; then
		[ $quiet = 1 ] || say "Перезапускаю zapret со стратегиями для сайтов…"
		cmd_start >/dev/null && { [ $quiet = 1 ] || ok "готово"; }
	fi
	return 0
}

# addresses DNS stubs answer with: nothing, this computer, local networks
is_stub() { case "$1" in 0.0.0.0|127.*|10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*) return 0 ;; *) return 1 ;; esac; }

# the reason from one request to the site past zapret: $1 curl's exit code, $2 HTTP code, $3 seconds to
# connect, $4 where it redirects, $5 the start of the page. see site_reason
reason_of()
{
	local geo='unsupported.(country|region)|unavailable.in.(your.)?region|not.available.in.your.(country|region)|недоступ[а-я]* в ваш(ей|ем) (стране|регионе)'
	case "$1" in
		0)
			if printf '%s\n%s\n' "$4" "$5" | grep -qiE "$geo"; then echo geo
			elif [ "$2" = 451 ]; then echo geo
			else echo open; fi
			;;
		6) echo nodns ;;
		# refused, or no answer before the connection was even set up: the address itself is blocked
		7) echo ip ;;
		# a timeout before the connection was set up (0 seconds to connect) — the address; after — the name
		28) if awk -v t="${3:-0}" 'BEGIN { exit !(t + 0 == 0) }'; then echo ip; else echo dpi; fi ;;
		# the connection was there and died when the site's name went out: what zapret is for
		*) echo dpi ;;
	esac
}

# why https://$1 doesn't open, looked at past zapret (pf leaves root alone): open, geo (the service
# itself turns Russia away), dns (the provider's DNS answers with a stub), nodns (no such name),
# ip (the server's address is blocked), dpi (the connection dies after the site's name went out)
site_reason()
{
	local d=$1 sys pub body out rc=0 code t redirect
	sys=$(dig +short +time=2 +tries=1 "$d" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
	pub=$(dig +short +time=2 +tries=1 @1.1.1.1 "$d" A 2>/dev/null | grep -E '^[0-9.]+$' | head -1)
	if [ -z "$sys" ] && [ -z "$pub" ]; then echo nodns; return; fi
	if [ -n "$sys" ] && is_stub "$sys" && [ -n "$pub" ] && ! is_stub "$pub"; then echo dns; return; fi
	body=$(mktemp)
	out=$(curl -s -o "$body" -m 8 --connect-timeout 5 -w '%{http_code} %{time_connect} %{redirect_url}' "https://$d/") || rc=$?
	read -r code t redirect <<<"$out"
	reason_of "$rc" "$code" "$t" "$redirect" "$(head -c 65536 "$body" 2>/dev/null)"
	rm -f "$body"
}

# a site that doesn't open: first why (site_reason); for a block zapret can work around it goes into the
# user's list and gets its own strategy if the main one
# doesn't open it, and is checked the way a browser opens it. --json: the result for the app
cmd_site()
{
	need_root site "$@"
	local d json=0 added=0 direct=0 works=0 strategy list="$PROJECT/lists/list-user.txt"
	[ "$2" = --json ] && json=1
	# https://www.example.com/page → example.com (subdomains are covered anyway)
	d=$(host_of "$1")
	if [ -z "$d" ]; then
		[ $json = 1 ] && { echo "{\"error\":$(jstr "$(msg "Не похоже на адрес сайта")")}"; return 1; }
		die "Не похоже на адрес сайта: %s" "$1"
	fi
	local reason
	reason=$(site_reason "$d")
	[ "$reason" = open ] && direct=1
	# only a block of the site's name is zapret's job; for the rest a strategy can't help
	if [ "$reason" = dpi ]; then
		if ! user_cat "$list" | grep -qxF "$d"; then
			user_append "$list" "$d"
			added=1
		fi
		local was_running=0
		running && was_running=1
		cmd_learn --quiet --no-restart "$d" >/dev/null
		strategy=$(awk -F'\t' -v d="$d" '$1 == d { print $2; exit }' "$SITES" 2>/dev/null)
		# the lists changed: the engine reads them on start
		if [ $was_running = 1 ]; then cmd_start >/dev/null 2>&1; sleep 1; fi
	fi
	as_user curl -s -o /dev/null -m 8 "https://$d/" && works=1
	log "site $d: reason=$reason works=$works strategy=${strategy:-main}"
	if [ $json = 1 ]; then
		printf '{"site":%s,"reason":%s,"added":%s,"direct":%s,"works":%s,"strategy":%s,"dns":%s}\n' "$(jstr "$d")" "$(jstr "$reason")" \
			"$([ $added = 1 ] && echo true || echo false)" "$([ $direct = 1 ] && echo true || echo false)" \
			"$([ $works = 1 ] && echo true || echo false)" "$(jstr "$strategy")" "$(jstr "$(dns_active)")"
		return 0
	fi
	case "$reason" in
		dns)   warn "провайдер подменяет адрес %s — поставить DNS 1.1.1.1: zapret.sh dns" "$d" ;;
		nodns) bad "адреса %s нет: опечатка или сайт закрылся" "$d" ;;
		ip)    bad "заблокирован сам адрес сервера %s — подмена пакетов тут не поможет" "$d" ;;
		geo)   warn "%s сам не пускает из России — поможет DNS для нейросетей: zapret.sh dns dnsai" "$d" ;;
		open)  say "  %s· без обхода тоже открывается — значит, мешает не провайдер, а что-то ещё%s" "${D}" "${N}" ;;
	esac
	[ $added = 1 ] && ok "%s добавлен в свой список" "$d"
	[ -n "$strategy" ] && ok "для %s своя стратегия: %s%s%s" "$d" "${B}" "$strategy" "${N}"
	if [ $works = 1 ]; then ok "%s открывается" "$d"
	elif [ "$reason" = dpi ]; then bad "%s всё ещё не открывается — попробовать подобрать стратегию (пункт меню 3)" "$d"; fi
}

# the reason for every site of the user's list and the found ones, all at once (each takes seconds):
# --json: [{"site":…,"reason":…}], otherwise a line each. as root, past zapret, like site_reason
cmd_sites_check()
{
	need_root sites-check "$@"
	local d tmp n=0 first=1 r
	tmp=$(mktemp -d)
	while IFS= read -r d; do
		[ -n "$(host_of "$d")" ] || continue
		n=$((n + 1))
		# at most eight at once
		[ $((n % 8)) = 0 ] && wait
		( site_reason "$d" > "$tmp/$n"; echo "$d" > "$tmp/$n.site" ) &
	done < <({ user_cat "$PROJECT/lists/list-user.txt"; echo; cat "$AUTO_LIST" 2>/dev/null; } |
		grep -vE '^[[:space:]]*(#|$)' | tr -d '\r' | sort -u)
	wait
	[ "$1" = --json ] && printf '['
	for r in $(seq "$n"); do
		[ -f "$tmp/$r.site" ] || continue
		d=$(cat "$tmp/$r.site")
		if [ "$1" = --json ]; then
			[ $first = 1 ] || printf ','
			first=0
			printf '{"site":%s,"reason":%s}' "$(jstr "$d")" "$(jstr "$(cat "$tmp/$r")")"
		else
			printf '  %-40s %s\n' "$d" "$(cat "$tmp/$r")"
		fi
	done
	[ "$1" = --json ] && echo ']'
	rm -rf "$tmp"
	return 0
}

# options the deep search tries, the simple ones first. the same tricks as blockcheck of bol-van:
# splitting, disorder, fakes with different ways to make the DPI accept and the server drop them
deep_candidates()
{
	local p f r g=@BASE@/bin/tls_clienthello_www_google_com.bin
	for p in 1 2 midsld 1,midsld sniext+1 host+1 2,sniext+1 1,sniext+1,host+1,midsld,endhost-1; do
		echo "--dpi-desync=multisplit --dpi-desync-split-pos=$p"
		echo "--dpi-desync=multidisorder --dpi-desync-split-pos=$p"
	done
	for p in 1 2 midsld; do
		echo "--dpi-desync=multisplit --dpi-desync-split-pos=$p --dpi-desync-split-seqovl=1"
		echo "--dpi-desync=multisplit --dpi-desync-split-pos=1 --dpi-desync-split-seqovl=681 --dpi-desync-split-seqovl-pattern=$g"
	done | sort -u
	for f in ts badseq md5sig datanoack badsum; do
		for r in 1 6; do
			echo "--dpi-desync=fake --dpi-desync-fooling=$f --dpi-desync-repeats=$r --dpi-desync-fake-tls=$g"
			echo "--dpi-desync=fake --dpi-desync-fooling=$f --dpi-desync-repeats=$r --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com"
		done
		for p in 1 midsld 1,midsld; do
			echo "--dpi-desync=fake,multisplit --dpi-desync-split-pos=$p --dpi-desync-fooling=$f --dpi-desync-fake-tls=$g"
			echo "--dpi-desync=fake,multidisorder --dpi-desync-split-pos=$p --dpi-desync-fooling=$f --dpi-desync-fake-tls=$g"
			echo "--dpi-desync=fakedsplit --dpi-desync-split-pos=$p --dpi-desync-fooling=$f"
			echo "--dpi-desync=fakeddisorder --dpi-desync-split-pos=$p --dpi-desync-fooling=$f"
		done
		echo "--dpi-desync=hostfakesplit --dpi-desync-fooling=$f --dpi-desync-hostfakesplit-mod=host=www.google.com"
		echo "--dpi-desync=fake,hostfakesplit --dpi-desync-fooling=$f --dpi-desync-hostfakesplit-mod=host=www.google.com --dpi-desync-fake-tls=$g"
	done
}

# when no strategy helps: hundreds of options of the engine are tried on one site (5-15 minutes),
# and the first working one becomes the site's own strategy. --json: events for the app
cmd_deep()
{
	need_root deep "$@"
	local d=${1:-www.youtube.com} json=0 n=0 total o found="" name
	[ "$2" = --json ] && json=1
	d=$(host_of "$d")
	if [ -z "$d" ]; then
		event error message "$(msg "Не похоже на адрес сайта")"
		die "Не похоже на адрес сайта: %s" "$1"
	fi
	installed || die "zapret не установлен. Запустить zapret.command"
	vpn_active && { event error message "$(msg "Включён VPN — его нужно выключить")"; die "Включён VPN — его нужно выключить"; }
	total=$(deep_candidates | wc -l | tr -d ' ')
	event start site "$d" total "$total"
	if site_ok "" "$d"; then
		event finish strategy "" reason "open"
		[ $json = 1 ] || ok "%s открывается и без обхода — дело не в провайдере" "$d"
		return 0
	fi
	if [ $json = 0 ]; then
		if tests_live; then say "%sГлубокий подбор для %s: до %s вариантов, 5–15 минут, остальной интернет работает как обычно…%s" "${B}" "$d" "$total" "${N}"
		else say "%sГлубокий подбор для %s: до %s вариантов, 5–15 минут, интернет на это время может пропадать…%s" "${B}" "$d" "$total" "${N}"; fi
	fi
	sync_runtime
	write_lists
	tests_begin
	while IFS= read -r o; do
		n=$((n + 1))
		if [ $json = 1 ]; then event progress tested "$n" option "${o//@BASE@\/bin\//}"; else echo "  $n) ${o//@BASE@\/bin\//}"; fi
		if try_opts "$o" "$d"; then found=$o; break; fi
	done < <(deep_candidates)
	if [ -n "$found" ]; then
		name="$(msg "Глубокий подбор: %s" "$d")"
		touch "$DSTRATS"
		{ grep -vF "$name|" "$DSTRATS"; echo "$name|$found"; } > "$TESTS_TMP/d"
		install -m 644 -o root -g wheel "$TESTS_TMP/d" "$DSTRATS"
		awk -F'\t' -v d="$d" '$1 != d' "$SITES" 2>/dev/null > "$TESTS_TMP/s"
		printf '%s\t%s\n' "$d" "$name" >> "$TESTS_TMP/s"
		cat "$TESTS_TMP/s" > "$SITES"
		log "deep $d: $found"
	fi
	# the main strategy comes back, with the site's new profile
	tests_end
	if [ -n "$found" ]; then
		running || cmd_start >/dev/null
		event finish strategy "$name" options "$found"
		[ $json = 1 ] || ok "найдено: %s%s%s (%s) — работает для %s" "${B}" "$name" "${N}" "$found" "$d"
	else
		event finish strategy "" reason "none"
		[ $json = 1 ] || bad "ничего не нашлось: провайдер режет %s так, что подмена пакетов не помогает" "$d"
	fi
}

# shows or clears what the smart mode has found
# what the provider did to the sites, from the engine's log: site<TAB>rst (reset the connection),
# redirect (to a page of another domain) or silence (requests nobody answers), the last one of each
found_whys()
{
	# a line: time : site : profile N : client ip:port : proto tls : what happened
	awk -F' : ' '
		$6 == "incoming RST" { w[$2] = "rst" }
		$6 == "redirect to another domain" { w[$2] = "redirect" }
		$6 == "retrans threshold reached" { w[$2] = "silence" }
		END { for (d in w) print d "\t" w[d] }' "$AUTO_WHY" 2>/dev/null
}

# the same for one site, nothing if the log doesn't say
found_why() { found_whys | awk -F'\t' -v d="$1" '$1 == d { print $2 }'; }

# the engine only appends to its log: only the last reason of each site is kept, the counters go
auto_why_trim()
{
	[ "$(stat -f %z "$AUTO_WHY" 2>/dev/null || echo 0)" -gt 65536 ] || return 0
	awk -F' : ' '$6 ~ /^(incoming RST|redirect to another domain|retrans threshold reached)$/ { l[$2] = $0 }
		END { for (d in l) print l[d] }' "$AUTO_WHY" > "$AUTO_WHY.new" && cat "$AUTO_WHY.new" > "$AUTO_WHY"
	rm -f "$AUTO_WHY.new"
}

found_why_name()
{
	case "$1" in
		rst) msg "сброс соединения" ;;
		redirect) msg "переадресация на заглушку" ;;
		silence) msg "запросы без ответа" ;;
	esac
}

# the found sites in one pass: site, its own strategy, why (both may be empty), separated by \037:
# read splits on it without merging empty fields, as it does with tabs
found_table()
{
	awk -F'\t' -v OFS='\037' 'FILENAME == ARGV[1] { if (!($1 in s)) s[$1] = $2; next }
		FILENAME == ARGV[2] { w[$1] = $2; next }
		!/^[[:space:]]*(#|$)/ { sub(/\r$/, ""); print $1, s[$1], w[$1] }' \
		<(cat "$SITES" 2>/dev/null) <(found_whys) "$AUTO_LIST" 2>/dev/null
}

cmd_found()
{
	if [ "$1" = --json ]; then
		local d s w first=1
		printf '['
		while IFS=$'\037' read -r d s w; do
			[ $first = 1 ] || printf ','
			first=0
			printf '{"site":%s,"strategy":%s,"why":%s}' "$(jstr "$d")" "$(jstr "$s")" "$(jstr "$w")"
		done < <(found_table)
		echo ']'
		return
	fi
	if [ "$1" = clear ]; then
		need_root found clear
		: > "$AUTO_LIST"; : > "$SITES"; : > "$SITES_TESTED"; [ -f "$AUTO_WHY" ] && : > "$AUTO_WHY"; [ -f "$LADDER_STATE" ] && : > "$LADDER_STATE"; rm -f "$LADDER_RUNGS"
		ok "найденные сайты и стратегии для них очищены"
		if running; then cmd_start >/dev/null; fi
		return
	fi
	local d s w
	say "%sНайденные сайты%s %s(умный режим)%s" "${B}" "${N}" "${D}" "${N}"
	if [ -s "$AUTO_LIST" ]; then
		while IFS=$'\037' read -r d s w; do
			w=$(found_why_name "$w")
			echo "  $d${w:+  ${D}($w)${N}}${s:+  ${D}→ $s${N}}"
		done < <(found_table)
	else
		say "  %sпока ничего%s" "${D}" "${N}"
	fi
	if [ -s "$SITES" ]; then
		echo; say "%sСвои стратегии для сайтов%s" "${B}" "${N}"
		awk -F'\t' '{ printf "  %s → %s\n", $1, $2 }' "$SITES"
	fi
}
