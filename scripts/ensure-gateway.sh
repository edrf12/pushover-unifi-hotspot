#!/bin/sh
set -eu
PATH=/usr/sbin:/usr/bin:/sbin:/bin
exec 9>/run/guest-ipv6.lock
flock -n 9 || exit 0
ipset list UBIOS_authorized_guests 2>/dev/null | grep -qx 'Type: hash:mac' || exit 0
rules=$(ebtables -t nat -L GUESTIN 2>/dev/null) || exit 0
printf '%s\n' "$rules" | grep -q 'policy: DROP' || exit 0
if ! ebtables -t nat -L GUEST6_BOOT_V1 >/dev/null 2>&1; then
    ebtables -t nat -N GUEST6_BOOT_V1 -P RETURN
    ebtables -t nat -A GUEST6_BOOT_V1 -p IPv6 --ip6-dst ff02::2 --ip6-proto 58 --ip6-icmp-type 133 -j ACCEPT
    ebtables -t nat -A GUEST6_BOOT_V1 -p IPv6 --ip6-dst ff02::1:2 --ip6-proto 17 --ip6-sport 546 --ip6-dport 547 -j ACCEPT
    ebtables -t nat -A GUEST6_BOOT_V1 -p IPv6 --ip6-dst ff02::1:ff00:0/104 --ip6-proto 58 --ip6-icmp-type 135 -j ACCEPT
    ebtables -t nat -A GUEST6_BOOT_V1 -p IPv6 --ip6-dst __GATEWAY_LINK_LOCAL__ --ip6-proto 58 --ip6-icmp-type 135:136 -j ACCEPT
fi
ebtables -t nat -L GUEST6_BOOT_V1 | grep -q 'entries: 4, policy: RETURN' || exit 1
printf '%s\n' "$rules" | grep -Eq -- '^-p IPv6 --logical-in __GUEST_BRIDGE__ -j GUEST6_BOOT_V1 *$' || ebtables -t nat -I GUESTIN 1 -p IPv6 --logical-in __GUEST_BRIDGE__ -j GUEST6_BOOT_V1
for proto in tcp udp; do
    expected="-p IPv6 --logical-in __GUEST_BRIDGE__ --ip6-dst __GUEST_DNS__ --ip6-proto $proto --ip6-dport 53 -j ACCEPT"
    ebtables -t nat -L GUESTIN | sed 's/ *$//' | grep -Fxq -- "$expected" || ebtables -t nat -I GUESTIN 1 -p IPv6 --logical-in __GUEST_BRIDGE__ --ip6-dst __GUEST_DNS__ --ip6-proto "$proto" --ip6-dport 53 -j ACCEPT
done
if ipset list UBIOS6guest_pre_allow >/dev/null 2>&1; then
    for port in 80 443; do
        expected="-p IPv6 --logical-in __GUEST_BRIDGE__ --set UBIOS6guest_pre_allow --set-flags dst --set-family inet6 --ip6-proto tcp --ip6-dport $port -j ACCEPT"
        ebtables -t nat -L GUESTIN | sed 's/ *$//' | grep -Fxq -- "$expected" || ebtables -t nat -I GUESTIN 1 -p IPv6 --logical-in __GUEST_BRIDGE__ --set UBIOS6guest_pre_allow --set-flags dst --set-family inet6 --ip6-proto tcp --ip6-dport "$port" -j ACCEPT
    done
fi
if ip6tables -S UBIOS_GUEST_LAN_USER >/dev/null 2>&1; then
    ip6tables -C UBIOS_GUEST_LAN_USER -i __GUEST_BRIDGE__ -d __PORTAL_IPV6__/128 -p tcp -m multiport --dports 80,443 -j ACCEPT 2>/dev/null || ip6tables -I UBIOS_GUEST_LAN_USER 1 -i __GUEST_BRIDGE__ -d __PORTAL_IPV6__/128 -p tcp -m multiport --dports 80,443 -j ACCEPT
fi
printf '%s\n' "$rules" | grep -Eq -- '^-p IPv6 --set UBIOS_authorized_guests --set-flags src --set-family inet6 -j ACCEPT *$' || ebtables -t nat -I GUESTIN 1 -p IPv6 --set UBIOS_authorized_guests --set-flags src --set-family inet6 -j ACCEPT
