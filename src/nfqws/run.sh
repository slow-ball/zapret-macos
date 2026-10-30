#!/bin/bash
# The engine's service. pf turns the traffic of users (not root) into utun50; utunws (engine/nfq, built by
# build/utunws.sh) applies the strategy and sends the packets itself over BPF to the physical interface.
# IPv4 and, where it works, IPv6. Started by launchd (com.zapret-macos.nfqws) or by the search of strategies.
# When the network changes it restarts the engine for the new one; with no network, or a VPN holding the
# route, it waits.
# Argument: the strategy file (/opt/zapret-macos/nfqws.conf by default).
# SIGHUP: read the strategy file again — only utunws restarts, the network setup and the pf rules stay.
# SIGUSR1: find the network again, as on a change (after sleep).

RT=/opt/zapret-macos
CONF=${1:-$RT/nfqws.conf}
ENGINE=$RT/nfqws/bin/utunws
ANCHOR=com.apple/zapret-macos
TOKEN_FILE=/var/run/zapret-macos.pf-token
KEEPINIT_FILE=/var/db/zapret-macos.keepinit
ENGINE_PID=
GUARD_PID=

flush_pf()
{
	rm -f /var/run/zapret-macos.nfqws-ready /var/run/zapret-macos.nfqws-ipv6
	/sbin/pfctl -a "$ANCHOR" -F all >/dev/null 2>&1
	if [ -s "$TOKEN_FILE" ]; then
		/sbin/pfctl -X "$(cat "$TOKEN_FILE")" >/dev/null 2>&1
		rm -f "$TOKEN_FILE"
	fi
}

# shellcheck disable=SC2317,SC2329  # called by trap
cleanup()
{
	trap - EXIT INT TERM HUP
	flush_pf
	rm -f /var/run/zapret-macos.nfqws-game /var/run/zapret-macos.nfqws-waiting
	[ -n "$GUARD_PID" ] && kill "$GUARD_PID" 2>/dev/null
	if [ -s "$KEEPINIT_FILE" ]; then
		/usr/sbin/sysctl -w net.inet.tcp.keepinit="$(cat "$KEEPINIT_FILE")" >/dev/null
		rm -f "$KEEPINIT_FILE"
	fi
	[ -n "$ENGINE_PID" ] && kill "$ENGINE_PID" 2>/dev/null && wait "$ENGINE_PID" 2>/dev/null
}

trap cleanup EXIT INT TERM
RELOAD=0
RENET=0
trap 'RELOAD=1' HUP
trap 'RENET=1' USR1
[ -x "$ENGINE" ] && [ -f "$CONF" ] || exit 1
flush_pf
pkill -9 -x utunws 2>/dev/null

# a connection the DPI silently drops hangs for 75 seconds before the app tries again; 7 seconds, as in
# Flowseal's port, so a video player recovers quickly. the old value comes back on exit
[ -s "$KEEPINIT_FILE" ] || /usr/sbin/sysctl -n net.inet.tcp.keepinit > "$KEEPINIT_FILE"
/usr/sbin/sysctl -w net.inet.tcp.keepinit=7000 >/dev/null

route_get() { /sbin/route -n get "$@" default 2>/dev/null; }

# the physical interface, its gateway and the gateway's MAC: utunws sends packets past the system
# straight to it. fails without a default route or with a gateway that has no MAC (a VPN tunnel)
detect_net()
{
	IFACE=$(route_get | awk '/interface:/{print $2; exit}')
	GATEWAY=$(route_get | awk '/gateway:/{print $2; exit}')
	[ -n "$IFACE" ] && [ -n "$GATEWAY" ] || return 1
	/sbin/ping -c 1 -t 1 "$GATEWAY" >/dev/null 2>&1
	GATEWAY_MAC=$(/usr/sbin/arp -n "$GATEWAY" | awk '/ at /{print $4; exit}')
	case "$GATEWAY_MAC" in *:*:*:*:*:*) ;; *) return 1 ;; esac
	GATEWAY6=$(route_get -inet6 | awk '/gateway:/{print $2; exit}')
	GATEWAY6_MAC=
	[ -n "$GATEWAY6" ] && GATEWAY6_MAC=$(/usr/sbin/ndp -n "$GATEWAY6" 2>/dev/null |
		awk '{for (i = 1; i <= NF; i++) if ($i ~ /^([0-9a-f]{1,2}:){5}[0-9a-f]{1,2}$/) { print $i; exit }}')
	return 0
}

detect_net || exit 1

# utunws makes utun50 itself; the address is ours
start_engine()
{
	local i=0
	# smart mode: the engine also reads the replies of servers, and sees the provider's resets and
	# redirects (engine/nfq/macrecv.c); not for strategy tests
	local inbound=0
	# the answers of servers: smart mode learns blocked sites from them, the ladder of the adaptive strategy
	# moves sites by them
	scope=$(cat "$RT/scope" 2>/dev/null)
	if [ "$ZAPRET_NO_V6" != 1 ] && { [ "$scope" = smart ] || grep -q -- '^--ladder=' "$CONF"; }; then
		inbound=1
	fi
	# @file is read only when it is the first argument; what the engine says goes to the log
	ZAPRET_IFACE=$IFACE ZAPRET_GATEWAY_MAC=$GATEWAY_MAC ZAPRET_GATEWAY6_MAC=$GATEWAY6_MAC ZAPRET_UTUN_UNIT=51 \
		ZAPRET_INBOUND=$inbound "$ENGINE" "@$CONF" 1>&2 &
	ENGINE_PID=$!
	until /sbin/ifconfig utun50 >/dev/null 2>&1; do
		i=$((i + 1))
		kill -0 "$ENGINE_PID" 2>/dev/null && [ $i -le 100 ] || return 1
		sleep 0.1
	done
	/sbin/ifconfig utun50 10.77.0.1 10.77.0.2 netmask 255.255.255.255 up
}

start_engine || exit 1

# if this script is killed with -9, drop the pf rules anyway: without utunws they would cut the traffic off
(
	while kill -0 $$ 2>/dev/null; do sleep 0.2; done
	/sbin/pfctl -a "$ANCHOR" -F all >/dev/null 2>&1
	pkill -x utunws
) &
GUARD_PID=$!
# not a job of this shell: its end is not reported to the log
disown "$GUARD_PID"

if /sbin/pfctl -s info 2>/dev/null | grep -q '^Status: Disabled'; then
	/sbin/pfctl -E 2>&1 | awk '/Token :/ { print $3 }' > "$TOKEN_FILE"
fi

PORTS_TCP="{80,443,2053,2083,2087,2096,8443}"
PORTS_UDP="{443,19294:19344,50000:50100}"
# game filter (zapret.sh game): ports of game servers go to utunws too. a reload keeps the ports,
# so zapret.sh restarts everything when the game filter changed
GAME=$(cat "$RT/game" 2>/dev/null)
case "$GAME" in
	tcp) PORTS_TCP="{80,443,1024:65535}" ;;
	udp) PORTS_UDP="{443,1024:65535}" ;;
	all) PORTS_TCP="{80,443,1024:65535}"; PORTS_UDP="{443,1024:65535}" ;;
esac

# only packets with the address of the physical interface: a VPN that routes 0/1 and 128.0/1 through
# its tunnel keeps the default route, and its packets sent past the tunnel would be dropped.
# $1=1: IPv6 goes to utunws too; otherwise IPv6 web traffic is rejected and browsers fall back to IPv4 at once.
# pfctl -f warns about the main ruleset on every load
load_rules()
{
	{
		echo "pass out quick route-to (utun50 10.77.0.2) inet proto tcp from ($IFACE) to any port $PORTS_TCP user { >root } no state"
		echo "pass out quick route-to (utun50 10.77.0.2) inet proto udp from ($IFACE) to any port $PORTS_UDP user { >root } no state"
		if [ "$1" = 1 ]; then
			echo "pass out quick route-to (utun50 fd00:7a70::2) inet6 proto tcp from ($IFACE) to any port $PORTS_TCP user { >root } no state"
			echo "pass out quick route-to (utun50 fd00:7a70::2) inet6 proto udp from ($IFACE) to any port $PORTS_UDP user { >root } no state"
		else
			echo "block return out quick inet6 proto tcp from ($IFACE) to any port {80,443} user { >root }"
			echo "block return out quick inet6 proto udp from ($IFACE) to any port 443 user { >root }"
		fi
	} | /sbin/pfctl -a "$ANCHOR" -f - 2>/dev/null
}

v6_ok() { "$@" curl -6 -s -o /dev/null -m 5 https://www.google.com/generate_204; }

# IPv6 through utunws when there is IPv6 at all and a test request as an ordinary user passes.
# strategy tests (ZAPRET_NO_V6=1) skip it: it takes seconds, and IPv4 is enough for them
V6=0
if [ "$ZAPRET_NO_V6" != 1 ] && [ -n "$GATEWAY6_MAC" ] && v6_ok &&
	/sbin/ifconfig utun50 inet6 fd00:7a70::1 fd00:7a70::2 prefixlen 128 2>/dev/null; then
	V6=1
fi
load_rules $V6 || exit 1
if [ $V6 = 1 ] && ! v6_ok sudo -u nobody; then
	echo "IPv6 через utunws не работает, IPv6-сайты пойдут по IPv4" >&2
	V6=0
	load_rules 0 || exit 1
fi
echo $V6 > /var/run/zapret-macos.nfqws-ipv6
echo "${GAME:-off}" > /var/run/zapret-macos.nfqws-game
touch /var/run/zapret-macos.nfqws-ready

# a new strategy: only utunws starts again, with the same network and pf rules
reload()
{
	rm -f /var/run/zapret-macos.nfqws-ready
	kill "$ENGINE_PID" 2>/dev/null
	wait "$ENGINE_PID" 2>/dev/null
	start_engine || exit 1
	[ $V6 = 1 ] && /sbin/ifconfig utun50 inet6 fd00:7a70::1 fd00:7a70::2 prefixlen 128 2>/dev/null
	# the rules name utun50, which is a new interface now
	load_rules $V6 || exit 1
		touch /var/run/zapret-macos.nfqws-ready
}

# another network (Wi-Fi, a cable, waking up, a VPN that took the default route): the engine starts
# again for it, without the rest of the setup. meanwhile the rules are gone and traffic goes as it is;
# while there is no network with a gateway (offline, a full VPN) the script waits for one
renet()
{
	rm -f /var/run/zapret-macos.nfqws-ready
	/sbin/pfctl -a "$ANCHOR" -F all >/dev/null 2>&1
	kill "$ENGINE_PID" 2>/dev/null
	wait "$ENGINE_PID" 2>/dev/null
	touch /var/run/zapret-macos.nfqws-waiting
	until detect_net; do
		sleep 2 &
		wait $!
	done
	rm -f /var/run/zapret-macos.nfqws-waiting
	start_engine || exit 1
	# IPv6 stays only where the new network has it
	[ -n "$GATEWAY6_MAC" ] || V6=0
	[ $V6 = 1 ] && /sbin/ifconfig utun50 inet6 fd00:7a70::1 fd00:7a70::2 prefixlen 128 2>/dev/null
	load_rules $V6 || exit 1
	echo $V6 > /var/run/zapret-macos.nfqws-ipv6
		touch /var/run/zapret-macos.nfqws-ready
	echo "$(date '+%F %T') сеть сменилась: $IFACE, шлюз $GATEWAY" >&2
}

while true; do
	if [ $RELOAD = 1 ]; then RELOAD=0; reload; fi
	if [ $RENET = 1 ]; then RENET=0; renet; fi
	kill -0 "$ENGINE_PID" 2>/dev/null || exit 1
	# in the background: a signal interrupts wait, not sleep
	sleep 2 &
	wait $!
	if [ "$(route_get | awk '/interface:/{print $2; exit}')" != "$IFACE" ] ||
		[ "$(route_get | awk '/gateway:/{print $2; exit}')" != "$GATEWAY" ]; then
		renet
	fi
done
