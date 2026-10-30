#!/bin/bash
# shellcheck source-path=SCRIPTDIR/..
# shellcheck disable=SC2016,SC2034,SC2329  # eval in single quotes on purpose; the sourced code reads PROJECT and json and calls the stubs
# Fast tests of the logic of zapret.sh: no root, no network, a few seconds. Run: tests/unit.sh
# The script is sourced as a library (ZAPRET_LIB_ONLY), /opt is replaced by temporary folders.

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/rt" "$TMP/project/lists"
export ZAPRET_LIB_ONLY=1 ZAPRET_TEST_RT="$TMP/rt"
# shellcheck source=src/zapret.sh
. "$ROOT/src/zapret.sh"
PROJECT="$TMP/project"
LOG="$TMP/log"
chown() { :; }
install_sudoers() { :; }
launchctl() { :; }
pkill() { :; }
sync_runtime
write_lists

passed=0 failed=0
check() {
	local what=$1
	shift
	if "$@"; then passed=$((passed + 1)); else failed=$((failed + 1)); echo "FAIL: $what"; fi
}
eq() { [ "$1" = "$2" ] || { echo "  получено «$1», ожидалось «$2»"; return 1; }; }
has() { printf '%s' "$1" | grep -qF -- "$2" || { echo "  нет «$2»"; return 1; }; }
lacks() { ! printf '%s' "$1" | grep -qF -- "$2" || { echo "  лишнее «$2»"; return 1; }; }
json() { python3 -I -c 'import json, sys; json.loads(sys.stdin.read())' <<<"$1" || { echo "  не JSON: $1"; return 1; }; }

# strategies
check "Windows-версия по префиксу" is_windows "nfqws general (ALT13)"
check "свои — не Windows" eval '! is_windows "macos (ALT5)"'
check "файл стратегии Windows" eq "$(nfqws_file "nfqws general (SIMPLE FAKE)")" general-simple-fake
check "неизвестная стратегия Windows" eq "$(nfqws_file "nfqws нет такой")" ""
check "стратегии Windows-версии первыми" eq "$(strategy_names | head -1)" "nfqws general"
check "свои после них, адаптивная первой" eq "$(own_names | head -2 | tr '\n' '|')" "Адаптивная|macos|"
check "38 стратегий" eq "$(strategy_names | wc -l | tr -d ' ')" 38
check "параметры своей по имени" has "$(strategy_opts "macos (ALT5)")" "--dpi-desync=multisplit"
check "чужое имя — без параметров" eq "$(strategy_opts "macos; rm -rf /")" ""
check "известное имя" known_name "macos (ALT14)"
check "чужое имя — неизвестное" eval '! known_name "general (ALT99)"'

# host names: only these go into curl, nfqws lists and strategy names
check "адрес из ссылки" eq "$(host_of "https://www.Example.COM/page?x=1")" example.com
check "порт отрезается" eq "$(host_of "site.ru:443")" site.ru
check "поддомены остаются" eq "$(host_of "rr3---sn-abc.googlevideo.com")" rr3---sn-abc.googlevideo.com
check "пробелы — не адрес" eq "$(host_of "not a site")" ""
check "кавычки — не адрес" eq "$(host_of 'a.com"; touch /tmp/x; "')" ""
check "перевод строки — не адрес" eq "$(host_of $'a.com\nb.com')" ""
check "без точки — не адрес" eq "$(host_of localhost)" ""

# configs for each scope, kind of strategy and game filter
c="$TMP/n.conf"
echo all > "$RT/scope"; rm -f "$RT/game"
nfqws_conf "nfqws general (ALT13)" "$c"
check "все сайты: ipset-any" has "$(cat "$c")" "ipset-any.txt"
check "без игр: нет игровых портов" lacks "$(cat "$c")" "1024-65535"
echo smart > "$RT/scope"
nfqws_conf "nfqws general (ALT13)" "$c"
check "умный: автосписок" has "$(cat "$c")" "--hostlist-auto="
check "умный: ipset-none" has "$(cat "$c")" "ipset-none.txt"
echo all > "$RT/scope"; echo all > "$RT/game"
nfqws_conf "nfqws general (ALT13)" "$c"
check "игры TCP и UDP" eq "$(grep -c -- '"1024-65535"' "$c")" 2
check "игры: свой IP-список" has "$(cat "$c")" "ipset-game.txt"
check "плейсхолдеров не осталось" lacks "$(cat "$c")" "@"
nfqws_conf "macos (ALT5)" "$c"
check "своя: параметры вместо @DESYNC@" eq "$(grep -c -- '--dpi-desync=multisplit' "$c")" 5
check "своя: QUIC как в general" has "$(cat "$c")" "quic_initial_www_google_com.bin"
check "своя: игры из шаблона" eq "$(grep -c -- '"1024-65535"' "$c")" 2
check "своя: плейсхолдеров не осталось" lacks "$(cat "$c")" "@"
check "своя: путь к фейкам" has "$(nfqws_conf "macos (ALT8)" "$c"; cat "$c")" "--dpi-desync-split-seqovl-pattern=$RT/nfqws/bin/tls_clienthello_www_google_com.bin"
# the adaptive one: every profile of the template once per rung
nfqws_conf "Адаптивная" "$c"
check "адаптивная: 23 ступени" eq "$(grep -c -- '^--ladder=22$' "$c")/$(grep -c -- '^--ladder=23$' "$c")" "4/0"
check "адаптивная: ступени во всех профилях TCP" eq "$(grep -cE -- '^--ladder=[0-9]+$' "$c")" 92
check "адаптивная: QUIC — 6 ступеней в двух профилях" eq "$(grep -c -- '^--ladder=quic:' "$c")/$(grep -c -- '^--ladder=quic:5$' "$c")" "12/2"
check "адаптивная: голос — 4 ступени" eq "$(grep -c -- '^--ladder=voice:' "$c")" 4
check "адаптивная: пороги автосписка не меняются" eq "$(grep -c -- '^--hostlist-auto-fail-threshold' "$c")" 0
check "адаптивная: файл ступеней один" eq "$(grep -c -- '--ladder-state=' "$c")" 1
check "адаптивная: подъёмы видны в журнале" has "$(cat "$c")" "--hostlist-auto-debug="
check "адаптивная: игровые профили не размножены" eq "$(grep -c -- '"1024-65535"' "$c")" 2
check "адаптивная: плейсхолдеров не осталось" lacks "$(cat "$c")" "@"
rm -f "$LADDER_RUNGS"
printf 'nfqws general\nmacos (ALT7)\n' > "$WORKED"
check "адаптивная: сработавшие на этой сети — первыми" eq "$(ladder_rungs | head -1)" "$(strategy_opts "macos (ALT7)")"
check "адаптивная: себя не включает" lacks "$(ladder_rungs)" "@LADDER@"
ladder_rungs > "$LADDER_RUNGS"
printf 'youtube.com 3\nquic:youtube.com 1\nvoice 2\n' > "$LADDER_STATE"
printf 'macos (ALT2)\n' > "$WORKED"
check "адаптивная: порядок ступеней не меняется после подбора" eq "$(ladder_rungs | head -1)" "$(strategy_opts "macos (ALT7)")"
check "адаптивная: ступени сайтов на месте" eq "$(head -1 "$LADDER_STATE")" "youtube.com 3"
echo "--dpi-desync=fake --приём-которого-нет" >> "$LADDER_RUNGS"
check "адаптивная: исчезнувший приём — порядок заново" eq "$(ladder_rungs | head -1)" "$(strategy_opts "macos (ALT2)")"
check "адаптивная: и ступени сайтов заново, кроме QUIC и голоса" eq "$(cat "$LADDER_STATE" | tr '\n' '|')" "quic:youtube.com 1|voice 2|"
check "сайту нельзя дать адаптивную" eq "$(site_opts "Адаптивная")" ""
ladder_rungs > "$LADDER_RUNGS"
printf 'youtube.com 1\n' > "$LADDER_STATE"
second=$(own_names | awk 'NR > 1' | while IFS= read -r n; do [ "$(strategy_opts "$n")" = "$(sed -n 2p "$LADDER_RUNGS")" ] && echo "$n" && break; done)
check "лестница в JSON" eq "$(cmd_ladder --json)" "[{\"site\":\"youtube.com\",\"kind\":\"tcp\",\"rung\":2,\"trick\":\"$second\",\"kbps\":0}]"
printf 'quic:googlevideo.com 3\nvoice 1\n' > "$LADDER_STATE"
check "лестница QUIC и голоса в JSON" eq "$(cmd_ladder --json)" '[{"site":"googlevideo.com","kind":"quic","rung":4,"trick":"","kbps":0},{"site":"Discord","kind":"voice","rung":2,"trick":"","kbps":0}]'

: > "$LADDER_STATE"
check "лестница пустая — JSON пустой" eq "$(cmd_ladder --json)" "[]"

# the adaptive strategy at work, for its page
printf 'a.com 10 1793350000 2 1500\nb.com 40 1793350001 0 0\n' > "$LADDER_SEEN"
printf '%s\n' '30.10.2026 12:00:00 : www.c.com : profile 3 : client x : proto tls : incoming RST' \
	'30.10.2026 12:00:01 : c.com : profile 3 : client x : proto tls : ladder rung 1' \
	'30.10.2026 12:02:00 : c.com : profile 3 : client x : proto tls : ladder rung 2' \
	'30.10.2026 12:03:00 : d.c.com : profile 3 : client x : proto tls : redirect to another domain' \
	'30.10.2026 12:03:01 : quic:c.com : profile 3 : client x : proto quic : ladder rung 1' \
	'30.10.2026 12:05:00 : a.com : profile 5 : client  : proto tls : ladder rung 2 faster' >> "$AUTO_WHY"
live=$(cmd_ladder --live)
check "вживую: JSON" json "$live"
check "вживую: частые сайты первыми" eq "$(python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); print(" ".join(s["site"] for s in d["sites"]))' "$live")" "b.com a.com"
check "вживую: скорость и ступень" has "$live" '"site":"a.com","connections":10,"last":1793350000,"rung":3,"kbps":1500'
check "вживую: события новые первыми, с причиной" eq "$(python3 -I -c 'import json,sys; d=json.loads(sys.argv[1]); print(" ".join(e["site"]+":"+e["reason"] for e in d["events"]))' "$live")" "a.com:faster quic:c.com:redirect c.com:silence c.com:rst"
: > "$LADDER_SEEN"; : > "$AUTO_WHY"

# the rungs by hand (the fight against slowing down) and learning the order
printf 'youtube.com 3\nquic:youtube.com 1\nvoice 2\n' > "$LADDER_STATE"
ladder_set 5 youtube.com googlevideo.com
check "ступень вручную" eq "$(ladder_get youtube.com)/$(ladder_get googlevideo.com)/$(ladder_get ytimg.com)" "5/5/0"
check "другие лестницы не задеты" eq "$(ladder_get quic:youtube.com)/$(ladder_get voice)" "1/2"
ladder_set 0 youtube.com
check "ступень 0 — строки нет" eq "$(grep -c '^youtube.com ' "$LADDER_STATE")" 0
ladder_rungs > "$LADDER_RUNGS"
third=$(sed -n 3p "$LADDER_RUNGS")
first=$(sed -n 1p "$LADDER_RUNGS")
printf 'a.com 2\nb.com 2\ne.com 2\nc.com 1\nd.com 5\ngooglevideo.com 1\nytimg.com 1\nquic:a.com 2\nvoice 1\n' > "$LADDER_STATE"
echo "Адаптивная" > "$CURRENT"
cmd_start() { :; }
rm -f "$RT/ladder-tuned"
auto_ladder_tune
check "обучение: самый частый приём — первый" eq "$(sed -n 1p "$LADDER_RUNGS")" "$third"
check "обучение: прежний первый — второй" eq "$(sed -n 2p "$LADDER_RUNGS")" "$first"
check "обучение: ступени пересчитаны" eq "$(sort "$LADDER_STATE" | tr '\n' '|')" "c.com 2|d.com 5|googlevideo.com 2|quic:a.com 2|voice 1|ytimg.com 2|"
printf 'a.com 1\nb.com 1\nquic:a.com 2\n' > "$LADDER_STATE"
rm -f "$RT/ladder-tuned"; cp "$LADDER_RUNGS" "$TMP/r2"; auto_ladder_tune
check "обучение: двух сайтов мало" eval 'cmp -s "$LADDER_RUNGS" "$TMP/r2"'
printf 'discord.com 3\ndiscordapp.com 3\ndiscordapp.net 3\ndiscord.gg 3\ndiscord.media 3\nyoutube.com 3\ngooglevideo.com 3\nytimg.com 3\n' > "$LADDER_STATE"
rm -f "$RT/ladder-tuned"; auto_ladder_tune
check "обучение: домены одного сервиса — один сайт" eval 'cmp -s "$LADDER_RUNGS" "$TMP/r2"'
check "обучение: раз в сутки" eval 'cp "$LADDER_RUNGS" "$TMP/r"; auto_ladder_tune; cmp -s "$LADDER_RUNGS" "$TMP/r"'
unset -f cmd_start
. "$ROOT/src/lib/start.sh"

# the search on the ladder: a "speed" that depends on the rung of youtube.com, the engine not restarted
nfqws_reload() { :; }
fake_speed() { [ "$(ladder_get youtube.com)" = 4 ] && echo 900 || echo 10; }
printf 'quic:x.com 1\n' > "$LADDER_STATE"
check "поиск: нашёл ступень" eval 'ladder_search fake_speed 500 10 youtube.com googlevideo.com'
check "поиск: ступень у всех ключей" eq "$(ladder_get youtube.com)/$(ladder_get googlevideo.com)/$LADDER_FOUND_SPEED" "4/4/900"
check "поиск: другие лестницы не задеты" eq "$(ladder_get quic:x.com)" 1
never() { echo 5; }
printf 'youtube.com 2\nquic:x.com 1\n' > "$LADDER_STATE"
check "поиск: лучше нет — ложь" eval '! ladder_search never 500 10 youtube.com googlevideo.com'
check "поиск: лучше нет — всё как было" eq "$(sort "$LADDER_STATE" | tr '\n' '|')" "quic:x.com 1|youtube.com 2|"
count() { echo x >> "$TMP/tries"; echo 1; }
: > "$TMP/tries"; ladder_search count 999 5 a.com
check "поиск: не больше восьми попыток" eq "$(wc -l < "$TMP/tries" | tr -d ' ')" 8
# the quick start: Discord found far up the ladder (past eight tries), YouTube that works left alone
: > "$LADDER_STATE"
echo "$ADAPTIVE" > "$CURRENT"
tests_live() { :; }
yt_speed() { echo 900; }
discord_speed() { [ "$(ladder_get discord.com)" = 12 ] && echo 50 || echo 0; }
ladder_warmup
check "быстрый старт: Discord на дальней ступени" eq "$(ladder_get discord.com)/$(ladder_get discord.media)" "12/12"
check "быстрый старт: YouTube не тронут" eq "$(ladder_get youtube.com)" 0
check "быстрый старт: поиск снят" eval '[ ! -f "$LEARN_BG" ]'
echo "macos" > "$CURRENT"; : > "$LADDER_STATE"
ladder_warmup
check "быстрый старт: только у адаптивной" eq "$(ladder_get discord.com)" 0
rm -f "$CURRENT"
unset -f tests_live yt_speed discord_speed
. "$ROOT/src/lib/sites.sh"; . "$ROOT/src/lib/service.sh"
# what the Telegram proxy saw: a failure after the last success, a recent one, means Telegram doesn't answer
mkdir -p "$(dirname "$TG_STATE")"
now=$(date +%s)
rm -f "$TG_STATE"
check "Telegram: ничего не видел — отвечает" telegram_reachable
printf 'ok %s\nfail %s\n' $((now - 60)) $((now - 10)) > "$TG_STATE"
check "Telegram: свежий сбой после успеха — не отвечает" eval '! telegram_reachable'
printf 'ok %s\nfail %s\n' $((now - 5)) $((now - 10)) > "$TG_STATE"
check "Telegram: успех после сбоя — отвечает" telegram_reachable
printf 'ok %s\nfail %s\ngood 2 relay.co.uk\n' $((now - 900)) $((now - 600)) > "$TG_STATE"
check "Telegram: старый сбой — не считается" telegram_reachable
rm -f "$TG_STATE"
check "секрет прокси: 32 hex" eval '[[ $(telegram_secret) =~ ^[0-9a-f]{32}$ ]]'
check "секрет прокси: тот же после переустановки" eq "$(telegram_secret)" "$(telegram_secret)"
# the relays of the Telegram proxy are left alone by the engine: they get into the exclusions of the run
mkdir -p "$(dirname "$TG_BIN")"
printf '#!/bin/sh\n[ "$1" = relays ] && echo relay.example.co.uk\n' > "$TG_BIN"; chmod +x "$TG_BIN"
write_lists
check "посредники Telegram — в исключениях движка" eval 'grep -qx relay.example.co.uk "$RT/lists/list-exclude.txt"'
check "исключения проекта — на месте" eval '[ "$(grep -c . "$RT/lists/list-exclude.txt")" -gt 1 ]'
rm -f "$TG_BIN"
# the sites used most, for the watchdog
now=$(date +%s)
printf 'a.com 5 %s\nb.com 50 %s\nyoutube.com 900 %s\nold.com 999 %s\ndiscordapp.com 70 %s\nsn-ab.googlevideo.com 80 %s\n' "$now" "$now" "$now" $((now - 300000)) "$now" "$now" > "$LADDER_SEEN"
check "частые сайты: по убыванию, без YouTube, Discord и старых" eq "$(busy_sites 5 | tr '\n' '|')" "b.com|a.com|"
check "частые сайты: не больше заданного" eq "$(busy_sites 1)" b.com
: > "$LADDER_SEEN"
# YouTube video over TCP: QUIC of its servers dropped, first in the adaptive config
rm -f "$RT/video-quic"
nfqws_conf "Адаптивная" "$c"
check "видео по TCP: QUIC видеосерверов отбрасывается" eq "$(grep -n -- '^--drop$' "$c" | cut -d: -f1)/$(grep -c -- '^--hostlist-domains=googlevideo.com$' "$c")" "3/1"
check "адаптивная: учёт сайтов" has "$(cat "$c")" "--ladder-seen="
touch "$RT/video-quic"
nfqws_conf "Адаптивная" "$c"
check "видео по QUIC: ничего не отбрасывается" eq "$(grep -c -- '^--drop$' "$c")" 0
rm -f "$RT/video-quic"
nfqws_conf "macos (ALT5)" "$c"
check "своя стратегия: QUIC не трогается" eq "$(grep -c -- '^--drop$' "$c")" 0
# the generator: a new trick changes one thing of the old one and is a valid line of options
for i in 1 2 3 4 5 6 7 8; do
	m=$(trick_mutate "--dpi-desync=fake,multisplit --dpi-desync-split-pos=1 --dpi-desync-fooling=ts --dpi-desync-repeats=6 --dpi-desync-fake-tls=@BASE@/bin/tls_clienthello_www_google_com.bin")
	pack_line=1; for w in $m; do pack_option_ok "$w" || pack_line=0; done
	[ $pack_line = 1 ] || echo "  недопустимый приём: $m"
	[[ $m == --dpi-desync=* ]] || echo "  без способа: $m"
done
check "генератор: приёмы допустимые" eq "$pack_line" 1
check "генератор: hostfakesplit без места разреза" eval '! TRICK_MODES=hostfakesplit trick_mutate "--dpi-desync=fake" | grep -q split-pos'
check "генератор: прочие параметры остаются" has "$(TRICK_MODES=multisplit trick_mutate "--dpi-desync=multisplit --dpi-desync-autottl=2 --dpi-desync-split-seqovl=1")" "--dpi-desync-autottl=2 --dpi-desync-split-seqovl=1"
check "генератор: перекрытие только при разрезе" lacks "$(TRICK_MODES=multidisorder trick_mutate "--dpi-desync=multidisorder --dpi-desync-split-seqovl=1")" "seqovl"
# the generator over stats: rung 2 fails a lot and no site stays on it, rung 1 is the best
cmd_start() { :; }
trick_ok() { :; }
echo "Адаптивная" > "$CURRENT"
ladder_rungs > "$LADDER_RUNGS"
size0=$(grep -c . "$LADDER_RUNGS")
printf '0 20 1 900\n1 30 0 3000\n2 20 15 100\n3 12 1 800\n' > "$LADDER_STATS"
printf 'a.com 3\n' > "$LADDER_STATE"
old2=$(sed -n 3p "$LADDER_RUNGS")
rm -f "$RT/ladder-evolved" "$LADDER_GEN" "$LADDER_RETIRED"
auto_ladder_evolve
check "генератор: плохая ступень заменена на месте" eval '[ "$(sed -n 3p "$LADDER_RUNGS")" != "$old2" ]'
check "генератор: ступени сайтов не тронуты" eq "$(sed -n 4p "$LADDER_RUNGS")" "$(ladder_rungs | sed -n 4p)"
check "генератор: лестница выросла" eq "$(grep -c . "$LADDER_RUNGS")" $((size0 + 2))
check "генератор: замеры заменённой ступени с нуля" eq "$(awk '$1 == 2' "$LADDER_STATS")" "2 0 0 0"
check "генератор: новые приёмы — свои для лестницы" eq "$(grep -c . "$LADDER_GEN")" 3
check "генератор: раз в сутки" eval 'cp "$LADDER_RUNGS" "$TMP/g"; auto_ladder_evolve; cmp -s "$LADDER_RUNGS" "$TMP/g"'
check "генератор: заменённый приём не возвращается" eval '! ladder_rungs | grep -qxF -- "$old2"'
# the watchdog: YouTube answers even if its page is slow; a lost connection is tried again
as_user() { echo x >> "$TMP/tries"; [ "$(grep -c . "$TMP/tries")" -ge 2 ] && echo 200 || echo 000; }
rm -f "$TMP/tries"; check "сторож: потерянное соединение — ещё раз" yt_answers https://x/
as_user() { echo 000; }
check "сторож: нет ответа — недоступен" eval '! yt_answers https://x/'
unset -f as_user
. "$ROOT/src/lib/helpers.sh"
unset -f cmd_start trick_ok
. "$ROOT/src/lib/start.sh"; . "$ROOT/src/lib/service.sh"
rm -f "$LADDER_RUNGS" "$LADDER_GEN" "$LADDER_RETIRED" "$CURRENT" "$RT/ladder-evolved"; : > "$LADDER_STATS"; : > "$LADDER_STATE"
unset -f nfqws_reload fake_speed never
. "$ROOT/src/lib/nfqws.sh"
: > "$LADDER_STATE"; rm -f "$LADDER_RUNGS" "$CURRENT" "$RT/ladder-tuned"
rm -f "$WORKED" "$LADDER_RUNGS"
rm -f "$RT/game" "$RT/scope"
check "неизвестная стратегия — ошибка" eval '! nfqws_conf "nfqws нет такой" "$c"'

# sites with their own strategy get the first profile
check "параметры Windows-стратегии для сайта" has "$(site_opts "nfqws general (ALT13)")" "--dpi-desync=fake,hostfakesplit"
check "без фильтров и списков" lacks "$(site_opts "nfqws general (ALT13)")" "--hostlist"
check "без кавычек" lacks "$(site_opts "nfqws general (ALT13)")" '"'
check "параметры своей для сайта" eq "$(site_opts "macos (ALT2)")" "--dpi-desync=multidisorder --dpi-desync-split-pos=1"
printf 'example.com\tmacos (ALT3)\n' > "$SITES"
nfqws_conf "nfqws general" "$c"
check "профиль сайта первый" eq "$(head -2 "$c" | tr '\n' ' ')" "--filter-tcp=80,443 --hostlist=$RT/lists/site-1.txt "
check "в профиле сайта — его стратегия" eq "$(sed -n 3,4p "$c" | tr '\n' ' ')" "--dpi-desync=multidisorder --dpi-desync-split-pos=2,sniext+1 "
check "список сайта" eq "$(cat "$RT/lists/site-1.txt")" example.com
: > "$SITES"
nfqws_site_conf "--dpi-desync=fake --dpi-desync-fake-tls=@BASE@/bin/x.bin" "$TMP/s.txt" "$c"
check "конфиг для пробы сайта" eq "$(tr '\n' ' ' < "$c")" "--filter-tcp=80,443 --hostlist=$TMP/s.txt --dpi-desync=fake --dpi-desync-fake-tls=$RT/nfqws/bin/x.bin "

# deep search
check "глубокий подбор: больше 80 вариантов" eval '[ "$(deep_candidates | wc -l)" -gt 80 ]'
check "глубокий подбор: без повторов" eq "$(deep_candidates | sort | uniq -d)" ""
check "глубокий подбор: без кавычек и пробелов в путях" eval '! deep_candidates | grep -q "[\"'"'"']"'

# versions
check "2.10.0 новее 2.9.0" newer 2.10.0 2.9.0
check "одинаковые — не новее" eval '! newer 2.1.0 2.1.0'
check "2.0.9 не новее 2.1.0" eval '! newer 2.0.9 2.1.0'
check "пустая — не новее" eval '! newer "" 2.1.0'

# JSON for the app
check "jstr экранирует" json "$(jstr 'кавычка " и \ слеш')"
json=1
check "событие — JSON" json "$(event result name 'nfqws general "x"' ok 1)"
json=0
check "событие молчит без --json" eq "$(event result name x)" ""
check "status --json" json "$(cmd_status --json)"

# lists
printf '# комментарий\n\na.com\nb.com\n' > "$TMP/list.txt"
check "записи без комментариев" eq "$(count_entries "$TMP/list.txt")" 2
check "нет файла — 0" eq "$(count_entries "$TMP/нет")" 0
check "свой список читается" has "$(user_cat "$TMP/list.txt")" "a.com"

# releases
check "версия из редиректа" eq "$(printf 'HTTP/2 302\r\nLocation: https://github.com/a/b/releases/tag/v3.1.0\r\n\r\n' | release_of)" 3.1.0
check "через несколько переадресаций" eq "$(printf 'HTTP/2 301\r\nLocation: https://github.com/a/c/releases/latest\r\n\r\nHTTP/2 302\r\nLocation: https://github.com/a/c/releases/tag/v4.0.1\r\n\r\n' | release_of)" 4.0.1
check "без релиза — пусто" eq "$(printf 'HTTP/2 302\r\nlocation: https://github.com/a/b/releases\r\n' | release_of)" ""
check "номер версии" valid_version 3.0.0
check "не номер версии" eval '! valid_version "3.0; rm -rf /"'
echo 1.0.0 > "$RT/previous"
check "предыдущая версия" eq "$(VERSION=1.0.1 previous_version)" 1.0.0
check "предыдущая — не та же" eq "$(VERSION=1.0.0 previous_version)" ""
rm -f "$RT/previous"

# signed releases
ssh-keygen -q -t ed25519 -N "" -C test -f "$TMP/key"
ssh-keygen -q -t ed25519 -N "" -C test -f "$TMP/backup"
RELEASE_KEY=$(cut -d' ' -f1,2 "$TMP/key.pub")
RELEASE_KEY_BACKUP=$(cut -d' ' -f1,2 "$TMP/backup.pub")
echo "архив" > "$TMP/a.tar.gz"
ssh-keygen -q -Y sign -f "$TMP/key" -n zapret-release "$TMP/a.tar.gz"
check "подпись сходится" verify_release "$TMP/a.tar.gz" "$TMP/a.tar.gz.sig"
echo "подмена" >> "$TMP/a.tar.gz"
check "подменённый архив не проходит" eval '! verify_release "$TMP/a.tar.gz" "$TMP/a.tar.gz.sig"'
ssh-keygen -q -t ed25519 -N "" -C other -f "$TMP/other"
echo "архив" > "$TMP/b.tar.gz"
ssh-keygen -q -Y sign -f "$TMP/other" -n zapret-release "$TMP/b.tar.gz"
check "чужой ключ не проходит" eval '! verify_release "$TMP/b.tar.gz" "$TMP/b.tar.gz.sig"'
echo "архив" > "$TMP/c.tar.gz"
ssh-keygen -q -Y sign -f "$TMP/backup" -n zapret-release "$TMP/c.tar.gz"
check "запасной ключ проходит" verify_release "$TMP/c.tar.gz" "$TMP/c.tar.gz.sig"
rm -f "$TMP/b.tar.gz.sig"
ssh-keygen -q -Y sign -f "$TMP/key" -n file "$TMP/b.tar.gz" </dev/null
check "подпись для другого назначения не проходит" eval '! verify_release "$TMP/b.tar.gz" "$TMP/b.tar.gz.sig"'

: > "$SITES"; : > "$SITES_TESTED"

# smart mode: what the provider did, from the engine's log; sites learn hasn't looked at
mkdir -p "$(dirname "$AUTO_WHY")"
printf '%s\n' '29.10.2026 01:02:03 : a.com : profile 2 : client 192.168.1.5:5 : proto tls : fail counter 1/3' \
	'29.10.2026 01:02:03 : a.com : profile 2 : client [fe80::1]:5 : proto tls : incoming RST' \
	'29.10.2026 01:02:04 : a.com : profile 2 : client 192.168.1.5:5 : proto tls : adding to /x' \
	'29.10.2026 01:02:05 : b.com : profile 2 : client 1.2.3.4:5 : proto http : redirect to another domain' \
	'29.10.2026 01:02:06 : c.com : profile 2 : client 1.2.3.4:5 : proto tls : retrans threshold reached' > "$AUTO_WHY"
check "причина: сброс" eq "$(found_why a.com)" rst
check "причина: переадресация" eq "$(found_why b.com)" redirect
check "причина: без ответа" eq "$(found_why c.com)" silence
check "причина неизвестна — пусто" eq "$(found_why d.com)" ""
check "причина не путает сайты" eq "$(found_why b.co)" ""
printf 'a.com\nb.com\n' > "$AUTO_LIST"
printf 'b.com\tmacos (ALT3)\n' > "$SITES"
check "таблица найденных" eq "$(found_table | tr '\037' '|')" "$(printf 'a.com||rst\nb.com|macos (ALT3)|redirect')"
check "найденные в JSON" eq "$(cmd_found --json)" '[{"site":"a.com","strategy":"","why":"rst"},{"site":"b.com","strategy":"macos (ALT3)","why":"redirect"}]'
: > "$SITES"
for i in $(seq 900); do echo "29.10.2026 01:02:07 : a.com : profile 2 : client 1.2.3.4:5 : proto tls : fail counter 1/3"; done >> "$AUTO_WHY"
auto_why_trim
check "журнал причин обрезан" eq "$(wc -l < "$AUTO_WHY" | tr -d ' ')" 3
check "причины после обрезки на месте" eq "$(found_why a.com)$(found_why c.com)" rstsilence
check "есть непроверенный найденный сайт" eval 'echo a.com > "$SITES_TESTED"; untested_found'
printf 'bad_name\n' >> "$AUTO_LIST"
echo a.com > "$SITES_TESTED"
check "есть непроверенный найденный сайт" untested_found
echo b.com >> "$SITES_TESTED"
check "все найденные проверены" eval '! untested_found'
: > "$AUTO_LIST"; : > "$AUTO_WHY"; : > "$SITES_TESTED"

# the order of a check: the running one, those that worked, the rest
echo "macos (ALT3)" > "$CURRENT"
printf 'nfqws general (ALT5)\ngeneral (ALT6)\nmacos (ALT3)\n' > "$WORKED"
o=$(strategy_names | check_order)
check "порядок: сначала текущая" eq "$(sed -n 1p <<<"$o")" "macos (ALT3)"
check "порядок: потом сработавшие" eq "$(sed -n 2p <<<"$o")" "nfqws general (ALT5)"
check "порядок: потом остальные" eq "$(sed -n 3p <<<"$o")" "nfqws general"
check "порядок: каждая один раз, исчезнувших нет" eq "$(wc -l <<<"$o" | tr -d ' ')" 38
o=$(windows_names | check_order)
check "порядок --quick: только Windows-версии" eq "$(sed -n 1p <<<"$o")" "nfqws general (ALT5)"
rm -f "$CURRENT" "$WORKED"
check "хорошая: всё, голос, 2 МБ/с" good_enough 4/4 2097152 1
check "без голоса — ищем дальше" eval '! good_enough 4/4 2097152 0'
check "медленная — ищем дальше" eval '! good_enough 4/4 300000 1'
check "не всё открылось — ищем дальше" eval '! good_enough 3/4 2097152 1'

# messages in the user's language
check "по-русски" eq "$(msg "Обновлено до %s" 3.1.0)" "Обновлено до 3.1.0"
UI=en
check "по-английски" eq "$(msg "Обновлено до %s" 3.1.0)" "Updated to 3.1.0"
check "без перевода — как есть" eq "$(msg "Такой строки нет %s" x)" "Такой строки нет x"
check "русские строки не равны в английской локали" eq "$(LANG=en_US.UTF-8 msg "Такой строки нет %s" x)" "Такой строки нет x"
check "ok по-английски" has "$(ok "%s открывается" example.com)" "example.com opens"
check "аргумент с процентом не ломает формат" has "$(ok "%s открывается" "100%s")" "100%s opens"
UI=ru

# why a site doesn't open
check "открылся — open" eq "$(reason_of 0 200 0.05 "" "<html>")" open
check "сервис сам не пускает — geo" eq "$(reason_of 0 403 0.05 "" '{"error":{"code":"unsupported_country_region_territory"}}')" geo
check "переадресация на «недоступно в регионе» — geo" eq "$(reason_of 0 302 0.05 "https://x.example/app-unavailable-in-region" "")" geo
check "451 — geo" eq "$(reason_of 0 451 0.05 "" "")" geo
check "по-русски — geo" eq "$(reason_of 0 403 0.05 "" "Сервис недоступен в вашей стране")" geo
check "обычный 403 — open" eq "$(reason_of 0 403 0.05 "" "Forbidden")" open
check "нет имени — nodns" eq "$(reason_of 6 000 0 "" "")" nodns
check "соединение отклонено — ip" eq "$(reason_of 7 000 0 "" "")" ip
check "не соединилось за время — ip" eq "$(reason_of 28 000 0.000000 "" "")" ip
check "соединилось и повисло — dpi" eq "$(reason_of 28 000 0.041 "" "")" dpi
check "оборвалось на TLS — dpi" eq "$(reason_of 35 000 0.04 "" "")" dpi
check "сброс после соединения — dpi" eq "$(reason_of 56 000 0.04 "" "")" dpi
check "заглушка DNS" is_stub 0.0.0.0
check "локальный адрес — заглушка" is_stub 10.10.34.35
check "обычный адрес — не заглушка" eval '! is_stub 142.250.74.14'

# fresh strategies without a release: only options of the bypass, paths only into their folders
bad_lines=0
while IFS= read -r l; do
	[ -z "$l" ] || pack_option_ok "$l" || { echo "  отвергнута своя строка: $l"; bad_lines=$((bad_lines + 1)); }
done < <(cat "$ROOT"/src/nfqws/strategies/*.conf.in; grep -hv '^#' "$ROOT"/src/nfqws/ladder-*.conf | tr ' ' '\n'; grep -v '^#' "$ROOT/src/nfqws/macos.conf" | cut -d'|' -f2 | grep -v '^@LADDER@$' | tr ' ' '\n'; deep_candidates | tr ' ' '\n')
check "пакет: все строки стратегий проходят" eq "$bad_lines" 0
for l in "--pidfile=/tmp/x" "--debug=@/tmp/x" "--user=root" "--daemon" "--hostlist=/etc/passwd" \
	"--dpi-desync-fake-tls=@BASE@/bin/../../etc/x.bin" "--dpi-desync-fake-tls=/etc/passwd" \
	"--ipset=@LISTS@/../x.txt" '--dpi-desync-fake-tls=$(id)' "--dpi-desync=fake; rm -rf /" \
	"--dpi-desync-fake-tls=@BASE@/x.sh" "--hostlist=@LISTS@/list.sh" "--filter-l3=all"; do
	check "пакет: отвергнуто $l" eval '! pack_option_ok "$l"'
done
"$ROOT/build/pack.sh" "$TMP/pk" >/dev/null 2>&1
mkdir -p "$TMP/pk/x" && tar -xzf "$TMP/pk/pack.tar.gz" -C "$TMP/pk/x"
check "пакет: собранный проходит проверку" pack_valid "$TMP/pk/x"
cp -R "$TMP/pk/x" "$TMP/pk/extra" && echo x > "$TMP/pk/extra/nfqws/run.sh"
check "пакет: лишний файл — нет" eval '! pack_valid "$TMP/pk/extra" 2>/dev/null'
cp -R "$TMP/pk/x" "$TMP/pk/link" && ln -s /etc/passwd "$TMP/pk/link/lists/list-google.txt.x"
check "пакет: ссылка — нет" eval '! pack_valid "$TMP/pk/link" 2>/dev/null'
cp -R "$TMP/pk/x" "$TMP/pk/list" && echo 'evil.example; rm' >> "$TMP/pk/list/lists/list-general.txt"
check "пакет: кривая строка списка — нет" eval '! pack_valid "$TMP/pk/list" 2>/dev/null'
cp -R "$TMP/pk/x" "$TMP/pk/stamp" && echo '1; id' > "$TMP/pk/stamp/STAMP"
check "пакет: кривая метка — нет" eval '! pack_valid "$TMP/pk/stamp" 2>/dev/null'
saved_pack_key=$PACK_KEY
ssh-keygen -q -t ed25519 -N "" -C test -f "$TMP/packkey"
PACK_KEY=$(cut -d' ' -f1,2 "$TMP/packkey.pub")
ssh-keygen -q -Y sign -f "$TMP/packkey" -n zapret-pack "$TMP/pk/pack.tar.gz" </dev/null
check "пакет: подпись ключом пакетов" verify_pack "$TMP/pk/pack.tar.gz" "$TMP/pk/pack.tar.gz.sig"
rm -f "$TMP/pk/pack.tar.gz.sig"
ssh-keygen -q -Y sign -f "$TMP/packkey" -n zapret-release "$TMP/pk/pack.tar.gz" </dev/null
check "пакет: подпись релиза за пакет не сойдёт" eval '! verify_pack "$TMP/pk/pack.tar.gz" "$TMP/pk/pack.tar.gz.sig"'
PACK_KEY=$saved_pack_key
# where the strategies come from: the pack while it is not older than the release
check "без пакета — стратегии релиза" eq "$(nq_dir)" "$RT/nfqws"
cp -R "$TMP/pk/x" "$RT/pack"
check "пакет той же версии — из пакета" eq "$(nq_dir)" "$RT/pack/nfqws"
check "списки — из пакета" eq "$(list_file list-general.txt)" "$RT/pack/lists/list-general.txt"
echo 0.1 > "$RT/pack/nfqws/windows-version"
check "пакет старее релиза — из релиза" eq "$(nq_dir)" "$RT/nfqws"
echo 99.0 > "$RT/pack/nfqws/windows-version"
touch "$RT/pack-off"
check "пакеты выключены — из релиза" eq "$(nq_dir)" "$RT/nfqws"
rm -rf "$RT/pack" "$RT/pack-off"

# DNS for services closed to Russia
dns_profile webshift "$TMP/dns.mobileconfig"
check "профиль DNS — правильный plist" eval 'plutil -lint -s "$TMP/dns.mobileconfig"'
check "профиль DNS — DoH сервиса" has "$(cat "$TMP/dns.mobileconfig")" "<string>https://d.webshiftvpn.ru/dns-query</string>"
check "профиль DNS — постоянный UUID" eq "$(dns_profile webshift /dev/stdout | grep -c "$(sed -n 's/.*<key>PayloadUUID<\/key><string>\(.*\)<\/string>/\1/p' "$TMP/dns.mobileconfig" | head -1)")" 1
profiles() { printf '_computerlevel[1] attribute: profileIdentifier: %s\nThere are 1 configuration profiles installed\n' "$PROFILE"; }
PROFILE=ru.dns-ai.profile
check "профиль с сайта DNS-AI узнаётся" eq "$(dns_active)" dnsai
PROFILE=com.zapret-macos.dns.webshift
check "свой профиль узнаётся" eq "$(dns_active)" webshift
PROFILE=com.example.other
check "чужой профиль — не DNS" eq "$(dns_active)" ""
unset -f profiles

# the best strategy
check "первая — лучшая" better "general" 100 0 "" 0 -1
check "голос важнее скорости" better "general (ALT)" 100 1 "general" 900 0
check "без голоса не обгоняет с голосом" eval '! better "general (ALT)" 900 0 "general" 100 1'
check "заметно быстрее — лучше" better "general (ALT)" 160 1 "general" 100 1
check "чуть быстрее — нет" eval '! better "general (ALT)" 120 1 "general" 100 1'
check "Windows-версия обгоняет свою на равных" better "nfqws general" 90 1 "macos" 100 1
check "своя не обгоняет Windows-версию на равных" eval '! better "macos" 110 1 "nfqws general" 100 1'
check "Windows-версия не обгоняет заметно быструю свою" eval '! better "nfqws general" 50 1 "macos" 100 1'

echo "unit: $passed прошло, $failed не прошло"
[ $failed = 0 ]
