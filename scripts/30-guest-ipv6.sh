#!/bin/sh
set -eu
mkdir -p /run/systemd/system
cat > /run/systemd/system/guest-ipv6.service <<'UNIT'
[Unit]
Description=Restore guest IPv6 rules
[Service]
Type=oneshot
ExecStart=/data/guest-ipv6/ensure-gateway.sh
UNIT
cat > /run/systemd/system/guest-ipv6.timer <<'UNIT'
[Unit]
Description=Check guest IPv6 rules
[Timer]
OnBootSec=20s
OnUnitActiveSec=15s
Unit=guest-ipv6.service
UNIT
cat > /run/systemd/system/guest-ipv6-ap.service <<'UNIT'
[Unit]
Description=Restore AP guest IPv6 rules
[Service]
Type=oneshot
TimeoutStartSec=20s
ExecStart=/data/guest-ipv6/ensure-ap-remote.sh
UNIT
cat > /run/systemd/system/guest-ipv6-ap.timer <<'UNIT'
[Unit]
Description=Check AP guest IPv6 rules
[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
Unit=guest-ipv6-ap.service
UNIT
cat > /run/systemd/system/guest-capport.service <<'UNIT'
[Unit]
Description=Restore guest CAPPORT DHCP discovery
[Service]
Type=oneshot
TimeoutStartSec=30s
ExecStart=/data/guest-ipv6/ensure-capport.sh
UNIT
cat > /run/systemd/system/guest-capport.timer <<'UNIT'
[Unit]
Description=Check guest CAPPORT discovery
[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
Unit=guest-capport.service
UNIT
systemctl daemon-reload
systemctl start guest-ipv6.timer guest-ipv6-ap.timer guest-capport.timer
systemctl start guest-ipv6.service guest-ipv6-ap.service guest-capport.service
