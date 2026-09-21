#!/usr/bin/env bash
set -Eeuo pipefail

# Guided installer. Run with:
# curl -fsSL https://raw.githubusercontent.com/edrf12/pushover-unifi-hotspot/main/scripts/install.sh | bash

BASE_URL="${SCRIPT_BASE_URL:-https://raw.githubusercontent.com/edrf12/pushover-unifi-hotspot/main/scripts}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
die_with_help() { printf 'Error: %s\n\n%s\n' "$1" "$2" >&2; exit 1; }
need() { command -v "$1" >/dev/null || die "Required command not found: $1"; }
ask() { local prompt=$1 default=${2-} answer; read -r -p "$prompt${default:+ [$default]}: " answer </dev/tty; printf '%s' "${answer:-$default}"; }
yes_no() { local answer; read -r -p "$1 [Y/n]: " answer </dev/tty; [[ -z "$answer" || "$answer" =~ ^[Yy]([Ee][Ss])?$ ]]; }
confirm_file() {
  printf '\nThis will create or replace: %s\n' "$1"
  yes_no 'Continue with this file?'
}
for command in ssh scp ssh-keygen curl ssh-keyscan; do need "$command"; done
[[ $EUID -ne 0 ]] || die 'Run this on your workstation, not as root.'
[[ -r /dev/tty && -w /dev/tty ]] || die 'Run this from an interactive terminal so the installer can ask questions.'

printf '%s\n' 'UniFi guest IPv6 + CAPPORT installer' '' \
  'This installs persistent IPv6 and CAPPORT repair on the gateway and AP.' \
  'UniFi remains the source of guest authorization.' '' \
  'Before continuing, create the guest network, enable its hotspot, and enable IPv6.' \
  'Add the portal IPv6 address to the hotspot pre-authorization list in UniFi Network.' ''
printf '%s\n' 'Gateway SSH host: Cloud Gateway Ultra management address. Console SSH normally uses root@IP.'
GATEWAY_HOST="$(ask 'Gateway SSH host' 'root@gateway.example')"
printf '%s\n' '' 'AP SSH host: AP management address with the username in UniFi Network → Settings → System → Device SSH Authentication.'
AP_HOST="$(ask 'Access point SSH host' 'ap-user@ap.example')"
printf '%s\n' '' 'VLAN ID: find it in UniFi Network → Settings → Networks → your guest network → VLAN ID.'
VLAN_ID="$(ask 'Guest VLAN ID')"
[[ "$VLAN_ID" =~ ^[1-9][0-9]{0,3}$ && "$VLAN_ID" -le 4094 ]] || die 'VLAN ID must be between 1 and 4094.'
GUEST_BRIDGE="br$VLAN_ID"
AP_BRIDGE="br0.$VLAN_ID"
printf '%s\n' '' 'CAPPORT URL: the public HTTPS URL for the portal /capport endpoint.'
PORTAL_URL="$(ask 'CAPPORT URL' 'https://portal.example.invalid/capport')"
printf '%s\n' 'Portal IPv6 address: the address guests can reach directly, not a public CDN/proxy address.' \
  'Find it in the portal host or container network settings. A local DNS override must resolve the portal hostname to it.'
PORTAL_IPV6="$(ask 'Portal IPv6 address' '2001:db8:200::10')"
AP_USER="${AP_HOST%@*}"; AP_ADDRESS="${AP_HOST#*@}"
[[ "$PORTAL_URL" == https://* ]] || die 'CAPPORT URL must use HTTPS.'
[[ "$PORTAL_URL" != *'|'* && "$PORTAL_URL" != *'&'* ]] || die 'CAPPORT URL cannot contain | or &.'
[[ "$GATEWAY_HOST" == *@* && "$AP_HOST" == *@* ]] || die 'SSH hosts must include a user.'
INSTALL_COMMON=0
yes_no 'Install or refresh UniFi Common on the gateway automatically?' && INSTALL_COMMON=1

printf '\nDownloading installer components from %s...\n' "$BASE_URL"
for file in 30-guest-ipv6.sh ensure-gateway.sh ensure-ap-remote.sh ensure-ap.sh ensure-capport.sh vlan250-capport.conf rollback.sh; do
  curl --fail --silent --show-error --location "$BASE_URL/$file" -o "$TMP_DIR/$file"
done
for file in 30-guest-ipv6.sh ensure-gateway.sh ensure-ap-remote.sh ensure-ap.sh ensure-capport.sh rollback.sh; do
  bash -n "$TMP_DIR/$file" || die "Downloaded $file has invalid shell syntax."
done
printf '\nChecking SSH access...\n'
ssh -o BatchMode=yes -o ConnectTimeout=8 "$GATEWAY_HOST" true || die 'Cannot SSH to the gateway.'
ssh -o BatchMode=yes -o ConnectTimeout=8 "$AP_HOST" true || die 'Cannot SSH to the AP.'

printf '\nDiscovering the UniFi network values for VLAN %s...\n' "$VLAN_ID"
ssh "$GATEWAY_HOST" "test -d /sys/class/net/$GUEST_BRIDGE" || die_with_help \
  "The gateway does not have $GUEST_BRIDGE." \
  "Confirm the VLAN ID in UniFi Network → Settings → Networks, then provision the guest network before running this installer."
GUEST_DNS="$(ssh "$GATEWAY_HOST" "ip -6 -o addr show dev $GUEST_BRIDGE scope global | awk '{sub(/\\/.*/, \"\", \$4); print \$4}'")"
GATEWAY_LINK_LOCAL="$(ssh "$GATEWAY_HOST" "ip -6 -o addr show dev $GUEST_BRIDGE scope link | awk '{sub(/\\/.*/, \"\", \$4); print \$4}'")"
[[ -n "$GUEST_DNS" && "$GUEST_DNS" != *$'\n'* ]] || die_with_help \
  "Could not find one global IPv6 address on $GUEST_BRIDGE." \
  "Enable IPv6 on the guest network in UniFi, wait for it to provision, then run the installer again."
[[ -n "$GATEWAY_LINK_LOCAL" && "$GATEWAY_LINK_LOCAL" != *$'\n'* ]] || die_with_help \
  "Could not find one link-local IPv6 address on $GUEST_BRIDGE." \
  "Wait for the guest network to provision, then run the installer again."
DHCP_TAGS="$(ssh "$GATEWAY_HOST" "for path in /run/dnsmasq.dhcp.conf.d/dhcp.dhcpServers-*_${GUEST_BRIDGE}_*.conf; do [ -f \"\$path\" ] || continue; tag=\${path##*/dhcp.dhcpServers-}; printf '%s\\n' \"\${tag%.conf}\"; done")"
GUEST_IPV4_TAG="$(printf '%s\n' "$DHCP_TAGS" | awk 'NF && !/_IPV6$/ { print }')"
GUEST_IPV6_TAG="$(printf '%s\n' "$DHCP_TAGS" | awk '/_IPV6$/ { print }')"
[[ -n "$GUEST_IPV4_TAG" && "$GUEST_IPV4_TAG" != *$'\n'* && -n "$GUEST_IPV6_TAG" && "$GUEST_IPV6_TAG" != *$'\n'* ]] || die_with_help \
  "Could not infer exactly one IPv4 and one IPv6 DHCP tag for VLAN $VLAN_ID." \
  "Create stateful DHCPv6 for the guest network in UniFi, wait for provisioning, then run the installer again."
ssh "$GATEWAY_HOST" "ipset test UBIOS6guest_pre_allow '$PORTAL_IPV6'" >/dev/null 2>&1 || die_with_help \
  "The portal IPv6 address is not in UniFi's IPv6 pre-authorization set." \
  "In the guest hotspot settings, add $PORTAL_IPV6 to Pre-Authorization Access, save, wait for provisioning, then run this installer again."
printf '%s\n' \
  "  gateway bridge: $GUEST_BRIDGE" \
  "  AP bridge: $AP_BRIDGE" \
  "  guest DNS: $GUEST_DNS" \
  "  gateway link-local IPv6: $GATEWAY_LINK_LOCAL" \
  "  IPv4 DHCP tag: $GUEST_IPV4_TAG" \
  "  IPv6 DHCP tag: $GUEST_IPV6_TAG"

if [ "$INSTALL_COMMON" = 1 ]; then
  printf '\nDownloading the UniFi Common installer to the gateway...\n'
  ssh "$GATEWAY_HOST" 'curl --fail --silent --show-error --location https://raw.githubusercontent.com/unifi-utilities/unifi-common/HEAD/remote_install.sh -o /tmp/unifi-common-install.sh; sha256sum /tmp/unifi-common-install.sh; printf "Review the downloaded script above.\n"'
  read -r -p 'Run this downloaded UniFi Common installer as root on the gateway? [y/N]: ' run_common </dev/tty
  [[ "$run_common" =~ ^[Yy]([Ee][Ss])?$ ]] || die 'UniFi Common installation was not confirmed.'
  ssh "$GATEWAY_HOST" '/bin/bash /tmp/unifi-common-install.sh; rm -f /tmp/unifi-common-install.sh'
  ssh "$GATEWAY_HOST" 'test -d /data/on_boot.d || test -d /mnt/data/on_boot.d' || die 'UniFi Common did not create an on_boot.d directory.'
fi

printf '\nGenerating a dedicated gateway-to-AP key...\n'
confirm_file '/data/guest-ipv6/ap_ed25519 (created only when it does not already exist)' || die 'Installation cancelled before creating the AP key.'
ssh "$GATEWAY_HOST" 'mkdir -p /data/guest-ipv6; chmod 700 /data/guest-ipv6; if [ ! -s /data/guest-ipv6/ap_ed25519 ]; then ssh-keygen -q -t ed25519 -N "" -f /data/guest-ipv6/ap_ed25519; fi; cat /data/guest-ipv6/ap_ed25519.pub' > "$TMP_DIR/ap-key.pub"
cat "$TMP_DIR/ap-key.pub"
printf '\nAdd that public key in UniFi Network → Settings → System → Device SSH Authentication.\n'
read -r -p 'Press Enter after saving the key in UniFi: ' _ </dev/tty

printf '\nInstalling gateway files...\n'
for target in \
  /data/guest-ipv6/ensure-gateway.sh \
  /data/guest-ipv6/ensure-ap-remote.sh \
  /data/guest-ipv6/ensure-ap.sh \
  /data/guest-ipv6/ensure-capport.sh \
  /data/guest-ipv6/vlan250-capport.conf \
  /data/on_boot.d/30-guest-ipv6.sh \
  /usr/local/bin/unifi-guest-ipv6-rollback; do
  confirm_file "$target" || die "Installation cancelled before changing $target."
done
scp "$TMP_DIR/30-guest-ipv6.sh" "$TMP_DIR/ensure-gateway.sh" "$TMP_DIR/ensure-ap-remote.sh" "$TMP_DIR/ensure-ap.sh" "$TMP_DIR/ensure-capport.sh" "$TMP_DIR/vlan250-capport.conf" "$TMP_DIR/rollback.sh" "$GATEWAY_HOST:/tmp/"
ssh "$GATEWAY_HOST" "sed -i -e 's|__GUEST_BRIDGE__|$GUEST_BRIDGE|g' -e 's|__AP_HOST__|$AP_ADDRESS|g' -e 's|__AP_USER__|$AP_USER|g' -e 's|__AP_BRIDGE__|$AP_BRIDGE|g' -e 's|__GUEST_IPV4_TAG__|$GUEST_IPV4_TAG|g' -e 's|__GUEST_IPV6_TAG__|$GUEST_IPV6_TAG|g' -e 's|__PORTAL_IPV6__|$PORTAL_IPV6|g' -e 's|__GUEST_DNS__|$GUEST_DNS|g' -e 's|__PORTAL_URL__|$PORTAL_URL|g' -e 's|__GATEWAY_LINK_LOCAL__|$GATEWAY_LINK_LOCAL|g' /tmp/ensure-gateway.sh /tmp/ensure-ap-remote.sh /tmp/ensure-ap.sh /tmp/ensure-capport.sh /tmp/vlan250-capport.conf /tmp/rollback.sh; install -d -m 700 /data/guest-ipv6 /data/on_boot.d; install -m 700 /tmp/ensure-gateway.sh /tmp/ensure-ap-remote.sh /tmp/ensure-capport.sh /tmp/ensure-ap.sh /data/guest-ipv6/; install -m 600 /tmp/vlan250-capport.conf /data/guest-ipv6/; install -m 700 /tmp/30-guest-ipv6.sh /data/on_boot.d/; install -m 700 /tmp/rollback.sh /usr/local/bin/unifi-guest-ipv6-rollback"

printf '\nInstalling AP files and pinning its host key...\n'
ssh-keyscan -H "$AP_ADDRESS" > "$TMP_DIR/ap_known_hosts" 2>/dev/null || die 'Could not read the AP host key.'
scp "$TMP_DIR/ap_known_hosts" "$GATEWAY_HOST:/data/guest-ipv6/ap_known_hosts"
ssh "$GATEWAY_HOST" "ssh -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/data/guest-ipv6/ap_known_hosts -i /data/guest-ipv6/ap_ed25519 $AP_HOST true" || die 'The AP does not accept the generated key.'
ssh "$GATEWAY_HOST" "install -m 700 /tmp/ensure-ap.sh /data/guest-ipv6/ensure-ap.sh; touch /data/guest-ipv6/ap-enabled"

printf '\nEnabling IPv6 firewall repair and CAPPORT DHCP advertisements...\n'
yes_no 'Start the repair timers and apply the runtime firewall/DHCP changes now?' || die 'Installation completed without enabling the services.'
ssh "$GATEWAY_HOST" '/data/on_boot.d/30-guest-ipv6.sh'
ssh "$GATEWAY_HOST" 'systemctl is-active guest-ipv6.timer guest-ipv6-ap.timer guest-capport.timer'
cat <<EOF

Installation complete.

Rollback command:
  sudo /usr/local/bin/unifi-guest-ipv6-rollback

Test a new guest by checking for an IPv6 address and opening:
  $PORTAL_URL
EOF
