#!/bin/sh
set -eu
portal_set=$(ipset save UBIOS6guest_pre_allow)
portal_addrs=$(printf '%s\n' "$portal_set" | awk '$1 == "add" {print $3}')
for addr in $portal_addrs; do
    case "$addr" in *[!0-9a-fA-F:/]*) exit 1 ;; esac
done
test -r /data/guest-ipv6/ensure-ap.sh
{ printf 'portal_sync=1\nportal_addrs="%s"\n' "$portal_addrs"; cat /data/guest-ipv6/ensure-ap.sh; } | /usr/bin/ssh -T -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/data/guest-ipv6/ap_known_hosts -o ConnectTimeout=5 -i /data/guest-ipv6/ap_ed25519 __AP_USER__@__AP_HOST__ 'sh -s'
