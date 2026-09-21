# UniFi guest IPv6 installer

Run this from an interactive terminal on a workstation that can SSH to the Cloud Gateway and AP:

```sh
curl -fsSL https://raw.githubusercontent.com/edrf12/pushover-unifi-hotspot/main/scripts/install.sh | bash
```

Questions are read directly from the terminal, so the command works with `curl | bash`. It then downloads the gateway/AP/CAPPORT/boot/rollback scripts from the same GitHub revision into a temporary directory and installs them on the gateway.

## Questions asked

The VLAN ID has no default and must be entered. The installer also asks for:

- Gateway SSH host: the Cloud Gateway management IP or name. Console SSH normally uses `root@IP`.
- AP SSH host: the AP management IP and the username configured in **UniFi Network → Settings → System → Device SSH Authentication**.
- CAPPORT HTTPS URL, which must end in the portal's `/capport` endpoint.
- Portal IPv6 address: the address guests can reach directly. Do not use a public CDN or reverse-proxy address when it differs from the portal's local address.
- Confirmation of a newly discovered AP SSH host key.
- An optional guided UniFi Common installation.
- A confirmation after the dedicated gateway-to-AP SSH public key has been added in UniFi.
- A separate confirmation before every persistent gateway file is created or replaced, and before the repair timers apply runtime changes.

The gateway bridge (`br<VLAN>`), AP bridge (`br0.<VLAN>`), gateway global and link-local IPv6 addresses, and UniFi IPv4/IPv6 DHCP tags are detected. Installation stops if any required value is absent or ambiguous. The DHCP tags come from UniFi's provisioned `/run/dnsmasq.dhcp.conf.d/dhcp.dhcpServers-*_br<VLAN>_*.conf` files.

## Prerequisites

- UniFi Common must already execute `/data/on_boot.d`.
- The selected network must be a UniFi hotspot with IPv4 and stateful DHCPv6 configured.
- The external portal must be permitted in UniFi pre-authorization access, including its IPv6 address.
- Local DNS must resolve the portal hostname to the locally reachable portal addresses.
- The portal and its trusted local reverse proxy must already be running.
- The AP must expose the VLAN and UniFi's native guest authorization/drop chains.

On its first run, the installer creates a dedicated AP SSH key on the gateway and prints only its public key. Add that key to UniFi Device SSH Authentication, wait for provisioning, then run the same `curl | bash` command again. The private key remains in `/data/guest-ipv6/ap_ed25519`.

When an AP host key has not been pinned, the installer displays its fingerprint and asks before saving it. Verify the fingerprint independently. A changed existing host key is rejected rather than silently replaced.

## Installed files and behavior

The installer writes separate ensure-gateway.sh, ensure-ap.sh, ensure-ap-remote.sh, ensure-capport.sh, rollback.sh, and CAPPORT files under /data/guest-ipv6, plus /data/on_boot.d/30-guest-ipv6.sh. It names each persistent path and waits for approval before replacing it.

The boot script creates transient systemd unit files under /run automatically at boot; no prompt is possible then. It starts three timers:

- Gateway IPv6 rule restoration every 15 seconds.
- AP IPv6 rule restoration every 30 seconds.
- DHCP option 114 and DHCPv6 option 103 restoration every 30 seconds.

Rules continue to use UniFi's native authorized-guest MAC sets. Unauthenticated clients receive the limited ICMPv6/DHCPv6/DNS/portal access needed to obtain an address and open CAPPORT; ordinary internet access remains gated by UniFi authorization.

If the DHCP CAPPORT file changes, dnsmasq configuration is validated before its verified main process is restarted. That can briefly interrupt DNS/DHCP. Repeated timer runs do not restart it when the file is unchanged.

## Rollback

Every installation records the previous files and DHCP CAPPORT configuration under `/data/guest-ipv6/backups/install.*`. Roll back the most recent installation with:

```sh
/data/guest-ipv6/rollback-guest-ipv6.sh
```

The rollback script asks first to remove rules, then asks separately for every backed-up file it will restore or current file it will remove. It stops timers, removes the installed gateway and AP rules, restores the prior DHCP CAPPORT file and persistent scripts, then restarts the previous boot setup if one existed. The AP SSH private key is never placed in a backup or removed.

The repository also contains [the rollback entry point](../scripts/rollback-guest-ipv6.sh), but the installed copy must be used because it loads the matching local configuration and backup location.

After installation or rollback, reconnect a fresh unauthorized guest and verify IPv6 address assignment, portal discovery, pre-login isolation, approval, and IPv4/IPv6 internet access. Firmware upgrades can change UniFi's internal chain names and require a fresh review.
