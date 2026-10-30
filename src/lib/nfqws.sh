# shellcheck shell=bash
# zapret.sh: nfqws engine. Sourced by src/zapret.sh, which defines the constants.

nfqws_installed() { [ -x "$RT/nfqws/bin/utunws" ] && [ "$(cat "$RT/nfqws/bin/VERSION" 2>/dev/null)" = "$NQ_TAG" ]; }

# the engine (utunws) and the Telegram proxy (zapret-tg): our release of engine/ (build/utunws.sh), checked
# against a pinned checksum. the fake payloads are in the project (nfqws/bin, build/fakes.swift)
nfqws_install()
{
	nfqws_installed && return 0
	say "%sСкачиваю движок nfqws (%s)…%s" "${B}" "$NQ_TAG" "${N}"
	local tmp ret=1
	tmp=$(mktemp -d)
	# GitHub drops a connection now and then: three more tries
	if ! curl -fL --retry 3 --retry-delay 3 --retry-connrefused --progress-bar -o "$tmp/u.tar.gz" "https://github.com/$REPO/releases/download/$NQ_TAG/utunws.tar.gz"; then
		bad "Не удалось скачать nfqws"
	elif ! echo "$NQ_SHA256  $tmp/u.tar.gz" | shasum -a 256 -c --status; then
		bad "Контрольная сумма nfqws не совпала"
	elif ! mkdir "$tmp/x" || ! tar -xzf "$tmp/u.tar.gz" -C "$tmp/x"; then
		bad "Не удалось распаковать nfqws"
	else
		mkdir -p "$RT/nfqws/bin"
		# a new file in place of the old one, never over it: macOS kills every later start of a signed
		# binary that was overwritten while it ran
		local b
		for b in utunws zapret-tg; do
			[ -f "$tmp/x/bin/$b" ] || continue
			cp "$tmp/x/bin/$b" "$RT/nfqws/bin/$b.new"
			chown root:wheel "$RT/nfqws/bin/$b.new"
			chmod 755 "$RT/nfqws/bin/$b.new"
			mv -f "$RT/nfqws/bin/$b.new" "$RT/nfqws/bin/$b"
		done
		echo "$NQ_TAG" > "$RT/nfqws/bin/VERSION"
		chown -R root:wheel "$RT/nfqws"
		# a running Telegram proxy is still the old binary: it restarts as the new one
		launchctl kickstart -k system/$TG_LABEL >/dev/null 2>&1
		ok "nfqws установлен"
		ret=0
	fi
	rm -rf "$tmp"
	return $ret
}

# the template of a strategy: Flowseal's file, or ours with @DESYNC@ for own and found ones. $1 name, $2 game-tcp/game-udp/empty
strategy_template()
{
	local f
	if is_windows "$1"; then
		f=$(nfqws_file "$1")
		[ -n "$f" ] || return 1
		f=$(nq_dir)/strategies/$f${2:+.$2}.conf.in
	else
		f=$RT/nfqws/macos/${2:-main}.conf.in
	fi
	[ -f "$f" ] && echo "$f"
}

# the rungs of the adaptive strategy, a line of options each: our own tricks, the ones that passed the last
# check on this network first, then the extra ones of nfqws/ladder-extra.conf and those the generator made
# (auto_ladder_evolve), at most 32, without those the generator retired. The order is kept in $LADDER_RUNGS
# once made: the rungs of sites in ladder.txt are indexes into it. A trick that is gone (a release dropped
# it) starts it over, with the sites at the bottom; new tricks only join at the end
ladder_rungs()
{
	local n o fresh
	fresh=$({ [ -f "$WORKED" ] && cat "$WORKED"; own_names; } | awk '!seen[$0]++' |
		while IFS= read -r n; do
			o=$(strategy_opts "$n")
			# bash 3.2 of macOS can't read a case inside $(…)
			if [ -n "$o" ] && [[ $o != *@LADDER@* ]]; then echo "$o"; fi
		done
		grep -hvE '^[[:space:]]*(#|$)' "$SRC/nfqws/ladder-extra.conf" "$LADDER_GEN" 2>/dev/null)
	[ -s "$LADDER_RETIRED" ] && fresh=$(grep -vxF -f "$LADDER_RETIRED" <<<"$fresh")
	if [ -s "$LADDER_RUNGS" ] && grep -qvxF -f <(printf '%s\n' "$fresh") "$LADDER_RUNGS"; then
		rm -f "$LADDER_RUNGS"
		[ -f "$LADDER_STATS" ] && : > "$LADDER_STATS"
		# the TCP sites start over; QUIC and voice have fixed lists of their own and keep their rungs
		if [ -f "$LADDER_STATE" ]; then
			awk '$1 ~ /^quic:/ || $1 == "voice"' "$LADDER_STATE" > "$LADDER_STATE.new"
			cat "$LADDER_STATE.new" > "$LADDER_STATE"
			rm -f "$LADDER_STATE.new"
		fi
	fi
	{ cat "$LADDER_RUNGS" 2>/dev/null; printf '%s\n' "$fresh"; } | awk 'NF && !seen[$0]++' | head -32
}

# the adaptive strategy at work, for its page in the app: the sites used most (the engine counts them) with
# the speed it measured and their trick, and the latest moves of the ladder with their reason (rst, redirect,
# silence — a failure; faster — the live choice)
ladder_live_json()
{
	local first=1 site conns last rung kbps name opts
	printf '{"sites":['
	while read -r site conns last rung kbps; do
		[ -n "$site" ] || continue
		opts=$(sed -n "$((rung + 1))p" "$LADDER_RUNGS" 2>/dev/null)
		name=$(own_lines | awk -F'|' -v o="$opts" '$2 == o { print $1; exit }')
		[ $first = 1 ] || printf ','
		first=0
		printf '{"site":%s,"connections":%s,"last":%s,"rung":%s,"kbps":%s,"trick":%s}' "$(jstr "$site")" "${conns:-0}" \
			"${last:-0}" "$((${rung:-0} + 1))" "${kbps:-0}" "$(jstr "$name")"
	done < <(sort -k2 -rn "$LADDER_SEEN" 2>/dev/null | head -30)
	printf '],"events":['
	# a line of the engine's log: time : host : profile N : client … : proto … : what happened. a move names
	# the site (youtube.com, quic:youtube.com), the failure before it the host (www.youtube.com): the latest
	# failure of a host of that site is the reason, used once
	awk -F' : ' '
		$6 ~ /^(incoming RST|redirect to another domain|retrans threshold reached)$/ { why[$2] = $6; at[$2] = NR }
		$6 ~ /^ladder rung [0-9]+/ {
			split($6, w, " "); r = w[3] + 1
			site = $2; sub(/^quic:/, "", site)
			h = ""; cause = ""
			if ($6 !~ /faster$/) {
				for (k in why) if ((k == site || substr(k, length(k) - length(site)) == "." site) && (h == "" || at[k] > at[h])) h = k
				if (h != "") { cause = why[h]; delete why[h]; delete at[h] }
			}
			if ($6 ~ /faster$/) reason = "faster"
			else if (cause == "incoming RST") reason = "rst"
			else if (cause == "redirect to another domain") reason = "redirect"
			else reason = "silence"
			ev[++n] = sprintf("{\"time\":\"%s\",\"site\":\"%s\",\"rung\":%d,\"reason\":\"%s\"}", $1, $2, r, reason)
		}
		END { for (i = n; i > 0 && i > n - 20; i--) printf "%s%s", (i < n ? "," : ""), ev[i] }' "$AUTO_WHY" 2>/dev/null
	echo ']}'
}

# the sites the adaptive strategy moved: site, its ladder (tcp, quic, voice), its rung, the name of the trick
# there (TCP only: QUIC and voice tricks have no names). --json for the app; --live --json: ladder_live_json
cmd_ladder()
{
	if [ "$1" = --live ]; then ladder_live_json; return; fi
	local key site kind rung opts name kbps first=1
	[ "$1" = --json ] && printf '['
	while read -r key rung; do
		[ -n "$key" ] || continue
		name=""
		case "$key" in
			quic:*) kind=quic site=${key#quic:} ;;
			voice) kind=voice site=Discord ;;
			sn-*.googlevideo.com) kind=tcp site="YouTube (${key%%.*})"
				opts=$(sed -n "$((rung + 1))p" "$LADDER_RUNGS" 2>/dev/null)
				name=$(own_lines | awk -F'|' -v o="$opts" '$2 == o { print $1; exit }')
				;;
			*)
				kind=tcp site=$key
				opts=$(sed -n "$((rung + 1))p" "$LADDER_RUNGS" 2>/dev/null)
				name=$(own_lines | awk -F'|' -v o="$opts" '$2 == o { print $1; exit }')
				;;
		esac
		# the speed the engine measured on the site's own trick (live choice), KB/s; 0 — not yet
		kbps=$(awk -v k="$key" '$1 == k { print $5 + 0 }' "$LADDER_SEEN" 2>/dev/null)
		if [ "$1" = --json ]; then
			[ $first = 1 ] || printf ','
			first=0
			printf '{"site":%s,"kind":"%s","rung":%s,"trick":%s,"kbps":%s}' "$(jstr "$site")" "$kind" "$((rung + 1))" "$(jstr "$name")" "${kbps:-0}"
		else
			say "  %s%s — приём %s%s" "$site" "$([ $kind = tcp ] || echo " ($kind)")" "$((rung + 1))" "${name:+ ($name)}"
		fi
	done < <(cat "$LADDER_STATE" 2>/dev/null)
	if [ "$1" = --json ]; then echo ']'; elif [ $first = 1 ] && [ ! -s "$LADDER_STATE" ]; then
		say "Адаптивная: все сайты открываются с первого приёма"
	fi
}

# the rungs of QUIC (@QUIC@) and Discord voice (@VOICE@): fixed lists, the first one is what every own
# strategy has there
udp_rungs() { grep -hvE '^[[:space:]]*(#|$)' "$SRC/nfqws/ladder-$1.conf" 2>/dev/null; }

# a template into the ladder: every profile with @DESYNC@ once per rung of the file $1 (--ladder=K and
# its options), with @QUIC@ and @VOICE@ the same from their lists; the engine keeps the rungs of sites
put_ladder()
{
	awk -v rf="$1" -v qf=<(udp_rungs quic) -v vf=<(udp_rungs voice) '
		function load(f, arr,   l, c) { c = 0; while ((getline l < f) > 0) arr[c++] = l; return c }
		BEGIN { nt = load(rf, rt); nq = load(qf, rq); nv = load(vf, rv) }
		function emit(prefix, opts,   m, a, j) {
			print "--ladder=" prefix
			m = split(opts, a, " ")
			for (j = 1; j <= m; j++) print a[j]
		}
		function flush(   i, k, reps, mark) {
			if (!np) return
			reps = 1; mark = ""
			for (i = 1; i <= np; i++)
				if (p[i] == "@DESYNC@") { reps = nt; mark = p[i] }
				else if (p[i] == "@QUIC@") { reps = nq; mark = p[i] }
				else if (p[i] == "@VOICE@") { reps = nv; mark = p[i] }
			for (k = 0; k < reps; k++) {
				if (out++) print "--new"
				for (i = 1; i <= np; i++)
					if (p[i] == "@DESYNC@") emit(k, rt[k])
					else if (p[i] == "@QUIC@") emit("quic:" k, rq[k])
					else if (p[i] == "@VOICE@") emit("voice:" k, rv[k])
					else print p[i]
			}
			np = 0
		}
		$0 == "--new" { flush(); next }
		{ p[++np] = $0 }
		END {
			flush()
			print "--ladder-state=\"@LISTS@/ladder.txt\""
			print "--ladder-seen=\"@LISTS@/ladder-seen.txt\""
			print "--ladder-stats=\"@LISTS@/ladder-stats.txt\""
			# every climb with its reason in the journal of the engine, whatever the scope (smart mode adds it too)
			print "--hostlist-auto-debug=\"@LISTS@/list-auto-why.log\""
		}'
}

# a template with one trick: its options one per line in place of @DESYNC@ ($1), the first rung of QUIC and
# voice in place of @QUIC@ and @VOICE@
put_desync()
{
	awk -v o="$1" -v q="$(udp_rungs quic | head -1)" -v v="$(udp_rungs voice | head -1)" '
		function put(s,   n, a, i) { n = split(s, a, " "); for (i = 1; i <= n; i++) print a[i] }
		$0 == "@DESYNC@" { put(o); next }
		$0 == "@QUIC@" { put(q); next }
		$0 == "@VOICE@" { put(v); next }
		{ print }'
}

# options of a strategy for one site's own profile: own and found ones as they are, the Windows version's
# from its profile for HTTP and HTTPS of the general list
site_opts()
{
	if is_windows "$1"; then
		local f
		f=$(strategy_template "$1") || return 1
		awk '
			$0 == "--new" { if (hit) exit; delete p; n = 0; next }
			$0 == "--filter-tcp=80,443" { tcp = 1 }
			$0 ~ /list-general\.txt"$/ { gen = 1 }
			$0 !~ /^--(filter|hostlist|ipset|new)/ { p[++n] = $0 }
			tcp && gen { hit = 1 }
			END { if (hit) for (i = 1; i <= n; i++) printf "%s%s", (i > 1 ? " " : ""), p[i]; print "" }
		' "$f" | tr -d '"'
	else
		# the adaptive one is a ladder, not options: it can't be a site's own strategy
		local o
		o=$(strategy_opts "$1")
		case "$o" in *@LADDER@*) ;; *) printf '%s\n' "$o" ;; esac
	fi
}

# fills the placeholders: $1 strategy name, $2 output file. sites with their own strategy (see learn)
# get a profile each, first: nfqws takes the first profile that fits
nfqws_conf()
{
	local t ipset=$RT/lists/ipset-none.txt auto="" opts=""
	known_name "$1" || return 1
	t=$(strategy_template "$1") || return 1
	is_windows "$1" || { opts=$(strategy_opts "$1"); [ -n "$opts" ] || return 1; }
	case "$(scope)" in
		all) ipset=$RT/lists/ipset-any.txt ;;
		# the profiles of the user's list also take the sites known to be blocked (blocked_update), and learn
		# new ones: from resets and redirects in the servers' answers (ZAPRET_INBOUND, run.sh) and from
		# requests nobody answers, at the second failure. the engine says which it was in list-auto-why.log
		smart) auto="--hostlist=\"@LISTS@/list-blocked.txt\" --hostlist-auto=\"@LISTS@/list-auto.txt\" --hostlist-auto-fail-threshold=2 --hostlist-auto-debug=\"@LISTS@/list-auto-why.log\"" ;;
	esac
	local g k s so n=0 f
	g=$(game_mode)
	rm -f "$RT"/lists/site-*.txt
	{
		if [ -s "$SITES" ]; then
			while IFS= read -r s; do
				so=$(site_opts "$s")
				[ -n "$so" ] || continue
				n=$((n + 1)); f=$RT/lists/site-$n.txt
				awk -F'\t' -v s="$s" '$2 == s { print $1 }' "$SITES" > "$f"
				chmod 644 "$f"
				printf '%s\n' --filter-tcp=80,443 "--hostlist=$f"
				printf '%s\n' "$so" | tr ' ' '\n'
				echo --new
			done < <(cut -f2 "$SITES" | sort -u)
		fi
		if [ "$opts" = @LADDER@ ]; then
			# video of YouTube over TCP: QUIC to its servers goes nowhere, first of all
			if ! video_quic; then printf '%s\n' --filter-udp=443 --hostlist-domains=googlevideo.com --drop --new; fi
			ladder_rungs > "$LADDER_RUNGS.new" && mv -f "$LADDER_RUNGS.new" "$LADDER_RUNGS"
			awk -v a="$auto" '{ print } a != "" && $0 == "--hostlist=\"@LISTS@/list-general-user.txt\"" { print a }' "$t" |
				put_ladder "$LADDER_RUNGS"
		else
			awk -v a="$auto" '{ print } a != "" && $0 == "--hostlist=\"@LISTS@/list-general-user.txt\"" { print a }' "$t" |
				put_desync "$opts"
		fi
		for k in tcp udp; do
			if { [ "$g" = all ] || [ "$g" = $k ]; } && f=$(strategy_template "$1" game-$k); then
				echo --new
				cat "$f"
			fi
		done
	} | sed -e "s|@BASE@|$(nq_dir)|g" -e "s|@LISTS@|$RT/lists|g" -e "s|@IPSET@|$ipset|g" \
		-e "s|@GAME_TCP@|1024-65535|g" -e "s|@GAME_UDP@|1024-65535|g" -e "s|@GAMEIPSET@|$(nq_dir)/ipset-game.txt|g" > "$2"
}

# a config for trying options on some sites only (learn, deep): $1 options, $2 file with the sites, $3 output
nfqws_site_conf()
{
	{
		printf '%s\n' --filter-tcp=80,443 "--hostlist=$2"
		printf '%s\n' "$1" | tr ' ' '\n'
	} | sed -e "s|@BASE@|$(nq_dir)|g" > "$3"
}

# runs a config ($1) for a test until nfqws_untry. the first call starts the engine, the next ones
# make it read the file again (SIGHUP to run.sh): a strategy takes a fraction of a second instead of
# the whole setup. IPv4 only: the IPv6 self-test takes seconds and test requests fall back to IPv4 at
# once. true when the engine is up
nfqws_try()
{
	rm -f "$NQ_READY"
	if [ -n "$TRY_PID" ] && kill -0 "$TRY_PID" 2>/dev/null && [ "$1" = "$TRY_CONF" ]; then
		kill -HUP "$TRY_PID"
	else
		nfqws_untry
		ZAPRET_NO_V6=1 "$RT/nfqws/run.sh" "$1" >/dev/null 2>&1 &
		TRY_PID=$!
		TRY_CONF=$1
	fi
	nfqws_wait_ready "$TRY_PID"
}

nfqws_untry()
{
	[ -n "$TRY_PID" ] && { kill "$TRY_PID" 2>/dev/null; wait "$TRY_PID" 2>/dev/null; }
	TRY_PID=""
}

nfqws_dry_run()
{
	local tmp ret
	tmp=$(mktemp)
	{ echo --dry-run; cat "$1"; } > "$tmp"
	# @file is read only when it is the first argument
	# in a subshell: bash would report a start macOS killed (see cmd_start)
	( "$RT/nfqws/bin/utunws" "@$tmp" ) >/dev/null 2>&1
	ret=$?
	rm -f "$tmp"
	return $ret
}

# waits until run.sh has loaded the pf rules (its IPv6 self-test takes up to 10 seconds);
# $1: the pid of run.sh, if it ends there is nothing to wait for
nfqws_wait_ready()
{
	local i
	for i in $(seq 150); do
		[ -f "$NQ_READY" ] && return 0
		[ -n "$1" ] && ! kill -0 "$1" 2>/dev/null && return 1
		sleep 0.1
	done
	return 1
}

# the running service takes the new $RT/nfqws.conf without a restart of the network setup and the
# firewall. not when the game filter changed: its ports are in the pf rules
nfqws_reload()
{
	[ -f "$NQ_READY" ] && launchctl print system/$NQ_LABEL >/dev/null 2>&1 || return 1
	[ "$(cat /var/run/zapret-macos.nfqws-game 2>/dev/null)" = "$(game_mode)" ] || return 1
	rm -f "$NQ_READY"
	launchctl kill SIGHUP system/$NQ_LABEL >/dev/null 2>&1 || return 1
	nfqws_wait_ready && running
}

nfqws_launch()
{
	cat > "$NQ_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>$NQ_LABEL</string>
	<key>ProgramArguments</key><array><string>$RT/nfqws/run.sh</string></array>
	<key>RunAtLoad</key><true/>
	<key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
	<key>ThrottleInterval</key><integer>5</integer>
	<key>StandardErrorPath</key><string>/var/log/zapret-macos-nfqws.log</string>
</dict>
</plist>
EOF
	launchctl enable system/$NQ_LABEL
	# a loaded job is restarted; a new one starts by RunAtLoad. kickstart right after bootstrap
	# would kill the first run.sh while it starts and leave the ready mark of a dead one
	if launchctl print system/$NQ_LABEL >/dev/null 2>&1; then
		launchctl kickstart -k system/$NQ_LABEL
	else
		launchctl bootstrap system "$NQ_PLIST"
	fi
	nfqws_wait_ready && pgrep -qx utunws
}

set_autostart()
{
	if [ "$1" = on ]; then launchctl enable system/$NQ_LABEL; else launchctl disable system/$NQ_LABEL; fi
}

# tests the URLs and prints "passed/total youtube_bytes_per_sec".
# $1: empty — directly as root (pf leaves root alone), "user" — as nobody, through pf and the running
# engine. $2=1 stops at the first failure.
probe()
{
	local url out code size speed pass=0 total=0 yt=0 run=()
	[ "$1" = user ] && run=(sudo -u nobody)
	for url in $TESTS; do
		total=$((total + 1))
		out=$("${run[@]}" curl -s -o /dev/null -m 8 -w "%{http_code} %{size_download} %{speed_download}" "$url")
		read -r code size speed <<<"$out"
		size=${size%.*}; speed=${speed%.*}
		if [ "${code:-000}" = 000 ]; then [ "$2" = 1 ] && break; continue; fi
		if [ "$url" = "https://www.youtube.com/" ]; then
			# DPI often lets the first ~16 KB through and then stalls the connection
			if [ "${size:-0}" -lt 300000 ]; then [ "$2" = 1 ] && break; continue; fi
			yt=${speed:-0}
		fi
		pass=$((pass + 1))
	done
	[ "$2" = 1 ] && total=$(echo "$TESTS" | wc -l | tr -d ' ')
	echo "$pass/$total $yt"
}

# the same URLs without zapret, all at once and briefly: without a bypass the provider lets connections
# hang, one by one that took half a minute. only for the "without zapret" line. prints "passed/total"
probe_base()
{
	local d url n=0 pass=0 code size
	d=$(mktemp -d)
	for url in $TESTS; do
		n=$((n + 1))
		curl -s -o /dev/null -m 5 -w "%{http_code} %{size_download} $url" "$url" > "$d/$n" &
	done
	wait
	for url in "$d"/*; do
		read -r code size url < "$url"
		[ "${code:-000}" = 000 ] && continue
		# DPI often lets the first ~16 KB through and then stalls the connection
		[ "$url" = "https://www.youtube.com/" ] && [ "${size%.*}" -lt 300000 ] && continue
		pass=$((pass + 1))
	done
	rm -rf "$d"
	echo "$pass/$n"
}

# Discord voice goes over UDP, and the strategies look for STUN on ports 19294-19344.
# a STUN request to such a port shows whether that path works. $1: empty — as root, past the engine;
# "user" — as nobody, through pf and the running engine
stun_ok()
{
	local run=()
	[ "$1" = user ] && run=(sudo -u nobody)
	"${run[@]}" "$TG_BIN" stun >/dev/null 2>&1
}

# one JSON line per event of check for the app; $1 event, then key value pairs (values are strings)
event()
{
	[ "$json" = 1 ] || return 0
	local e=$1 out k v
	shift
	out="{\"event\":\"$e\""
	while [ $# -ge 2 ]; do
		k=$1; v=${2//\\/\\\\}; v=${v//\"/\\\"}
		out="$out,\"$k\":\"$v\""
		shift 2
	done
	echo "$out}"
}
