# WireGuard + AdGuard Home with Docker Compose

A deliberately small Docker Compose setup for:

- [wg-easy](https://github.com/wg-easy/wg-easy): WireGuard with a web UI
- [AdGuard Home](https://github.com/AdguardTeam/AdGuardHome): DNS-level ad and tracker blocking
- Linux host networking: no custom Docker networks and no reverse proxy

## What the installer does

A single run of `install.sh`:

- installs the required networking tools and Docker Engine when missing;
- creates `.env` when it does not exist;
- detects the public IPv4 address, with a local IPv4 fallback;
- generates a strong random wg-easy administrator password;
- preserves existing `.env` values on later runs;
- enables IPv4 forwarding;
- detects the default IPv4 network interface;
- configures persistent forwarding and NAT for WireGuard clients;
- pulls and starts wg-easy and AdGuard Home;
- prints the URLs, endpoint and generated credentials.

The generated `.env` file is private (`chmod 600`) and ignored by Git.

## Requirements

- A Linux server
- Root or `sudo` access
- `git`

The installer supports common distributions using `apt`, `dnf`, `yum` or `apk`.

## Install

```bash
git clone https://github.com/theowlk/wireguard-adguard-host.git
cd wireguard-adguard-host
sudo bash install.sh
```

That is all. No manual `.env` editing is required for a normal installation.

At the end, the installer prints something similar to:

```text
wg-easy UI:        http://192.168.1.10:51821
AdGuard setup:      http://192.168.1.10:3000
WireGuard endpoint: 203.0.113.10:51820/udp
VPN IPv4 subnet:    10.8.0.0/24
NAT interface:      eth0
Username:           admin
Password:           generated-random-password
```

The same values are stored in `.env`:

```bash
sudo cat .env
```

## Existing configuration

The installer is idempotent. Running it again updates the containers and refreshes the routing rules without replacing an existing host, username or password.

To use a DNS name instead of the detected public IPv4, edit `.env` before running the installer again:

```dotenv
WG_HOST=vpn.example.com
```

The default WireGuard IPv4 subnet is `10.8.0.0/24`. When changing the interface CIDR in the wg-easy admin panel, also update:

```dotenv
WG_IPV4_CIDR=10.8.0.0/24
```

Then run `sudo bash install.sh` again.

## Finish the setup

1. Open AdGuard Home at the URL printed by the installer.
2. Complete its setup wizard and keep DNS on port `53`.
3. Open the wg-easy URL printed by the installer.
4. Sign in with the generated credentials and create a client.
5. Forward UDP port `51820` from the router to the server's local IPv4 address.

WireGuard clients use `10.8.0.1` as their DNS server, so DNS requests go through AdGuard Home.

For a full-tunnel client, its WireGuard configuration must contain:

```ini
AllowedIPs = 0.0.0.0/0
```

If the connection uses CGNAT, forwarding a public port may not be possible even when a public IPv4 is detected externally. Use a VPS or request a real public IPv4 from the ISP.

## Fix an existing installation

Pull the latest version and rerun the installer. Existing clients and wg-easy data are preserved.

```bash
cd wireguard-adguard-host
git pull
sudo bash install.sh
```

Then disconnect and reconnect the WireGuard client.

Verify the host routing rules with:

```bash
sysctl net.ipv4.ip_forward
sudo iptables -S WGAH_FORWARD
sudo iptables -t nat -S WGAH_NAT
```

`net.ipv4.ip_forward` must be `1`, and the NAT chain must contain a `MASQUERADE` rule for `10.8.0.0/24`.

## Security

Only UDP port `51820` should be forwarded from the Internet.

Do not publicly expose:

- `53/tcp` or `53/udp` — AdGuard DNS
- `3000/tcp` — initial AdGuard setup
- `51821/tcp` — wg-easy web UI running in insecure HTTP mode

On a directly exposed VPS, restrict these ports with the provider firewall or the host firewall.

## Useful commands

```bash
# Run the installer again and update the containers and routing rules
sudo bash install.sh

# Show status
docker compose ps

# Show logs
docker compose logs -f

# Reapply only the forwarding and NAT rules
sudo systemctl restart wireguard-adguard-firewall

# Stop the stack
docker compose down
```

## Port 53 is already in use

On Ubuntu or Debian, `systemd-resolved` may be listening on port 53. Follow the official AdGuard Home Docker documentation to disable its local DNS stub before starting this stack.

## Data

Persistent files are stored under `./data/` and are ignored by Git.

## License

MIT
