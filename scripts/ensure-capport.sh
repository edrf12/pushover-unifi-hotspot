#!/bin/sh
set -eu
exec 9>/run/guest-capport.lock
flock -n 9 || exit 0
source=/data/guest-ipv6/vlan250-capport.conf
target=/run/dnsmasq.dhcp.conf.d/zz-guest-capport.conf
test -f /run/dnsmasq.dns.conf.d/main.conf
cmp -s "$source" "$target" && exit 0
pid=$(cat /run/dnsmasq-main.pid)
case "$pid" in ''|*[!0-9]*) exit 1;; esac
tr '\0' ' ' < "/proc/$pid/cmdline" | grep -q '/usr/sbin/dnsmasq.*--pid-file=/run/dnsmasq-main.pid'
cp "$source" "$target.new"
chmod 644 "$target.new"
mv "$target.new" "$target"
/usr/sbin/dnsmasq --test --conf-file=/run/dnsmasq.dns.conf.d/main.conf --conf-dir=/run/dnsmasq.dhcp.conf.d/
kill -TERM "$pid"
n=0
while test "$n" -lt 20; do
    sleep 1
    next=$(cat /run/dnsmasq-main.pid 2>/dev/null || true)
    if test -n "$next" && test "$next" != "$pid" && kill -0 "$next" 2>/dev/null; then exit 0; fi
    n=$((n + 1))
done
rm -f "$target"
exit 1
