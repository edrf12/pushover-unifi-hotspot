#!/bin/sh
set -eu
exec 9>/tmp/guest-ipv6.lock
flock -n 9 || exit 0
test -d /sys/class/net/__AP_BRIDGE__ || exit 0
ipset list guest_authorized_mac 2>/dev/null | grep -qx 'Type: hash:mac' || exit 0
for chain in GUESTIN GUESTOUT; do
    ebtables -t nat -L "$chain" 2>/dev/null | grep -Eq '^-p IPv6 -j DROP *$' || exit 0
done
ensure() {
    chain=$1; expected=$2; shift 2
    ebtables -t nat -L "$chain" | sed 's/ *$//' | grep -Fxq -- "$expected" || ebtables -t nat -I "$chain" 1 "$@"
}
ensure GUESTIN '-p IPv6 --logical-in __AP_BRIDGE__ --set guest_authorized_mac --set-flags src --set-family inet6 -j ACCEPT' -p IPv6 --logical-in __AP_BRIDGE__ --set guest_authorized_mac --set-flags src --set-family inet6 -j ACCEPT
ensure GUESTOUT '-p IPv6 --logical-out __AP_BRIDGE__ --set guest_authorized_mac --set-flags dst --set-family inet6 -j ACCEPT' -p IPv6 --logical-out __AP_BRIDGE__ --set guest_authorized_mac --set-flags dst --set-family inet6 -j ACCEPT
ensure GUESTOUT '-p IPv6 -s __GATEWAY_LINK_LOCAL__ --logical-out __AP_BRIDGE__ --ip6-proto ipv6-icmp --ip6-icmp-type router-advertisement -j ACCEPT' -p IPv6 -s __GATEWAY_LINK_LOCAL__ --logical-out __AP_BRIDGE__ --ip6-proto 58 --ip6-icmp-type 134 -j ACCEPT
ensure GUESTOUT '-p IPv6 -s __GATEWAY_LINK_LOCAL__ --logical-out __AP_BRIDGE__ --ip6-proto ipv6-icmp --ip6-icmp-type neighbour-solicitation -j ACCEPT' -p IPv6 -s __GATEWAY_LINK_LOCAL__ --logical-out __AP_BRIDGE__ --ip6-proto 58 --ip6-icmp-type 135 -j ACCEPT
if ! ebtables -t nat -L GUEST6_BOOT_V1 >/dev/null 2>&1; then
    ebtables -t nat -N GUEST6_BOOT_V1 -P RETURN
    ebtables -t nat -A GUEST6_BOOT_V1 -p IPv6 --ip6-dst ff02::2 --ip6-proto 58 --ip6-icmp-type 133 -j ACCEPT
    ebtables -t nat -A GUEST6_BOOT_V1 -p IPv6 --ip6-dst ff02::1:2 --ip6-proto 17 --ip6-sport 546 --ip6-dport 547 -j ACCEPT
    ebtables -t nat -A GUEST6_BOOT_V1 -p IPv6 --ip6-dst ff02::1:ff00:0/104 --ip6-proto 58 --ip6-icmp-type 135 -j ACCEPT
    ebtables -t nat -A GUEST6_BOOT_V1 -p IPv6 --ip6-dst __GATEWAY_LINK_LOCAL__ --ip6-proto 58 --ip6-icmp-type 135:136 -j ACCEPT
fi
ebtables -t nat -L GUEST6_BOOT_V1 | grep -q 'entries: 4, policy: RETURN' || exit 1
ensure GUESTIN '-p IPv6 --logical-in __AP_BRIDGE__ -j GUEST6_BOOT_V1' -p IPv6 --logical-in __AP_BRIDGE__ -j GUEST6_BOOT_V1
ensure GUESTOUT '-p IPv6 -s __GATEWAY_LINK_LOCAL__ --logical-out __AP_BRIDGE__ --ip6-dst fe80::/ffc0:: --ip6-proto udp --ip6-sport 547 --ip6-dport 546 -j ACCEPT' -p IPv6 -s __GATEWAY_LINK_LOCAL__ --logical-out __AP_BRIDGE__ --ip6-dst fe80::/ffc0:: --ip6-proto 17 --ip6-sport 547 --ip6-dport 546 -j ACCEPT
ensure GUESTOUT '-p IPv6 -s __GATEWAY_LINK_LOCAL__ --logical-out __AP_BRIDGE__ --ip6-dst fe80::/ffc0:: --ip6-proto ipv6-icmp --ip6-icmp-type neighbour-advertisement -j ACCEPT' -p IPv6 -s __GATEWAY_LINK_LOCAL__ --logical-out __AP_BRIDGE__ --ip6-dst fe80::/ffc0:: --ip6-proto 58 --ip6-icmp-type 136 -j ACCEPT
if [ "${portal_sync:-0}" = 1 ]; then
    ipset create guest6_portal hash:net family inet6 -exist
    ipset create guest6_portal_next hash:net family inet6 -exist
    ipset flush guest6_portal_next
    for addr in ${portal_addrs:-}; do ipset add guest6_portal_next "$addr" -exist; done
    ipset swap guest6_portal_next guest6_portal
    ipset destroy guest6_portal_next
fi
for port in 80 443; do
    ensure GUESTIN "-p IPv6 --logical-in __AP_BRIDGE__ --set guest6_portal --set-flags dst --set-family inet6 --ip6-proto tcp --ip6-dport $port -j ACCEPT" -p IPv6 --logical-in __AP_BRIDGE__ --set guest6_portal --set-flags dst --set-family inet6 --ip6-proto tcp --ip6-dport "$port" -j ACCEPT
done
