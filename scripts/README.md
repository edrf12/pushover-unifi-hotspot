# UniFi guest IPv6 installer

Run the guided installer from a workstation that can SSH to the Cloud Gateway Ultra and access point:

```sh
curl -fsSL https://raw.githubusercontent.com/edrf12/pushover-unifi-hotspot/main/scripts/install.sh | bash
```

The installer asks for the gateway SSH host, the AP SSH host, the guest VLAN ID, the public CAPPORT URL, and the portal's locally reachable IPv6 address. It explains where to find each value in UniFi or on the portal host. It derives the gateway bridge as `br<VLAN>`, the AP bridge as `br0.<VLAN>`, the gateway IPv6 addresses, and the IPv4/DHCPv6 tags from the provisioned UniFi configuration. It stops if any discovered value is missing or ambiguous.

Find the VLAN ID in **UniFi Network → Settings → Networks → guest network → VLAN ID**. Use the management addresses for the gateway and AP. The AP username is configured in **UniFi Network → Settings → System → Device SSH Authentication**. The portal IPv6 address must be the address that a guest can reach directly; configure local DNS so the portal hostname resolves to that address for guests, and add it to the hotspot's pre-authorization access list.

The installer asks whether to install or refresh UniFi Common automatically, then downloads the component scripts, generates a dedicated Ed25519 key on the gateway, waits for that key to be added under UniFi Device SSH Authentication, and installs the persistent repair services.

Before creating or replacing the AP key, each persistent script, the CAPPORT DHCP configuration, the boot hook, or the rollback command, it names the target path and asks for approval. It asks once more before starting the repair timers and applying the runtime rules.

When selected, it downloads UniFi Common's upstream installer to a temporary gateway file, displays its SHA-256 checksum, and asks for confirmation before running it as root. The gateway must reach GitHub. Choosing `n` assumes UniFi Common is already installed and runs the on-boot directory.

The effective changes are kept separate:

- `ensure-gateway.sh` restores gateway IPv6 setup, DNS, portal reachability, and authorized-guest forwarding.
- `ensure-ap-remote.sh` securely sends the AP repair script and portal allowlist to the AP.
- `ensure-ap.sh` restores AP IPv6 authorization, router discovery, DHCPv6, and portal rules.
- `ensure-capport.sh` advertises CAPPORT through DHCP option 114 and DHCPv6 option 103.
- `30-guest-ipv6.sh` creates the boot and provisioning timers.
- `rollback.sh` is installed as `unifi-guest-ipv6-rollback` on the gateway.

Set `SCRIPT_BASE_URL` to use a fork or a pinned release. The scripts assume UniFi has already created the guest network, hotspot, IPv6 prefix, native guest authorization sets, and `UBIOS_GUEST_LAN_USER` chain. They fail closed when those prerequisites are absent.
