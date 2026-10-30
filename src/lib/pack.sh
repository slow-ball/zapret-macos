# shellcheck shell=bash
# zapret.sh: fresh strategies without a release. Sourced by src/zapret.sh, which defines the constants.
#
# The strategies of the Windows version, its fake payloads and the site lists come out more often than
# releases. CI packs them (build/pack.sh) and signs the pack with a key of its own, PACK_KEY, in a
# namespace of its own: a pack signature can't pass for a release one. A pack holds no code, and every
# line of it is checked against what a strategy may contain (pack_valid): even a forged one could spoil
# the bypass, not write or run anything. It lives in $RT/pack, apart from the release: while it is newer
# than the release's Windows version, the strategies of the Windows version, the fake payloads and the
# lists come from it (nq_dir, list_file), and without it — from the release again. Our own strategies of
# macOS and the code come only with releases.

PACK_URL="https://github.com/$REPO/releases/download/pack"

# the stamp of a pack: <version of the Windows version>+<UTC date and time of the pack>
pack_stamp() { cat "$RT/pack/STAMP" 2>/dev/null; }
packs_on() { [ ! -f "$RT/pack-off" ]; }

# one line of a strategy file: only options of the bypass, paths only into its own folders
pack_option_ok()
{
	local l=$1 v
	case "$l" in *..*|*'$'*|*'`'*|*\\*) return 1 ;; esac
	[[ $l =~ ^--(new|ip-id=[a-z]+|filter-(tcp|udp)=\"?[0-9,@A-Z_-]+\"?|filter-l3=ipv[46]|filter-l7=[a-z0-9,]+|hostlist(-exclude)?-domains=[a-z0-9.,-]+|(hostlist|hostlist-exclude|hostlist-auto|ipset|ipset-exclude)=.+|dpi-desync(-[a-z0-9]+)*(=.+)?|dup(-[a-z0-9]+)*(=.+)?|orig(-[a-z0-9]+)*(=.+)?)$ ]] || return 1
	# a value with a path: a fake payload of the pack or a list of zapret
	v=${l#*=}
	v=${v//\"/}
	case "$v" in
		*/*) case "$v" in @BASE@/bin/*.bin|@LISTS@/*.txt) ;; *) return 1 ;; esac ;;
		@*) case "$v" in @IPSET@|@GAMEIPSET@|@GAME_TCP@|@GAME_UDP@) ;; *) return 1 ;; esac ;;
	esac
	return 0
}

# a list: domains (^ — this one only, without subdomains), addresses and networks, comments
pack_list_ok() { ! grep -vE '^([#].*|\^?[a-z0-9.*_-]+|[0-9a-f.:]+(/[0-9]+)?|[[:space:]]*)$' "$1" >/dev/null; }

# the unpacked pack in $1 holds only what a pack may hold, and each piece is what it should be
pack_valid()
{
	local d=$1 f rel l
	[[ $(cat "$d/STAMP" 2>/dev/null) =~ ^[0-9.]+[a-z]?\+[0-9]{8}\.[0-9]{4}$ ]] || return 1
	[ -s "$d/nfqws/strategies.tsv" ] || return 1
	while IFS= read -r f; do
		rel=${f#"$d"/}
		case "$rel" in
			STAMP|nfqws/strategies.tsv|nfqws/windows-version|nfqws/ipset-game.txt) ;;
			nfqws/strategies/*.conf.in)
				while IFS= read -r l || [ -n "$l" ]; do
					[ -z "$l" ] || pack_option_ok "$l" || { echo "pack: $rel: $l" >&2; return 1; }
				done < "$f"
				;;
			nfqws/bin/*.bin) [ "$(stat -f %z "$f")" -le 65536 ] || return 1 ;;
			lists/list-general.txt|lists/list-google.txt|lists/list-exclude.txt|lists/ipset-exclude.txt)
				pack_list_ok "$f" || { echo "pack: $rel" >&2; return 1; } ;;
			*) echo "pack: лишний файл $rel" >&2; return 1 ;;
		esac
	done < <(find "$d" -type f)
	# no links, devices or other surprises
	[ -z "$(find "$d" ! -type f ! -type d)" ] || return 1
	awk -F'\t' 'NF != 2 || $1 !~ /^[a-z0-9-]+$/ { bad = 1 } END { exit bad }' "$d/nfqws/strategies.tsv"
}

# a pack is used while it is on and its Windows version is not older than the release's
pack_active()
{
	packs_on && [ -f "$RT/pack/STAMP" ] || return 1
	local mine theirs
	mine=$(cat "$RT/nfqws/windows-version" 2>/dev/null)
	theirs=$(cat "$RT/pack/nfqws/windows-version" 2>/dev/null)
	[ "$theirs" = "$mine" ] || newer "$theirs" "$mine"
}

# where the strategies of the Windows version, the fake payloads and the game addresses come from
nq_dir() { if pack_active; then echo "$RT/pack/nfqws"; else echo "$RT/nfqws"; fi; }
# where a list of zapret comes from: $1 its name, like list-general.txt
list_file() { if pack_active && [ -f "$RT/pack/lists/$1" ]; then echo "$RT/pack/lists/$1"; else echo "$RT/$1"; fi; }

# pack update: the latest pack if it is new, checked and laid over; pack on|off; pack status [--json]
cmd_pack()
{
	case "$1" in
		on)  need_root pack on; rm -f "$RT/pack-off"; ok "свежие стратегии без обновления: включены" ;;
		off) need_root pack off; touch "$RT/pack-off"; rm -rf "$RT/pack"; ok "свежие стратегии без обновления: выключены" ;;
		status)
			if [ "$2" = --json ]; then
				printf '{"on":%s,"stamp":%s}\n' "$(jbool packs_on)" "$(jstr "$(pack_stamp)")"
			elif [ -n "$(pack_stamp)" ]; then ok "свежие стратегии: %s" "$(pack_stamp)"
			else say "свежие стратегии: из релиза"; fi
			;;
		update)
			need_root pack update
			packs_on || return 0
			local tmp stamp was
			tmp=$(mktemp -d)
			if ! curl -fsSL -m 30 -o "$tmp/pack.tar.gz" "$PACK_URL/pack.tar.gz" ||
				! curl -fsSL -m 30 -o "$tmp/pack.tar.gz.sig" "$PACK_URL/pack.tar.gz.sig"; then
				rm -rf "$tmp"; die "Не удалось скачать свежие стратегии"
			fi
			if ! verify_pack "$tmp/pack.tar.gz" "$tmp/pack.tar.gz.sig"; then
				rm -rf "$tmp"; log "pack: подпись не совпала"; die "Подпись свежих стратегий не совпала — не ставлю"
			fi
			mkdir "$tmp/x"
			if ! tar -xzf "$tmp/pack.tar.gz" -C "$tmp/x" || ! pack_valid "$tmp/x"; then
				rm -rf "$tmp"; log "pack: недопустимое содержимое"; die "В свежих стратегиях недопустимое содержимое — не ставлю"
			fi
			stamp=$(cat "$tmp/x/STAMP")
			if [ "$stamp" = "$(pack_stamp)" ] || [ "$stamp" = "$(cat "$RT/pack-bad" 2>/dev/null)" ]; then
				rm -rf "$tmp"; ok "свежие стратегии уже стоят: %s" "$stamp"; return 0
			fi
			rm -rf "$RT/pack.new"
			mv "$tmp/x" "$RT/pack.new"
			chown -R root:wheel "$RT/pack.new"
			chmod -R go-w "$RT/pack.new"
			rm -rf "$RT/pack"
			mv "$RT/pack.new" "$RT/pack"
			rm -rf "$tmp"
			if ! pack_active; then
				rm -rf "$RT/pack"
				ok "в релизе стратегии не старее — свежие не нужны"
				return 0
			fi
			log "pack: $stamp"
			# a pack the engine doesn't take goes, and the release's strategies come back by themselves
			if running; then
				was=$(current)
				if ! cmd_start "$was" >/dev/null 2>&1; then
					echo "$stamp" > "$RT/pack-bad"
					rm -rf "$RT/pack"
					log "pack: $stamp не запустился, убран"
					cmd_start "$was" >/dev/null 2>&1
					die "Свежие стратегии %s не запустились — вернул стратегии релиза" "$stamp"
				fi
			fi
			ok "свежие стратегии: %s" "$stamp"
			;;
		*) die "pack: %s" "update, on, off, status" ;;
	esac
}

# true if $2 signs $1 with the key of packs, in the namespace of packs
verify_pack()
{
	local keys r
	keys=$(mktemp)
	printf 'zapret %s\n' "$PACK_KEY" > "$keys"
	ssh-keygen -Y verify -f "$keys" -I zapret -n zapret-pack -s "$2" < "$1" >/dev/null 2>&1
	r=$?
	rm -f "$keys"
	return $r
}
