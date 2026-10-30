# shellcheck shell=bash
# zapret.sh: autostart / watchdog. Sourced by src/zapret.sh, which defines the constants.

cmd_autostart()
{
	need_root autostart "$@"
	case "$1" in
		on)  set_autostart on && ok "автозапуск включён" ;;
		off) set_autostart off && ok "автозапуск выключен" ;;
		*)   if autostart_on; then cmd_autostart off; else cmd_autostart on; fi ;;
	esac
}

# installs the background job when autofix or autoupdate needs it and removes it otherwise
# the background job runs while zapret is installed: fresh strategies, the Telegram proxy, repair after a macOS
# update and smart mode's search need it whatever the switches; autofix and autoupdate check theirs inside.
# off: removed (uninstall)
background_job()
{
	if [ "$1" != off ] && installed; then
		[ -f "$WD_PLIST" ] && launchctl print system/$WD_LABEL >/dev/null 2>&1 && return 0
		cat > "$WD_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$WD_LABEL</string>
	<key>ProgramArguments</key><array><string>$RT/zapret.sh</string><string>watchdog</string><string>run</string></array>
	<key>StartInterval</key><integer>300</integer>
	<key>RunAtLoad</key><false/>
</dict>
</plist>
EOF
		launchctl bootout system/$WD_LABEL 2>/dev/null
		launchctl bootstrap system "$WD_PLIST"
	else
		launchctl bootout system/$WD_LABEL 2>/dev/null
		rm -f "$WD_PLIST"
	fi
}

cmd_watchdog()
{
	case "$1" in
		on)
			need_root watchdog on
			sync_runtime
			touch "$RT/autofix"
			background_job && ok "автопочинка включена: проверка каждые 5 минут"
			;;
		off)
			need_root watchdog off
			rm -f "$RT/autofix" "$RT/watchdog.fails"
			background_job
			ok "автопочинка выключена"
			;;
		run)
			watchdog_run
			;;
		*)
			if watchdog_on; then cmd_watchdog off; else cmd_watchdog on; fi
			;;
	esac
}

cmd_autoupdate()
{
	case "$1" in
		on)
			need_root autoupdate on
			sync_runtime
			touch "$RT/autoupdate"
			background_job && ok "автообновление включено: проверка раз в сутки"
			;;
		off)
			need_root autoupdate off
			rm -f "$RT/autoupdate"
			background_job
			ok "автообновление выключено"
			;;
		*)
			if autoupdate_on; then cmd_autoupdate off; else cmd_autoupdate on; fi
			;;
	esac
}

# once a day: a newer version is installed and the current strategy restarted with it.
# if the new strategies don't suit the provider, autofix picks another one
auto_update()
{
	local rv
	[ -n "$(find "$RT/update-checked" -mtime -1 2>/dev/null)" ] && return 0
	touch "$RT/update-checked"
	rv=$(remote_version)
	newer "$rv" "$VERSION" || return 0
	# the user went back from this version
	newer "$rv" "$(cat "$RT/skip-version" 2>/dev/null)" || return 0
	log "autoupdate: $VERSION → $rv"
	if cmd_update >/dev/null 2>&1; then
		notify "$(msg "Обновлено до %s" "$rv")"
	else
		log "$(msg "autoupdate: не удалось")"
	fi
}

# the background search (auto_learn) of a running watchdog: its pid in $LEARN_BG
learn_bg_running() { local p; p=$(cat "$LEARN_BG" 2>/dev/null) && [ -n "$p" ] && [ "$p" != $$ ] && kill -0 "$p" 2>/dev/null; }

# stops it: its trap puts the running strategy back (tests_end), waits for that up to 20 s
learn_bg_stop()
{
	local i
	learn_bg_running || { rm -f "$LEARN_BG"; return 0; }
	kill -TERM "$(cat "$LEARN_BG")" 2>/dev/null
	for i in $(seq 40); do learn_bg_running || break; sleep 0.5; done
	rm -f "$LEARN_BG"
}

# true if the engine found a site learn hasn't looked at yet (one learn takes: a host name)
untested_found()
{
	local d
	while IFS= read -r d; do
		[ -n "$(host_of "$d")" ] || continue
		grep -qxF "$d" "$SITES_TESTED" 2>/dev/null || return 0
	done < <(grep -vE '^[[:space:]]*(#|$)' "$AUTO_LIST" 2>/dev/null | tr -d '\r')
	return 1
}

# smart mode: a site the engine found blocked gets a strategy of its own in the background, while
# the internet works as usual (live tests only). at most every half hour
auto_learn()
{
	local before after
	[ "$(scope)" = smart ] || return 0
	[ -n "$(find "$RT/learn-auto" -mmin -30 2>/dev/null)" ] && return 0
	untested_found && tests_live || return 0
	learn_bg_running && return 0
	touch "$RT/learn-auto"
	echo $$ > "$LEARN_BG"
	before=$(count_entries "$SITES")
	cmd_learn --quiet --live-only >/dev/null 2>&1
	after=$(count_entries "$SITES")
	rm -f "$LEARN_BG"
	[ "$after" -gt "$before" ] && notify "$(msg "Умный режим подобрал стратегии для сайтов: %s" $((after - before)))"
	return 0
}

# fresh strategies of the Windows version, once a day, a release or not and whatever autoupdate says:
# a pack holds no code, only signed strategies and lists (pack.sh)
auto_pack()
{
	packs_on || return 0
	[ -n "$(find "$RT/pack-checked" -mtime -1 2>/dev/null)" ] && return 0
	touch "$RT/pack-checked"
	cmd_pack update >/dev/null 2>&1
	return 0
}

# the adaptive strategy, by hand: the rung of a key of ladder.txt (0 when it isn't there)
ladder_get() { awk -v k="$1" '$1 == k { r = $2 } END { print r + 0 }' "$LADDER_STATE" 2>/dev/null; }

# sets the rung $1 for the keys that follow (0: the bottom, the line goes); the engine reads the file
# again on nfqws_reload
ladder_set()
{
	local r=$1 k tmp
	shift
	tmp=$(mktemp)
	awk -v ks="$*" 'BEGIN { n = split(ks, a, " "); for (i = 1; i <= n; i++) drop[a[i]] = 1 } !($1 in drop)' \
		"$LADDER_STATE" 2>/dev/null > "$tmp"
	if [ "$r" -gt 0 ]; then for k in "$@"; do echo "$k $r" >> "$tmp"; done; fi
	cat "$tmp" > "$LADDER_STATE"
	rm -f "$tmp"
}

# bytes/s of $1 as the browser gets it (through pf and the engine), counted from the first byte: a long
# wait for the answer is latency, not a slowed transfer. 0 when it doesn't finish in 10 s (a provider that
# lets the first kilobytes through and then stalls the connection) or is shorter than $2 bytes.
# only TCP: curl of macOS has no QUIC, the QUIC ladder moves by its own failures
url_speed()
{
	local out
	out=$(sudo -u nobody curl -s -o /dev/null -m 10 -w '%{size_download} %{time_starttransfer} %{time_total}' "$1") ||
		{ echo 0; return; }
	awk -v m="$2" '{ if ($1 < m) { print 0; exit } d = $3 - $2; if (d < 0.05) d = 0.05; printf "%d\n", $1 / d }' <<<"$out"
}
yt_speed()      { url_speed https://www.youtube.com/ 300000; }
discord_speed() { url_speed https://discord.com/ 1; }
site_speed()    { url_speed "https://$SITE/" 1; }

# the sites used most (the engine counts their connections in ladder-seen.txt), seen in the last two days,
# without YouTube and Discord (they have checks of their own): at most $1, the busiest first
busy_sites()
{
	awk -v now="$(date +%s)" '$3 > now - 172800 { print $2, $1 }' "$LADDER_SEEN" 2>/dev/null | sort -rn |
		awk '{ print $2 }' |
		grep -vxE 'youtube\.com|(.+\.)?googlevideo\.com|ytimg\.com|discord\.com|discordapp\.com|discordapp\.net|discord\.gg|discord\.media' |
		head -"$1"
}

# bytes/s of the network itself, the same way and about the same size as the YouTube page: a megabyte of a
# domestic mirror, as root (pf leaves root alone)
net_speed()
{
	curl -s -o /dev/null -r 0-999999 -m 10 -w '%{size_download} %{time_starttransfer} %{time_total}' \
		https://mirror.yandex.ru/debian/ls-lR.gz | awk '{ d = $3 - $2; if (d < 0.05) d = 0.05; printf "%d\n", $1 / d }'
}

# tries the rungs after the current one for the keys ($4…), a speed measured by the function $1 on each,
# until it reaches $2; $3 is where it started. every other rung once at most, eight at most or $LADDER_TRIES
# (each try restarts the engine for a moment). the best one stays; nothing better — everything as it was, also when a user
# command stops this. true if it got better
ladder_search()
{
	local test=$1 want=$2 base=$3 size cur best best_s s i r
	shift 3
	size=$(grep -c . "$LADDER_RUNGS" 2>/dev/null)
	cur=$(ladder_get "$1")
	best=$cur best_s=$base
	cp "$LADDER_STATE" "$RT/ladder-before" 2>/dev/null || : > "$RT/ladder-before"
	trap 'cat "$RT/ladder-before" > "$LADDER_STATE"; nfqws_reload; rm -f "$LEARN_BG" "$RT/ladder-before"; exit 130' INT TERM
	for ((i = 1; i < size && i <= ${LADDER_TRIES:-8}; i++)); do
		r=$(((cur + i) % size))
		ladder_set "$r" "$@"
		nfqws_reload || break
		sleep 1
		s=$($test)
		[ "$s" -gt "$best_s" ] && best=$r best_s=$s
		[ "$s" -ge "$want" ] && break
	done
	if [ "$best" != "$cur" ]; then ladder_set "$best" "$@"; else cat "$RT/ladder-before" > "$LADDER_STATE"; fi
	nfqws_reload
	trap - INT TERM
	rm -f "$RT/ladder-before"
	LADDER_FOUND=$best LADDER_FOUND_SPEED=$best_s
	[ "$best" != "$cur" ]
}

# a quick start of the adaptive strategy (an install, a reset, a switch to it): YouTube and Discord get a trick
# that works right away, the whole ladder if need be, instead of waiting until the engine has seen enough failures
# to climb (several broken connections each). in the background: a user's command stops it like the other
# searches (learn_bg_stop), and everything is as it was
ladder_warmup()
{
	adaptive_on && tests_live && ! learn_bg_running || return 0
	echo $$ > "$LEARN_BG"
	if [ "$(yt_speed)" = 0 ] && LADDER_TRIES=32 ladder_search yt_speed 1 0 youtube.com googlevideo.com ytimg.com; then
		log "$(msg "адаптивная: YouTube на приёме %s" $((LADDER_FOUND + 1)))"
	fi
	if [ "$(discord_speed)" = 0 ] &&
		LADDER_TRIES=32 ladder_search discord_speed 1 0 discord.com discordapp.com discordapp.net discord.gg discord.media; then
		log "$(msg "адаптивная: Discord на приёме %s" $((LADDER_FOUND + 1)))"
	fi
	rm -f "$LEARN_BG"
}

# starts it apart from the command that switched (the app waits for that one): the root copy, detached
ladder_warmup_bg()
{
	[ -x "$RT/zapret.sh" ] || return 0
	nohup "$RT/zapret.sh" warmup </dev/null >/dev/null 2>&1 &
}

# the adaptive strategy on what the engine can't see: a page that stops halfway (the provider lets the
# first kilobytes through and then stalls the connection) — of YouTube, of Discord and of the sites used most.
# measured twice; then the rungs are tried right away. at most every half hour. slowing down is the engine's:
# it measures the speed every site really gets and moves it to a faster trick itself (ladder_sample)
auto_ladder_speed()
{
	local yt net d
	adaptive_on || return 0
	[ -n "$(find "$RT/ladder-speed" -mmin -30 2>/dev/null)" ] && return 0
	tests_live && ! learn_bg_running || return 0
	net=$(net_speed)
	# the network itself is slow or away: nothing a trick could fix
	[ "${net:-0}" -ge 524288 ] || return 0
	touch "$RT/ladder-speed"
	echo $$ > "$LEARN_BG"
	yt=$(yt_speed)
	if [ "$yt" = 0 ] && sleep 5 && [ "$(yt_speed)" = 0 ]; then
		log "$(msg "адаптивная: YouTube не загружается до конца — пробую другие приёмы")"
		if ladder_search yt_speed 1 0 youtube.com googlevideo.com ytimg.com; then
			log "$(msg "адаптивная: YouTube на приёме %s" $((LADDER_FOUND + 1)))"
			notify "$(msg "YouTube снова открывается — адаптивная нашла приём")"
		fi
	fi
	d=$(discord_speed)
	if [ "$d" = 0 ] && sleep 5 && [ "$(discord_speed)" = 0 ]; then
		log "$(msg "адаптивная: Discord не загружается до конца — пробую другие приёмы")"
		if ladder_search discord_speed 1 0 discord.com discordapp.com discordapp.net discord.gg discord.media; then
			log "$(msg "адаптивная: Discord на приёме %s" $((LADDER_FOUND + 1)))"
			notify "$(msg "Discord снова открывается — адаптивная нашла приём")"
		fi
	fi
	# the sites you use: a page that stops halfway gets a trick of its own. two searches a run at most
	local n=0
	for SITE in $(busy_sites 6); do
		[ "$(site_speed)" = 0 ] || continue
		sleep 3
		[ "$(site_speed)" = 0 ] || continue
		# not answering at all, without zapret too: down, or its address is blocked — no trick helps
		[ "$(curl -s -o /dev/null -m 8 -w '%{http_code}' "https://$SITE/")" = 000 ] && continue
		log "$(msg "адаптивная: %s не загружается до конца — пробую другие приёмы" "$SITE")"
		if ladder_search site_speed 1 0 "$SITE"; then
			log "$(msg "адаптивная: %s на приёме %s" "$SITE" $((LADDER_FOUND + 1)))"
		fi
		n=$((n + 1))
		[ $n -lt 2 ] || break
	done
	rm -f "$LEARN_BG"
	return 0
}

# the ladder learns from itself, once a day: the trick most sites settled on (three at least) moves to the
# bottom of the ladder, so a new site tries it first. the rungs of sites that climbed are renumbered with it;
# the sites that never had to climb start from the new first trick, and climb on if it doesn't suit them.
# the domains of one service count as one site: YouTube's (googlevideo.com, ytimg.com) and Discord's move
# together (auto_ladder_speed).
# the engine reads the new numbering right away (cmd_start): it writes the file only on a climb
auto_ladder_tune()
{
	local top cnt tmp
	adaptive_on && [ -s "$LADDER_RUNGS" ] && [ -s "$LADDER_STATE" ] || return 0
	[ -n "$(find "$RT/ladder-tuned" -mtime -1 2>/dev/null)" ] && return 0
	touch "$RT/ladder-tuned"
	# TCP keys only: their lines have no "quic:" and aren't "voice"
	read -r cnt top < <(awk '$1 ~ /^quic:/ || $1 == "voice" { next }
		{ site = $1
		  if (site ~ /(^|\.)googlevideo\.com$/ || site == "ytimg.com") site = "youtube.com"
		  if (site ~ /^(discordapp\.com|discordapp\.net|discord\.gg|discord\.media)$/) site = "discord.com"
		  if (!seen[site, $2]++) n[$2]++ }
		END { for (r in n) print n[r], r }' "$LADDER_STATE" | sort -rn | head -1)
	[ "${cnt:-0}" -ge 3 ] && [ "${top:-0}" -gt 0 ] || return 0
	tmp=$(mktemp)
	# the new order: that trick first, the others as they were
	{ sed -n "$((top + 1))p" "$LADDER_RUNGS"; awk -v t=$((top + 1)) 'NR != t' "$LADDER_RUNGS"; } > "$tmp.rungs"
	# old rung → new: the top one becomes 0, those below it move up by one
	awk -v t="$top" '$1 ~ /^quic:/ || $1 == "voice" { print; next }
		{ r = $2; if (r == t) r = 0; else if (r < t) r = r + 1; if (r > 0) print $1, r }' "$LADDER_STATE" > "$tmp"
	cat "$tmp.rungs" > "$LADDER_RUNGS"
	cat "$tmp" > "$LADDER_STATE"
	# how each rung does, renumbered the same way
	awk -v t="$top" '{ r = $1; if (r == t) r = 0; else if (r < t) r = r + 1; $1 = r; print }' "$LADDER_STATS" 2>/dev/null |
		sort -n > "$tmp"
	cat "$tmp" > "$LADDER_STATS" 2>/dev/null
	rm -f "$tmp" "$tmp.rungs"
	log "$(msg "адаптивная: приём, на котором остановилось сайтов: %s, — теперь первый" "$cnt")"
	cmd_start "$ADAPTIVE" >/dev/null 2>&1
	return 0
}

# once a day in "all sites" mode: uploads that freeze are told, with what fixes them (upload_ok)
auto_upload_check()
{
	[ "$(scope)" = all ] && running || return 0
	[ -n "$(find "$RT/upload-checked" -mtime -1 2>/dev/null)" ] && return 0
	touch "$RT/upload-checked"
	upload_ok && return 0
	log "$(msg "watchdog: загрузки на зарубежные сайты зависают в режиме «Все сайты»")"
	notify "$(msg "Загрузки на некоторые сайты зависают в режиме «Все сайты» — умный режим это исправит")"
}

# called by launchd as root every 5 minutes
watchdog_run()
{
	local fails new
	auto_why_trim
	auto_pack
	# a fresh list of blocked sites goes into the running engine
	if blocked_update && running && [ "$(scope)" = smart ]; then write_lists; nfqws_reload >/dev/null; fi
	# a macOS update may have reset what zapret set up
	[ "$(os_build)" = "$(cat "$RT/os-build" 2>/dev/null)" ] || cmd_repair --quiet
	# the project folder belongs to the user: update only while someone is logged in
	autoupdate_on && [ "$(stat -f %Su /dev/console)" != root ] && auto_update
	if telegram_on && ! telegram_running; then
		log "$(msg "watchdog: прокси для Telegram не работал, запускаю")"
		cmd_telegram on >/dev/null
	fi
	telegram_repair
	watchdog_on || return 0
	running || return 0
	vpn_active && return 0
	[ "$(stat -f %Su /dev/console)" = root ] && return 0
	# check the real path: as the user, through pf and the running engine
	if yt_answers https://www.youtube.com/ && yt_answers https://redirector.googlevideo.com/generate_204; then
		rm -f "$RT/watchdog.fails"
		auto_learn
		auto_ladder_speed
		auto_ladder_tune
		auto_ladder_evolve
		auto_upload_check
		return 0
	fi
	# no internet at all is not our problem
	curl -s -o /dev/null -m 8 https://www.apple.com/ || return 0
	fails=$(( $(cat "$RT/watchdog.fails" 2>/dev/null || echo 0) + 1 ))
	echo $fails > "$RT/watchdog.fails"
	log "$(msg "watchdog: YouTube недоступен (%s)" "$fails")"
	# the adaptive strategy: the ladder's search first, right away (auto_ladder_speed logs what it finds);
	# a full check would replace the strategy, so only when two searches didn't help
	if adaptive_on && [ $fails -lt 3 ]; then
		rm -f "$RT/ladder-speed"
		auto_ladder_speed
		return 0
	fi
	[ $fails -ge 2 ] || return 0
	rm -f "$RT/watchdog.fails"
	local old
	old=$(current)
	new=$(cmd_check --quiet | tail -1)
	if [ -n "$new" ] && [ "$new" != "$old" ]; then
		log "watchdog: $old → $new"
		notify "$(msg "«%s» перестала работать, включена «%s»" "$old" "$new")"
	elif [ -z "$new" ]; then
		log "$(msg "watchdog: рабочая стратегия не найдена")"
		notify "$(msg "YouTube недоступен, рабочая стратегия не найдена")"
	fi
}

# $1 answers through zapret: any HTTP answer counts, not the whole page — a provider that slows YouTube
# down lets a megabyte of it take longer than the check waits. a connection the provider loses (it drops
# one in several, with zapret or without) is tried once more
yt_answers()
{
	local i
	for i in 1 2; do
		[ "$(as_user curl -s -o /dev/null -m 8 -w '%{http_code}' "$1")" != 000 ] && return 0
	done
	return 1
}

os_build() { sw_vers -buildVersion 2>/dev/null; }

# after a macOS update (or anything else that broke the setup): puts back the sudoers rule, the
# services and the firewall rules, and starts zapret if it should run. the app calls it when the
# system's build changed, the background job does too. --json: what was fixed, for the app
cmd_repair()
{
	need_root repair "$@"
	installed || die "zapret не установлен. Запустить zapret.command"
	local json=0 quiet=0 fixed=() a i f=/etc/sudoers.d/zapret-macos
	local net=0
	for a in "$@"; do case "$a" in --json) json=1 ;; --quiet) quiet=1 ;; --net) net=1 ;; esac; done
	if ! visudo -c -q -f "$f" >/dev/null 2>&1; then
		install_sudoers
		fixed+=("$(msg "правило sudo для приложения")")
	fi
	if ! launchctl print system/$WD_LABEL >/dev/null 2>&1; then
		rm -f "$WD_PLIST"
		background_job
		fixed+=("$(msg "фоновая проверка")")
	fi
	# not when the user stopped it
	if [ -n "$(current)" ] && [ ! -f "$RT/stopped" ] && autostart_on && ! running && ! waiting; then
		cmd_start >/dev/null 2>&1 && fixed+=("$(msg "zapret запущен")")
	elif running && ! pfctl -a $NQ_ANCHOR -s rules 2>/dev/null | grep -q route-to; then
		cmd_start >/dev/null 2>&1 && fixed+=("$(msg "правила файрвола")")
	elif [ $net = 1 ] && running; then
		# after sleep: the network may look the same and still be another one
		rm -f "$NQ_READY"
		launchctl kill SIGUSR1 system/$NQ_LABEL >/dev/null 2>&1 && nfqws_wait_ready && fixed+=("$(msg "движок для текущей сети")")
	fi
	if telegram_on && ! telegram_running; then
		cmd_telegram on >/dev/null 2>&1 && fixed+=("$(msg "прокси для Telegram")")
	fi
	os_build > "$RT/os-build"
	[ ${#fixed[@]} -gt 0 ] && log "repair: ${fixed[*]}"
	if [ $json = 1 ]; then
		local out=""
		for i in "${fixed[@]}"; do out="$out${out:+,}$(jstr "$i")"; done
		echo "{\"fixed\":[$out]}"
	elif [ $quiet = 0 ]; then
		if [ ${#fixed[@]} = 0 ]; then ok "всё на месте"; else for i in "${fixed[@]}"; do ok "восстановлено: %s" "$i"; done; fi
	fi
	[ $quiet = 1 ] && [ ${#fixed[@]} -gt 0 ] && notify "$(msg "macOS обновилась — zapret восстановлен")"
	return 0
}

# back to how zapret starts out, without reinstalling: the strategy, the scope and the game filter by
# default, the history of searches and what was found for sites forgotten. the user's own lists, the
# switches of Settings, the Telegram proxy and the DNS for neural networks stay
cmd_reset()
{
	need_root reset "$@"
	installed || die "zapret не установлен. Запустить zapret.command"
	rm -f "$WORKED" "$SITES" "$SITES_TESTED" "$DSTRATS" "$RT/scope" "$RT/game" "$RT/skip-version" "$RT/watchdog.fails"
	[ -f "$AUTO_LIST" ] && : > "$AUTO_LIST"
	[ -f "$AUTO_WHY" ] && : > "$AUTO_WHY"
	[ -f "$LADDER_STATE" ] && : > "$LADDER_STATE"
	rm -f "$LADDER_RUNGS" "$LADDER_GEN" "$LADDER_RETIRED"
	# emptied, not removed: the engine runs without root and can't make them again
	[ -f "$LADDER_STATS" ] && : > "$LADDER_STATS"
	[ -f "$LADDER_SEEN" ] && : > "$LADDER_SEEN"
	log "reset"
	cmd_start "$DEFAULT_STRATEGY" >/dev/null || die "zapret не запустился после сброса — подробности в диагностике"
	ok "zapret сброшен: стратегия «%s», все сайты, игры выключены" "$DEFAULT_STRATEGY"
}

# the generator of the adaptive strategy: a new trick made from $1 (a line of options) by changing one thing in
# it — how the packet is cut, where, how the fake is told apart, how often it repeats, which fake goes. the
# pieces are those of the own strategies and the deep search: every one of them works on this engine
TRICK_MODES="multisplit multidisorder fakedsplit fakeddisorder fake,multisplit fake,multidisorder hostfakesplit fake"
TRICK_POS="1 2 midsld 1,midsld sniext+1 host+1 2,sniext+1 1,sniext+1,host+1,midsld"
TRICK_FOOL="ts badseq md5sig datanoack badsum"
TRICK_REP="1 2 4 6 8 11"
TRICK_FAKE="@BASE@/bin/tls_clienthello_www_google_com.bin @BASE@/bin/tls_clienthello_4pda_to.bin mod"

# one of the words of $1, at random
pick_word() { local a; read -r -a a <<<"$1"; echo "${a[RANDOM % ${#a[@]}]}"; }

# a change that changes nothing (the fake of a trick without fakes) is tried again, five times at most
trick_mutate()
{
	local o i
	for i in 1 2 3 4 5; do
		o=$(trick_mutate_once "$1")
		[ "$o" != "$1" ] && break
	done
	echo "$o"
}

trick_mutate_once()
{
	local mode pos fool rep fake o
	mode=$(sed -n 's/.*--dpi-desync=\([^ ]*\).*/\1/p' <<<"$1")
	pos=$(sed -n 's/.*--dpi-desync-split-pos=\([^ ]*\).*/\1/p' <<<"$1")
	fool=$(sed -n 's/.*--dpi-desync-fooling=\([^ ]*\).*/\1/p' <<<"$1")
	rep=$(sed -n 's/.*--dpi-desync-repeats=\([^ ]*\).*/\1/p' <<<"$1")
	fake=$(sed -n 's/.*--dpi-desync-fake-tls=\([^ ]*\).*/\1/p' <<<"$1")
	[[ $1 == *--dpi-desync-fake-tls-mod=* ]] && fake=mod
	: "${mode:=multisplit}" "${pos:=1}" "${fool:=ts}" "${rep:=6}" "${fake:=@BASE@/bin/tls_clienthello_www_google_com.bin}"
	case $((RANDOM % 5)) in
		0) mode=$(pick_word "$TRICK_MODES") ;;
		1) pos=$(pick_word "$TRICK_POS") ;;
		2) fool=$(pick_word "$TRICK_FOOL") ;;
		3) rep=$(pick_word "$TRICK_REP") ;;
		4) fake=$(pick_word "$TRICK_FAKE") ;;
	esac
	o="--dpi-desync=$mode"
	case $mode in
		hostfakesplit) o="$o --dpi-desync-hostfakesplit-mod=host=www.google.com" ;;
		*split* | *disorder*) o="$o --dpi-desync-split-pos=$pos" ;;
	esac
	case $mode in multisplit | multidisorder) ;; *) o="$o --dpi-desync-fooling=$fool" ;; esac
	case $mode in
		fake | fake,*)
			o="$o --dpi-desync-repeats=$rep"
			if [ "$fake" = mod ]; then o="$o --dpi-desync-fake-tls-mod=rnd,dupsid,sni=www.google.com"
			else o="$o --dpi-desync-fake-tls=$fake"; fi
			;;
	esac
	# what the generator doesn't change stays (the TTL of fakes, an overlap), the overlap only with a split
	local w
	for w in $1; do
		case $w in
			--dpi-desync=* | --dpi-desync-split-pos=* | --dpi-desync-fooling=* | --dpi-desync-repeats=* | \
				--dpi-desync-fake-tls=* | --dpi-desync-fake-tls-mod=* | --dpi-desync-hostfakesplit-mod=*) ;;
			--dpi-desync-split-seqovl*) [[ $mode == *multisplit ]] && o="$o $w" ;;
			*) o="$o $w" ;;
		esac
	done
	echo "$o"
}

# the engine takes the trick: a profile of it alone, dry run
trick_ok()
{
	local f ret
	f=$(mktemp)
	# shellcheck disable=SC2086 # the options of the trick, a word each
	printf '%s\n' --filter-tcp=443 $1 | sed "s|@BASE@|$(nq_dir)|g" > "$f"
	nfqws_dry_run "$f" >/dev/null 2>&1
	ret=$?
	rm -f "$f"
	return $ret
}

# the generator, once a day: from how each rung does over all sites (the engine's ladder-stats.txt), the rungs
# that do badly — failing half the time, or several times slower than the best — and that no site stays on give
# way to new tricks made from the best two (in place: the rungs of sites keep their numbers); a ladder shorter
# than 32 rungs grows by up to two. the tricks replaced are retired for good. a rung needs ten measurements to
# be judged. the engine tries new tricks on a share of connections like any trick not measured yet
auto_ladder_evolve()
{
	local best bad r opts new i n tries made=0 size
	adaptive_on && [ -s "$LADDER_RUNGS" ] && [ -s "$LADDER_STATS" ] || return 0
	[ -n "$(find "$RT/ladder-evolved" -mtime -1 2>/dev/null)" ] && return 0
	touch "$RT/ladder-evolved"
	size=$(grep -c . "$LADDER_RUNGS")
	# the best two: measured, rarely failing, fastest
	best=$(awk '$2 >= 10 && $3 * 4 < $2 { print $4, $1 }' "$LADDER_STATS" | sort -rn | head -2 | awk '{ printf "%s ", $2 }')
	[ -n "$best" ] || return 0
	local top
	top=$(awk '$2 >= 10 && $3 * 4 < $2 { print $4 }' "$LADDER_STATS" | sort -rn | head -1)
	# the bad ones no site stays on (ladder.txt holds the rungs of sites; the bottom one is everyone's)
	bad=$(awk -v top="$top" -v used="$(awk '$1 !~ /^quic:/ && $1 != "voice" { printf " %s ", $2 }' "$LADDER_STATE" 2>/dev/null)" \
		'$1 > 0 && $2 >= 10 && ($3 * 2 >= $2 || $4 * 3 < top) && index(used, " " $1 " ") == 0 { print $1 }' "$LADDER_STATS" | head -2)
	for r in $bad new new; do
		[ "$r" = new ] && [ "$size" -ge 32 ] && break
		opts=$(sed -n "$(($(pick_word "$best") + 1))p" "$LADDER_RUNGS")
		new=""
		for ((tries = 0; tries < 30; tries++)); do
			n=$(trick_mutate "$opts")
			# not one of the ladder, nor one retired (it would be taken off again)
			grep -qxF -- "$n" "$LADDER_RUNGS" "$LADDER_RETIRED" 2>/dev/null && continue
			trick_ok "$n" && new=$n && break
		done
		[ -n "$new" ] || continue
		if [ "$r" != new ]; then
			# the old trick goes for good: out of what the generator made, and kept off the ladder
			opts=$(sed -n "$((r + 1))p" "$LADDER_RUNGS")
			echo "$opts" >> "$LADDER_RETIRED"
			[ -f "$LADDER_GEN" ] && { grep -vxF -- "$opts" "$LADDER_GEN" > "$LADDER_GEN.new"; cat "$LADDER_GEN.new" > "$LADDER_GEN"; rm -f "$LADDER_GEN.new"; }
		fi
		echo "$new" >> "$LADDER_GEN"
		if [ "$r" = new ]; then
			echo "$new" >> "$LADDER_RUNGS"
			size=$((size + 1))
		else
			i=$((r + 1))
			awk -v i="$i" -v n="$new" 'NR == i { print n; next } { print }' "$LADDER_RUNGS" > "$LADDER_RUNGS.new" &&
				cat "$LADDER_RUNGS.new" > "$LADDER_RUNGS"
			rm -f "$LADDER_RUNGS.new"
			# the measurements of the old trick are not the new one's
			awk -v r="$r" '$1 == r { print r, 0, 0, 0; next } { print }' "$LADDER_STATS" > "$LADDER_STATS.new" &&
				cat "$LADDER_STATS.new" > "$LADDER_STATS"
			rm -f "$LADDER_STATS.new"
		fi
		made=$((made + 1))
	done
	[ $made -gt 0 ] || return 0
	log "$(msg "адаптивная: новых приёмов: %s — движок опробует их сам" "$made")"
	cmd_start "$ADAPTIVE" >/dev/null 2>&1
	return 0
}
