#!/bin/sh
set -eu
systemctl stop guest-ipv6.timer guest-ipv6-ap.timer guest-capport.timer 2>/dev/null || true
systemctl stop guest-ipv6.service guest-ipv6-ap.service guest-capport.service 2>/dev/null || true
rm -f /data/on_boot.d/30-guest-ipv6.sh
rm -f /run/systemd/system/guest-ipv6.service /run/systemd/system/guest-ipv6.timer /run/systemd/system/guest-ipv6-ap.service /run/systemd/system/guest-ipv6-ap.timer /run/systemd/system/guest-capport.service /run/systemd/system/guest-capport.timer
systemctl daemon-reload
rm -f /run/dnsmasq.dhcp.conf.d/zz-guest-capport.conf
rm -f /data/guest-ipv6/ensure-*.sh /data/guest-ipv6/vlan250-capport.conf /data/guest-ipv6/ap-enabled
printf '%s\n' 'Installer services and files removed. Existing UniFi rules remain until UniFi reprovisions them.'
