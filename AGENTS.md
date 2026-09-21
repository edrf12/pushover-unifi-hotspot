# Project overview

`pushover-unifi-hotspot` is a small Rust/Axum service that approves UniFi guest access through Pushover. It also exposes an RFC 8908 CAPPORT endpoint and includes shell scripts that repair UniFi guest IPv6/CAPPORT behavior on a Cloud Gateway and access point.

Keep the project as one containerized Rust service plus the UniFi installation scripts. Do not introduce a frontend toolchain, persistent database, or another service unless requested.

## Repository map

- `src/main.rs`: all application configuration, routes, UniFi and Pushover calls, in-memory session coordination, CAPPORT handling, and SSE.
- `src/pages/status.html`: embedded status page served at `/`.
- `src/pages/waiting.html`: embedded approval page; uses browser `EventSource`.
- `src/pages/authorized.html`: embedded success page.
- `Cargo.toml` / `Cargo.lock`: Rust 2024 application using Axum, Tokio, Reqwest, Clap, Serde, UUID, `futures-util`, `axum-client-ip`, and `axum-extra`.
- `Dockerfile`: Rust Bookworm builder and Fedora Minimal 44 runtime; runs as UID/GID 10001 and listens on port 3000.
- `README.md`: service deployment, UniFi setup, and IPv6 installer overview.
- `docs/guest-ipv6-install.md`: detailed operator guide for the UniFi IPv6/CAPPORT installer.
- `scripts/README.md`: shorter description of the installer and installed components.
- `scripts/install.sh`: interactive workstation entry point that discovers UniFi values and installs the remaining scripts.
- `scripts/30-guest-ipv6.sh`: gateway boot hook that creates transient systemd services and timers.
- `scripts/ensure-gateway.sh`: restores gateway guest IPv6, DNS, portal, and authorized-client rules.
- `scripts/ensure-ap-remote.sh`: invokes the AP repair over the dedicated gateway-to-AP SSH connection.
- `scripts/ensure-ap.sh`: restores AP guest IPv6 bootstrap, authorization, and portal rules.
- `scripts/ensure-capport.sh`: restores DHCP option 114 and DHCPv6 option 103, validating dnsmasq before restart.
- `scripts/vlan250-capport.conf`: dnsmasq template populated by the installer. The filename is historical; installer placeholders select the actual VLAN tags.
- `scripts/rollback.sh`: installed rollback command that stops the timers and removes installed files; it does not restore backups or remove every runtime firewall rule immediately.

There is currently no `src/tests.rs` or committed Rust test suite. HTML is embedded with `include_str!`, so page changes require rebuilding the binary. There is no JavaScript framework or frontend build step.

## Application routes and flow

- `GET /` serves the service-status page.
- `GET /waiting` serves the browser approval page.
- `GET /authorized` serves the success page.
- `GET /guest/s/default/` starts or reuses approval. UniFi supplies `id` as the client MAC and may supply `ssid`; missing SSID is treated as `Wired`.
- `GET /guest/events` streams approval state over SSE using `session` and client MAC `id` query parameters.
- `POST /guest/callback` accepts Pushover form fields `receipt` and `acknowledged`.
- `GET /capport` returns `application/captive+json` for the requesting guest.

The portal flow is:

1. Look up the connected client through the UniFi integration API by MAC. The resulting UniFi client ID is distinct from the MAC in the portal URL.
2. Send already-authorized clients to `/authorized`.
3. Reserve a session under the UniFi client ID. Concurrent portal requests reuse it and must not send duplicate notifications.
4. Redirect immediately to `/waiting?session=<browser-token>&id=<MAC>` and send the Pushover emergency notification in the background.
5. Save the returned Pushover receipt only if the browser token still identifies the same session.
6. Stream `waiting`, `authorized`, `failed`, or `expired` events to the browser.
7. On an acknowledged callback, locate the pending session by its secret receipt, reserve authorization, and call UniFi with `AUTHORIZE_GUEST_ACCESS`.
8. Publish `Authorized` only after UniFi succeeds and retain the terminal session for reconnecting browsers.

CAPPORT trusts `X-Real-IP`, configured through `axum-client-ip`. IPv4 clients are found directly through the integration API. IPv6 clients are first matched to a MAC with the legacy `/proxy/network/api/s/{site}/stat/sta` endpoint, then resolved through the integration API. The generated user portal URL must use HTTPS. Reverse proxies must replace `X-Real-IP` with the actual guest address; do not trust a client-supplied forwarding header.

## State and security invariants

`AppState` owns an `Arc<Config>`, one reusable 30-second-timeout `reqwest::Client`, and an `Arc<tokio::sync::Mutex<HashMap<String, ClientSession>>>`.

- The session map is keyed by UniFi client ID, not MAC or receipt.
- Insert `receipt: None` under the same map lock used to check for reuse, then release the lock before network calls.
- Keep the random browser UUID separate from the Pushover receipt.
- Match the browser token when completing a background notification so a stale result cannot overwrite a newer session.
- Receipt lookup intentionally scans this small map. Do not add client locks or a receipt index without a concrete need.
- `authorizing_until` prevents overlapping callbacks and lets a later callback recover if an attempt is cancelled.
- Failed authorization releases the reservation; successful authorization clears the receipt and retains the browser update.
- Never put receipts, API keys, Pushover credentials, or `.env` values in browser responses, URLs, documentation, images, or logs.
- The callback deliberately does not call Pushover's receipt-verification API. It relies on the secret receipt plus `acknowledged=1`; preserve that design unless asked to change it.
- Unknown receipts and active authorization attempts return HTTP 503. Expired matching sessions return HTTP 410. A repeated callback after success is unknown because the receipt was cleared.
- State is in memory and local to one process. Restarts lose it, and upstream requests are not exactly-once when a response is lost.

`APPROVAL_WINDOW` is 90 seconds. Pushover uses a 30-second emergency retry and 90-second expiration. `SESSION_RETENTION` is 900 seconds from the latest lifecycle transition, with cleanup every 30 seconds. These values do not control UniFi's guest-access duration.

SSE sends the current watch-channel value immediately, uses 15-second keep-alives, sets `X-Accel-Buffering: no`, and closes after a terminal event. If a retained session is gone, `/guest/events` queries UniFi once by MAC to recover the current status without sending another notification.

## Configuration and upstream APIs

Clap accepts environment variables and corresponding kebab-case CLI flags. The binary does not load `.env`; Docker may inject one with `--env-file .env`.

| Variable | Meaning |
| --- | --- |
| `APPLICATION_URL` | Public HTTPS portal base URL used for callbacks and CAPPORT portal URLs |
| `UNIFI_API_URL` | UniFi connector-console or local controller base URL, before the proxy paths |
| `UNIFI_API_KEY` | UniFi API key sent in `X-API-Key` |
| `UNIFI_SITE_ID` | Integration API site UUID |
| `UNIFI_LEGACY_SITE_NAME` | Legacy API site name; defaults to `default` |
| `PUSHOVER_TOKEN` | Pushover application token |
| `PUSHOVER_USER` | Pushover recipient key |

Current UniFi integration endpoints are built below `{UNIFI_API_URL}/proxy/network/integration/v1/sites/{UNIFI_SITE_ID}`. Authorization posts to `/clients/{client-id}/actions` with only `{"action":"AUTHORIZE_GUEST_ACCESS"}` so UniFi controls access duration. CAPPORT identity/SSID discovery also uses the legacy site-name endpoint described above.

When changing an upstream contract, check current official UniFi or Pushover documentation. Do not assume an old versioned UniFi Markdown URL is still reachable or current.

## UniFi IPv6/CAPPORT scripts

The supported entry point is the interactive installer, run on a non-root workstation that can SSH to both the gateway and AP:

```sh
curl -fsSL https://raw.githubusercontent.com/edrf12/pushover-unifi-hotspot/main/scripts/install.sh | bash
```

Use `SCRIPT_BASE_URL` to test a fork or pin a release. The installer downloads all component files from that base URL, checks shell syntax, discovers bridge/address/DHCP values, optionally installs UniFi Common, creates a dedicated gateway-to-AP Ed25519 key, substitutes `__...__` placeholders, copies files to the gateway, pins the AP host key, and starts the repair timers after confirmation.

Installed gateway locations include `/data/guest-ipv6`, `/data/on_boot.d/30-guest-ipv6.sh`, and `/usr/local/bin/unifi-guest-ipv6-rollback`. The timers repair gateway rules every 15 seconds and AP/CAPPORT state every 30 seconds. UniFi remains the source of authorization through its native authorized-guest MAC sets.

Run rollback on the gateway with:

```sh
sudo /usr/local/bin/unifi-guest-ipv6-rollback
```

Treat installation and rollback as live network administration, not test commands. Do not run `install.sh`, its installed scripts, SSH/SCP commands, systemd actions, firewall commands, dnsmasq restarts, or rollback against real UniFi equipment unless the user explicitly asks. The repository scripts contain unresolved placeholders and are not meant to be executed directly before installation.

Keep `README.md`, `scripts/README.md`, and `docs/guest-ipv6-install.md` synchronized with script behavior. Be precise about destructive effects: the current rollback removes installed persistence and CAPPORT configuration but does not provide backup restoration.

## Working conventions

- Prefer simple changes within the existing Rust/Axum and shell-script structure.
- Explain Rust mechanisms plainly when the request is educational; do not turn an explanation-only request into an implementation.
- Keep Rustdoc comments on application functions and update nearby comments and operator documentation when behavior changes.
- Prefer borrowed `&str` form values instead of allocating strings for literals.
- Preserve notification deduplication, callback reservation, secret separation, SSE reconnect recovery, IPv4/IPv6 CAPPORT identity handling, and fail-closed script prerequisite checks.
- Preserve ignore rules for `.env`, `.env.*`, `/target`, and other secrets or build output.
- Use local mocks for application tests. Never send a real Pushover notification or authorize a real client during routine validation.
- Preserve unrelated working-tree changes; this repository may already be dirty.

## Validation

For Rust or embedded-page changes, run as appropriate:

```sh
cargo fmt --check
cargo check --locked
cargo test --locked
cargo doc --locked --no-deps --document-private-items
```

Use `--offline` when dependencies are cached and network access is unavailable. `cargo test` currently mainly verifies the test-profile build because no test suite is committed. If future tests bind localhost, sandbox network restrictions may require permission; a permission error is not an application failure.

For shell changes, at minimum syntax-check every shell script:

```sh
for script in scripts/*.sh; do bash -n "$script"; done
```

Also search changed templates for unresolved or misspelled placeholders and verify that `scripts/install.sh` substitutes every intended placeholder. Static checks cannot validate firmware-specific chains, ipsets, bridges, DHCP tags, AP provisioning, or live guest behavior.

Container verification, when Docker is available:

```sh
docker build -t pushover-unifi-hotspot .
docker run --rm -p 3000:3000 --env-file .env pushover-unifi-hotspot
```

Do not claim a Docker build, live callback, Pushover delivery, UniFi authorization, installer run, or IPv6 guest test succeeded unless it was actually performed.

## References

- UniFi external hotspot workflow: https://help.ui.com/hc/en-us/articles/31228198640023-External-Hotspot-API-for-Authorization-Clients
- UniFi API: https://developer.ui.com/
- RFC 8908 CAPPORT API: https://www.rfc-editor.org/rfc/rfc8908.html
- Pushover messages: https://pushover.net/api
- Pushover callbacks: https://pushover.net/api/receipts
