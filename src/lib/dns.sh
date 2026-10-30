# shellcheck shell=bash
# zapret.sh: DNS. Sourced by src/zapret.sh, which defines the constants.

# encrypted DNS of other people for services that are closed to Russia (neural networks and the like):
# for those they answer with the addresses of their servers abroad, other sites resolve as usual.
# id|name|DoH URL|addresses for the first connection|identifier of the profile on their own site
dns_providers()
{
	cat <<'EOF2'
webshift|WebShift DNS|https://d.webshiftvpn.ru/dns-query|31.31.207.68|ru.webshiftvpn.dns
dnsai|DNS-AI|https://dns.dns-ai.ru/dns-query|194.87.196.13 45.151.102.219|ru.dns-ai.profile
EOF2
}

dns_field() { dns_providers | awk -F'|' -v id="$1" -v n="$2" '$1 == id { print $n; exit }'; }

# identifiers of the installed configuration profiles (profiles needs root for the computer level)
installed_profiles() { profiles list 2>/dev/null | sed -n 's/.*profileIdentifier: *//p'; }

# the provider whose profile is installed, ours or from its site; nothing if none
dns_active()
{
	local ids id
	ids=$(installed_profiles)
	while IFS='|' read -r id _ _ _ theirs; do
		printf '%s\n' "$ids" | grep -qxF -e "com.zapret-macos.dns.$id" -e "$theirs" && { echo "$id"; return; }
	done < <(dns_providers)
}

# the same UUID for the same text, in the form of a random one (version 4): installing the profile again
# replaces it instead of adding another
dns_uuid()
{
	printf '%s' "$1" | shasum | cut -c1-32 | tr a-f A-F |
		sed -E 's/(.{8})(.{4}).(.{3}).(.{3})(.{12})/\1-\2-4\3-8\4-\5/'
}

# the profile macOS installs for the whole system: DoH to the provider. $1 id, $2 file.
# PayloadScope System: at the level of the user macOS can't set up DNS ("couldn't create the VPN service")
dns_profile()
{
	local name url addrs a list="" u1 u2
	name=$(dns_field "$1" 2); url=$(dns_field "$1" 3); addrs=$(dns_field "$1" 4)
	for a in $addrs; do list="$list<string>$a</string>"; done
	u1=$(dns_uuid "zapret-dns-$1-settings")
	u2=$(dns_uuid "zapret-dns-$1")
	cat > "$2" <<EOF2
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PayloadContent</key>
	<array>
		<dict>
			<key>DNSSettings</key>
			<dict>
				<key>DNSProtocol</key><string>HTTPS</string>
				<key>ServerURL</key><string>$url</string>
				<key>ServerAddresses</key><array>$list</array>
			</dict>
			<key>PayloadDisplayName</key><string>$name</string>
			<key>PayloadIdentifier</key><string>com.zapret-macos.dns.$1.settings</string>
			<key>PayloadType</key><string>com.apple.dnsSettings.managed</string>
			<key>PayloadUUID</key><string>$u1</string>
			<key>PayloadVersion</key><integer>1</integer>
		</dict>
	</array>
	<key>PayloadDisplayName</key><string>zapret: $name</string>
	<key>PayloadDescription</key><string>$(msg "Зашифрованный DNS %s для всей системы. Удалить — в zapret или здесь же." "$name")</string>
	<key>PayloadIdentifier</key><string>com.zapret-macos.dns.$1</string>
	<key>PayloadOrganization</key><string>zapret</string>
	<key>PayloadScope</key><string>System</string>
	<key>PayloadRemovalDisallowed</key><false/>
	<key>PayloadType</key><string>Configuration</string>
	<key>PayloadUUID</key><string>$u2</string>
	<key>PayloadVersion</key><integer>1</integer>
</dict>
</plist>
EOF2
}

# removes the profiles of every provider (ours and those from their sites) except $1
dns_remove_others()
{
	local id theirs
	while IFS='|' read -r id _ _ _ theirs; do
		[ "$id" = "$1" ] && continue
		profiles remove -identifier "com.zapret-macos.dns.$id" >/dev/null 2>&1
		profiles remove -identifier "$theirs" >/dev/null 2>&1
	done < <(dns_providers)
}

# our profiles only, for uninstall: one put from a provider's own site belongs to the user
dns_remove_ours()
{
	local id
	while IFS='|' read -r id _; do
		profiles remove -identifier "com.zapret-macos.dns.$id" >/dev/null 2>&1
	done < <(dns_providers)
}

# dns: public DNS 1.1.1.1 for the active connection (some providers answer YouTube with a stub).
# dns webshift|dnsai: that provider for the whole system — macOS installs the profile only after the
# user confirms it in System Settings, so the profile opens there. dns off: no provider.
# dns status [--json]
cmd_dns()
{
	case "$1" in
		"") dns_public ;;
		status)
			need_root dns status "$2"
			local a
			a=$(dns_active)
			if [ "$2" = --json ]; then
				printf '{"dns":%s,"name":%s}\n' "$(jstr "$a")" "$(jstr "$(dns_field "$a" 2)")"
			elif [ -n "$a" ]; then ok "DNS: %s" "$(dns_field "$a" 2)"
			else say "DNS: системный"; fi
			;;
		off)
			need_root dns off
			dns_remove_others ""
			dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null
			log "dns off"
			ok "DNS: системный"
			;;
		*)
			need_root dns "$1"
			[ -n "$(dns_field "$1" 1)" ] || die "dns: %s" "webshift, dnsai, off, status"
			local f
			f=/tmp/zapret-dns-$1.mobileconfig
			dns_profile "$1" "$f"
			chown "$(console_user)" "$f"
			dns_remove_others "$1"
			log "dns $1"
			if [ "$(dns_active)" = "$1" ]; then
				ok "DNS: %s" "$(dns_field "$1" 2)"
				return
			fi
			# the profile appears in System Settings → Profiles (Device Management) and waits there
			as_user open "$f"
			sleep 1
			as_user open "x-apple.systempreferences:com.apple.Profiles-Settings.extension"
			say "Профиль %s открыт в Системных настройках: дважды щёлкнуть по нему и нажать «Установить»." "$(dns_field "$1" 2)"
			;;
	esac
}

# the active network service gets public DNS: some providers answer YouTube with a stub
dns_public()
{
	need_root dns
	local dev svc
	dev=$(route -n get default 2>/dev/null | awk '/interface:/ { print $2; exit }')
	svc=$(networksetup -listnetworkserviceorder | awk -v dev="$dev" '
		/^\([0-9]+\) / { name = $0; sub(/^\([0-9]+\) /, "", name) }
		index($0, "Device: " dev ")") { print name; exit }')
	[ -n "$svc" ] || die "Не удалось найти активное подключение"
	networksetup -setdnsservers "$svc" 1.1.1.1 1.0.0.1 8.8.8.8 || die "Не удалось сменить DNS"
	dscacheutil -flushcache; killall -HUP mDNSResponder 2>/dev/null
	ok "DNS для «%s»: 1.1.1.1, 1.0.0.1, 8.8.8.8" "$svc"
}
