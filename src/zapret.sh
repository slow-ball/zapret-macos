#!/bin/bash
# shellcheck source-path=SCRIPTDIR
# zapret-macos: the command line of zapret for macOS — install, strategies, the engine, the services.
# Without arguments it opens a menu; the commands are in usage() (src/lib/menu.sh).

# strings compare byte by byte: awk compares them by the collation of the locale, and in some locales
# two different Russian strings come out equal. LC_ALL would override LC_COLLATE
unset LC_ALL
export LC_COLLATE=C
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SELF="$SRC/$(basename "${BASH_SOURCE[0]}")"
RT=/opt/zapret-macos          # the root-owned copy of the scripts: launchd and the app run it
# tests (only they) put it elsewhere; sudo and launchd never pass this variable
[ "$ZAPRET_LIB_ONLY" = 1 ] && RT=${ZAPRET_TEST_RT:-$RT}
REPO=slow-ball/zapret-macos
# releases are signed with one of these keys (build/release.sh); an update without a valid signature is
# not installed. the backup key is kept off the computer, for when the main one is lost
RELEASE_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJKLGLi13f9yB7KucbwVHTl0yc84E4bt4TJgMI0oNkdl"
# fresh strategies between releases (src/lib/pack.sh) are signed by CI with this key, in a namespace of their own
PACK_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM/apOaxajTADEsTfA4eGS21U/aVI0BmL7uc3UQbtWP+"
RELEASE_KEY_BACKUP="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBANscZ3X47PUq7WCPh/r4aSqI2ouJTC49NI+oKPGSNQ"
NQ_TAG=utunws-1               # the engine's release (build/utunws.sh, workflow Build)
NQ_SHA256=99cdb6e343d700571baa13d7d34530f8b2837b119686efa0fb6065651e8258c7
APPTAG=utunws-1               # the release with zapret-app.zip (workflow Build); empty: the app is built from source
APPSHA256=9f14e93bb2403c1665a4877f3af2d49371c1574d17de433abd774cc811ceaa2b
TG_BIN=$RT/nfqws/bin/zapret-tg   # our Telegram proxy (engine/tg), installed with the engine
TG_STATE=$RT/telegram/state       # what the proxy learned: the way that works, when Telegram last answered
TG_LABEL=com.zapret-macos.telegram
TG_PLIST=/Library/LaunchDaemons/$TG_LABEL.plist
WD_LABEL=com.zapret-macos.watchdog
WD_PLIST=/Library/LaunchDaemons/$WD_LABEL.plist
NQ_LABEL=com.zapret-macos.nfqws
NQ_PLIST=/Library/LaunchDaemons/$NQ_LABEL.plist
NQ_ANCHOR=com.apple/zapret-macos
NQ_READY=/var/run/zapret-macos.nfqws-ready
NQ_UID=2147483647                     # the user the engine drops root to (nfqws's default)
AUTO_LIST=$RT/lists/list-auto.txt     # sites the smart mode found blocked
AUTO_WHY=$RT/lists/list-auto-why.log  # why: the engine's log of what the provider did to them
LEARN_BG=/var/run/zapret-macos.learn.pid  # the background search of smart mode (auto_learn)
LADDER_STATE=$RT/lists/ladder.txt     # the adaptive strategy: the rung of every site (the engine writes it)
LADDER_RUNGS=$RT/lists/ladder-rungs.txt  # its rungs in their order, a line of options each
LADDER_SEEN=$RT/lists/ladder-seen.txt    # the sites it handles: site connections last-seen (the engine)
LADDER_STATS=$RT/lists/ladder-stats.txt  # how each rung does: rung measurements failures avg-kbps (the engine)
LADDER_GEN=$RT/ladder-generated.txt      # tricks the generator made, valid rungs like the own ones
LADDER_RETIRED=$RT/ladder-retired.txt    # tricks the generator replaced: they don't come back as rungs
ADAPTIVE="Адаптивная"                 # the strategy of the engine's ladder (src/nfqws/macos.conf)
DEFAULT_STRATEGY=$ADAPTIVE            # a new install, a reset, a strategy that is gone
SITES=$RT/site-strategies             # site<TAB>strategy, filled by learn and deep
CURRENT=$RT/current                   # the strategy that runs
SITES_TESTED=$RT/site-tested          # sites learn has already looked at
WORKED=$RT/check-worked               # strategies that passed the last check, the best first
LOG=/var/log/zapret-macos.log

if [ "$SRC" = "$RT" ]; then
	PROJECT=$(cat "$RT/project" 2>/dev/null)
elif [ -n "$ZAPRET_PROJECT" ]; then
	# an update runs the new script from its download; the root copy above ignores this
	PROJECT=$ZAPRET_PROJECT
else
	PROJECT=$(dirname "$SRC")
fi
NQ_STRATS="$SRC/nfqws/strategies.tsv"     # the Windows version's
OWN_STRATS="$SRC/nfqws/macos.conf"         # our own
# found by the deep search (cmd_deep). root-owned on purpose: they go into the config of the engine
DSTRATS=$RT/strategies-deep.conf
VERSION=$(cat "$SRC/VERSION" 2>/dev/null)

TESTS="https://www.youtube.com/
https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg
https://redirector.googlevideo.com/generate_204
https://discord.com/"

if [ -t 1 ]; then
	B=$'\e[1m'; G=$'\e[32m'; R=$'\e[31m'; Y=$'\e[33m'; D=$'\e[2m'; N=$'\e[0m'
fi
# messages are Russian printf formats with their arguments; in English their formats come from
# lang/en.tsv (Russian<TAB>English). the language is the one of the user's macOS (see ui_lang)
msg()
{
	local f=$1 e
	shift
	if [ "$UI" = en ]; then
		e=$(awk -F'\t' -v k="$f" '$1 == k { print $2; exit }' "$SRC/lang/en.tsv" 2>/dev/null)
		[ -n "$e" ] && f=$e
	fi
	# shellcheck disable=SC2059  # the format comes from this code or its table
	printf "$f" "$@"
}
say()  { msg "$@"; echo; }
ok()   { echo "  ${G}✓${N} $(msg "$@")"; }
bad()  { echo "  ${R}✗${N} $(msg "$@")"; }
warn() { echo "  ${Y}!${N} $(msg "$@")"; }
die()  { echo "${R}$(msg "$@")${N}" >&2; exit 1; }
log()  { echo "$(date '+%F %T') $*" >> "$LOG"; }

# the code lives in lib/: next to this script, so the root copy in $RT sources root-owned files
# shellcheck source=lib/helpers.sh
. "$SRC/lib/helpers.sh"
# shellcheck source=lib/nfqws.sh
. "$SRC/lib/nfqws.sh"
# shellcheck source=lib/start.sh
. "$SRC/lib/start.sh"
# shellcheck source=lib/telegram.sh
. "$SRC/lib/telegram.sh"
# shellcheck source=lib/sites.sh
. "$SRC/lib/sites.sh"
# shellcheck source=lib/check.sh
. "$SRC/lib/check.sh"
# shellcheck source=lib/diag.sh
. "$SRC/lib/diag.sh"
# shellcheck source=lib/dns.sh
. "$SRC/lib/dns.sh"
# shellcheck source=lib/pack.sh
. "$SRC/lib/pack.sh"
# shellcheck source=lib/service.sh
. "$SRC/lib/service.sh"
# shellcheck source=lib/app.sh
. "$SRC/lib/app.sh"
# shellcheck source=lib/update.sh
. "$SRC/lib/update.sh"
# shellcheck source=lib/menu.sh
. "$SRC/lib/menu.sh"

# ru or en: the first language of the logged in user's macOS. as root too: the app and launchd run
# the script as root, the messages are for the user. ZAPRET_LANG — for tests and the curious
ui_lang()
{
	local u l
	u=$(console_user)
	if [ "$(id -u)" = 0 ]; then
		[ -n "$u" ] && [ "$u" != root ] && l=$(sudo -u "$u" defaults read -g AppleLanguages 2>/dev/null)
	else
		l=$(defaults read -g AppleLanguages 2>/dev/null)
	fi
	l=$(printf '%s\n' "$l" | sed -n '2p' | tr -d ' ",')
	case "$l" in ru*|be*|kk*|ky*|"") echo ru ;; *) echo en ;; esac
}

# tests source this script for its functions only
if [ "$ZAPRET_LIB_ONLY" = 1 ]; then UI=${ZAPRET_LANG:-ru}; return 0; fi
UI=${ZAPRET_LANG:-$(ui_lang)}

# what the user does wins over the background search of smart mode: it stops first and puts back
# the running strategy, then the command goes on (as root: need_root comes back here through sudo)
case "$1" in
	start | stop | check | learn | scope | site | sites-check | deep | game | video | update | repair | reset | pack | uninstall | install | sync)
		[ "$(id -u)" = 0 ] && learn_bg_stop ;;
	found) [ "$2" = clear ] && [ "$(id -u)" = 0 ] && learn_bg_stop ;;
esac

case "$1" in
	"" | menu)  need_root; if [ -x "$RT/zapret.sh" ]; then cmd_menu; else cmd_install && cmd_menu; fi ;;
	install)    shift; cmd_install "$@" ;;
	start)      shift; cmd_start "$@" ;;
	stop)       cmd_stop ;;
	status)     shift; cmd_status "$@" ;;
	list)       strategy_names ;;
	check)      shift; cmd_check "$@" ;;
	diag)       shift; cmd_diag "$@" ;;
	dns)        shift; cmd_dns "$@" ;;
	autostart)  shift; cmd_autostart "$@" ;;
	watchdog)   shift; cmd_watchdog "$@" ;;
	autoupdate) shift; cmd_autoupdate "$@" ;;
	telegram)   shift; cmd_telegram "$@" ;;
	app)        shift; cmd_app "$@" ;;
	# an update of a stopped zapret ends here
	sync)       need_root sync; sync_runtime ;;
	scope)      shift; cmd_scope "$@" ;;
	found)      shift; cmd_found "$@" ;;
	site)       shift; cmd_site "$@" ;;
	sites-check) shift; cmd_sites_check "$@" ;;
	deep)       shift; cmd_deep "$@" ;;
	game)       shift; cmd_game "$@" ;;
	video)      shift; cmd_video "$@" ;;
	learn)      shift; cmd_learn "$@" ;;
	ladder)     shift; cmd_ladder "$@" ;;
	warmup)     need_root warmup; ladder_warmup ;;
	update)     shift; cmd_update "$@" ;;
	repair)     shift; cmd_repair "$@" ;;
	reset)      shift; cmd_reset "$@" ;;
	pack)       shift; cmd_pack "$@" ;;
	uninstall)  shift; cmd_uninstall "$@" ;;
	help|-h|--help) usage ;;
	*)          usage; exit 1 ;;
esac
