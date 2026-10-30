# shellcheck shell=bash
# zapret.sh: helpers. Sourced by src/zapret.sh, which defines the constants.

need_root()
{
	[ "$(id -u)" = 0 ] || exec sudo "$SELF" "$@"
}

console_user()
{
	local u=${SUDO_USER:-$(stat -f %Su /dev/console)}
	[ "$u" = root ] && u=$(stat -f %Su /dev/console)
	echo "$u"
}

# run a command as the logged in user (inside their GUI session when we are root)
as_user()
{
	local u
	if [ "$(id -u)" = 0 ]; then
		u=$(console_user)
		[ -n "$u" ] && [ "$u" != root ] || return 1
		launchctl asuser "$(id -u "$u")" sudo -H -u "$u" "$@"
	else
		"$@"
	fi
}

notify()
{
	# the app tells about changes itself, with buttons
	pgrep -qx zapret && return 0
	as_user osascript -e "display notification \"$1\" with title \"zapret\"" >/dev/null 2>&1
}

# one engine, nfqws, and three kinds of strategies: the Windows version's (Flowseal's files listed in
# nfqws/strategies.tsv, named "nfqws <name>"), our own for macOS (lines of nfqws/macos.conf) and the ones
# the deep search found (lines of $DSTRATS). own and found ones are options for TCP put into a template
# the list of the Windows version's strategies: of a fresh pack (pack.sh) or of the release
nq_tsv()        { if pack_active; then echo "$RT/pack/nfqws/strategies.tsv"; else echo "$NQ_STRATS"; fi; }
windows_names() { awk -F'\t' 'NF == 2 { print "nfqws " $2 }' "$(nq_tsv)"; }
# lines of both files; no file or no lines is no error: these functions go into pipes
own_lines()
{
	grep -hvE '^\s*(#|$)' "$OWN_STRATS" 2>/dev/null
	[ ! -f "$DSTRATS" ] || grep -hvE '^\s*(#|$)' "$DSTRATS"
	return 0
}
own_names()     { own_lines | cut -d'|' -f1; }

# the Windows version's first: they are the main ones
strategy_names()
{
	windows_names
	own_names
}

is_windows()  { case "$1" in "nfqws "*) return 0 ;; *) return 1 ;; esac; }
nfqws_file()  { awk -F'\t' -v n="${1#nfqws }" '$2 == n { print $1; exit }' "$(nq_tsv)"; }
# reads the whole list: grep -q would stop early and break the pipe under pipefail
known_name()  { strategy_names | grep -xF -- "$1" >/dev/null; }

# options of an own or found strategy, nothing for others
strategy_opts()
{
	own_lines | awk -F'|' -v n="$1" '$1 == n { print $2; exit }'
}

installed()  { [ -f "$RT/zapret.sh" ] && [ -d "$RT/lib" ]; }
adaptive_on() { [ "$(current)" = "$ADAPTIVE" ]; }

nfqws_stop()
{
	launchctl bootout system/$NQ_LABEL 2>/dev/null
	# bootout returns before the job is gone, and bootstrap of a job still there fails
	local i
	for i in $(seq 25); do launchctl print system/$NQ_LABEL >/dev/null 2>&1 || break; sleep 0.2; done
	pkill -f -- "$RT/nfqws/run.sh"
	pkill -9 -x utunws
	pfctl -a $NQ_ANCHOR -F all >/dev/null 2>&1
	rm -f "$NQ_READY"
	# run.sh restores the TCP connect timeout itself, unless it was killed
	if [ -s /var/db/zapret-macos.keepinit ]; then
		sysctl -w net.inet.tcp.keepinit="$(cat /var/db/zapret-macos.keepinit)" >/dev/null
		rm -f /var/db/zapret-macos.keepinit
	fi
}

running()    { pgrep -qx utunws; }
# the service is up but waits for a network with a gateway (offline, a VPN took the default route)
waiting()    { [ -f /var/run/zapret-macos.nfqws-waiting ] && pgrep -qf -- "$RT/nfqws/run.sh"; }
current()    { head -1 "$CURRENT" 2>/dev/null; }
vpn_active() { netstat -rn -f inet | grep -qE '^(0/1|default) +[^ ]+ +[^ ]+ +utun'; }
autostart_on()  { ! launchctl print-disabled system 2>/dev/null | grep -qE "\"$NQ_LABEL\" => (true|disabled)"; }
# autofix and autoupdate: the background job (launchd, every 5 minutes) checks them, it runs anyway
watchdog_on()   { [ -f "$RT/autofix" ]; }
autoupdate_on() { [ -f "$RT/autoupdate" ]; }
app_installed() { [ -d /Applications/zapret.app ]; }
# which sites are processed: all, smart (lists + found blocked ones) or lists
scope()         { local s; s=$(cat "$RT/scope" 2>/dev/null); echo "${s:-all}"; }
scope_name()    { case "$(scope)" in all) msg "все" ;; smart) msg "умный" ;; *) msg "по спискам" ;; esac; }
# game filter of the Windows version: nfqws also handles ports 1024-65535 of game servers. off, tcp, udp or all
game_mode()     { local g; g=$(cat "$RT/game" 2>/dev/null); echo "${g:-off}"; }
game_name()     { case "$(game_mode)" in tcp) echo TCP ;; udp) echo UDP ;; all) say "TCP и UDP" ;; *) msg "выкл" ;; esac; }

# the latest release: github.com/…/releases/latest redirects to …/releases/tag/vX.Y.Z.
# only released versions reach users, not every change of main
remote_version()
{
	curl -fsSIL -m 8 "https://github.com/$REPO/releases/latest" 2>/dev/null | release_of
}

# the version from the headers of those redirects (the last one), nothing if there is none
release_of()
{
	awk 'tolower($1) == "location:" { n = split($2, a, "/"); print a[n] }' | tr -d '\r' | sed 's/^v//' |
		grep -xE '[0-9]+(\.[0-9]+){1,3}' | tail -1
}

# true if $1 is a newer version than $2
newer()
{
	[ -n "$1" ] && [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

# copy the scripts into the root-owned runtime folder that launchd and the app use
sync_runtime()
{
	[ "$SRC" = "$RT" ] && return
	mkdir -p "$RT"
	cp "$SRC/zapret.sh" "$SRC/VERSION" \
		"$SRC/list-general.txt" "$SRC/list-google.txt" "$SRC/list-exclude.txt" "$SRC/ipset-exclude.txt" "$RT/"
	mkdir -p "$RT/nfqws" "$RT/telegram" "$RT/lib" "$RT/lang"
	cp "$SRC"/lib/*.sh "$RT/lib/"
	cp "$SRC"/lang/*.tsv "$RT/lang/"
	cp -R "$SRC/nfqws/." "$RT/nfqws/"
	echo "$PROJECT" > "$RT/project"
	install_sudoers
	chown -R root:wheel "$RT"
	engine_files_own
	chmod 755 "$RT" "$RT/zapret.sh" "$RT/nfqws/run.sh"
}

# the files the engine writes stay its own: it runs without root ($NQ_UID) and chowns them only when it
# starts. without this, any command that syncs the runtime while the engine runs (Telegram on, an update)
# would stop the smart mode and the ladder from learning until the next start
engine_files_own()
{
	local f
	for f in "$AUTO_LIST" "$AUTO_WHY" "$LADDER_STATE" "$LADDER_SEEN" "$LADDER_STATS"; do
		[ -f "$f" ] && chown "$NQ_UID" "$f"
	done
	return 0
}

# the app runs these commands of the root-owned copy without a password. update too: it installs
# only signed releases and runs the new script from its own checked download
install_sudoers()
{
	local f=/etc/sudoers.d/zapret-macos tmp c
	tmp=$(mktemp)
	{
		echo "# zapret-macos: the app runs these without a password"
		printf '%%admin ALL=(root) NOPASSWD:'
		for c in start stop check scope game video autostart watchdog autoupdate learn found diag telegram site sites-check dns deep repair update reset pack; do
			printf ' %s %s, %s %s *,' "$RT/zapret.sh" $c "$RT/zapret.sh" $c
		done | sed 's/,$//'
		echo
	} > "$tmp"
	if visudo -c -q -f "$tmp" 2>/dev/null; then
		cmp -s "$tmp" "$f" || { install -m 440 -o root -g wheel "$tmp" "$f"; }
	fi
	rm -f "$tmp"
}

# https://www.Example.com/page → example.com; prints nothing if it is not a host name.
# only such names go into curl, the lists nfqws reads and the names of strategies
host_of()
{
	local d
	d=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's#^[a-z]+://##; s#[/?#:].*$##; s#^www\.##')
	# the whole string, not line by line: a second line would get into names that end up in the
	# config zapret runs as a script
	[[ $d =~ ^[a-z0-9-]+(\.[a-z0-9-]+)+$ ]] && printf '%s\n' "$d"
}

# the user's files are read and written with the rights of the project folder's owner. as root,
# a symlink there would let any program read or change a system file: the sudoers rule asks no password
project_owner() { stat -f %Su "$PROJECT" 2>/dev/null; }

user_cat()
{
	local u
	u=$(project_owner)
	if [ "$(id -u)" = 0 ] && [ -n "$u" ] && [ "$u" != root ]; then
		sudo -u "$u" cat "$@" 2>/dev/null
	else
		cat "$@" 2>/dev/null
	fi
}

# $1 file, $2 line
user_append()
{
	local u
	u=$(project_owner)
	if [ "$(id -u)" = 0 ] && [ -n "$u" ] && [ "$u" != root ]; then
		sudo -u "$u" /bin/sh -c 'printf "%s\n" "$2" >> "$1"' sh "$1" "$2"
	else
		printf '%s\n' "$2" >> "$1"
	fi
}

# the lists nfqws reads, in $RT/lists
write_lists()
{
	local l=$RT/lists
	[ -d "$PROJECT/lists" ] || warn "папка проекта не найдена (%s) — свои списки не подключены. Запустить zapret.command из новой папки." "$PROJECT"
	mkdir -p "$l"
	local f
	for f in list-general.txt list-google.txt list-exclude.txt ipset-exclude.txt; do cp "$(list_file $f)" "$l/$f"; done
	user_cat "$PROJECT/lists/list-user.txt" > "$l/list-general-user.txt"
	user_cat "$PROJECT/lists/list-exclude-user.txt" > "$l/list-exclude-user.txt"
	: > "$l/ipset-exclude-user.txt"
	touch "$AUTO_LIST" "$AUTO_WHY" "$LADDER_STATE" "$LADDER_SEEN" "$LADDER_STATS"
	auto_why_trim
	: > "$l/ipset-any.txt"                        # empty ipset: every IPv4 address
	echo 203.0.113.113/32 > "$l/ipset-none.txt"   # documentation address: nothing
	chmod 755 "$l"; chmod 644 "$l"/*
}

# logs are kept small: the last ~300 KB of each once it grows past 1 MB
trim_logs()
{
	local f
	for f in "$LOG" /var/log/zapret-macos-nfqws.log /var/log/zapret-macos-telegram.log; do
		[ -f "$f" ] && [ "$(stat -f %z "$f")" -gt 1048576 ] || continue
		tail -c 300000 "$f" | tail -n +2 > "$f.tmp" && cat "$f.tmp" > "$f"
		rm -f "$f.tmp"
	done
}
