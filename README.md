# Unifi Pushover Captive Portal

This is an external portal server for Unifi that sends a Pushover emergency priority notification that authorizes the guest when acknowledged.

## Deployment

To deploy this captive portal use the Docker image published by your repository, for example `ghcr.io/OWNER/REPOSITORY`.

The portal listens by default at port 3000.

You must supply the following environment variables:
- `APPLICATION_URL`: Public portal url (Pushover will need to be able to call this).
- `UNIFI_API_URL`: UniFi integration API base URL, before `/v1`.
- `UNIFI_API_KEY`: UniFi API key.
- `UNIFI_SITE_ID`: UniFi site ID.
- `PUSHOVER_TOKEN`: Pushover application token.
- `PUSHOVER_USER`: Pushover user key.

CAPPORT requires the reverse proxy to set `X-Real-IP` to the guest address. For Caddy, configure `header_up X-Real-IP {client_ip}` in the portal's `reverse_proxy` block. When Caddy is behind another proxy, configure Caddy's trusted proxies so `{client_ip}` resolves the original guest address.

### Getting unifi environment variables

#### UNIFI_API_URL

This is your console's api base url, if you want to use the cloud connector access [UniFi](https://unifi.ui.com), open your console, copy the console id ( the part after `/consoles/`) and format the url like this `https://api.ui.com/v1/connector/consoles/<console-id>` or you can use the local API URL `https://<controller_ip>/`.

#### UNIFI_API_KEY

This is your UniFi API key, which you can obtain from the [UniFi console](https://unifi.ui.com/settings/api-keys/).

The key only needs access to Network at the site of interest.

#### UNIFI_SITE_ID

With your newly obtained API URL and API key, you can obtain your site id by running the following command:

```bash
curl -X GET "$UNIFI_API_URL/integration/v1/sites" -H "X-API-Key: $UNIFI_API_KEY"
```

### Setting up your router

- Create a network in the Hotspot zone and note it's ID (we will use this later for IPv6 and is not needed for IPv4)
- Create a wifi network with application Hotspot and set the hotspot type to Captive Portal, additionally you may enable Enchanced Open to make it a little more secure. For IPv6 set it to the network we just created
- Now go to Clients > Hotspot > Landing Page, set your authentication to external portal server and put the ip of the server you are hosting your portal.
- Also enable Encrypted URl, Secure Portal and set Domain to the domain you are using for your portal.
- In pre-authorization allowaces add your domain
- Add the domain you are using for your portal to your local DNS records as well.

### Exposing your portal to the internet

The portal does need to be exposed to the internet so Pushover can reach it.

For security I reccommend you limit external access to the `/guest/callback` endpoint. You may also block this endpoint for local guests.

## IPv6 Support

> **Here be dragons:** this has not been heavily tested and I relied in ai to help me get IPv6 working on my router. This seems to work fine with the devices I tested.

Although Unifi is not too keen in working with IPv6 clients on Captive Networks there are some workarounds we can use to get around this.

By implementing support for [CAPPORT](https://www.rfc-editor.org/rfc/rfc8908.html) we can advertise where clients should go to authenticate to our network, since Unifi does not redirect clients using IPv6 to make requests.

```bash
curl -fsSL https://raw.githubusercontent.com/edrf12/pushover-unifi-hotspot/main/scripts/install.sh | bash
```

The guided installer asks whether to install or refresh UniFi Common automatically, then asks for network-specific values, generates a dedicated gateway-to-AP key, pauses while you add its public key under UniFi Device SSH Authentication, installs persistent IPv6/CAPPORT repair, and places `unifi-guest-ipv6-rollback` in `/usr/local/bin` on the gateway. If selected, it downloads UniFi Common's installer, shows its checksum, and asks for confirmation before running it as root. Set `SCRIPT_BASE_URL` to use a fork or pinned release.

## Wired guests

To have wired guests authenticate assign switch ports to a network in the Hotspot zone.
