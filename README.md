# WireGuard + AdGuard Home with Docker Compose

A deliberately small Docker Compose setup for:

- [wg-easy](https://github.com/wg-easy/wg-easy): WireGuard with a web UI
- [AdGuard Home](https://github.com/AdguardTeam/AdGuardHome): DNS-level ad and tracker blocking
- Linux host networking: no custom Docker networks and no reverse proxy

## Requirements

- A Linux server
- Root or `sudo` access
- `git` and `curl`
- A public IP address or DNS name

Docker Engine is installed automatically by `install.sh` when it is missing.

## Install

```bash
git clone https://github.com/theowlk/wireguard-adguard-host.git
cd wireguard-adguard-host
sudo ./install.sh
```

The first run creates `.env` and stops. Edit it:

```bash
nano .env
```

Set at least:

```dotenv
WG_HOST=vpn.example.com
WG_PASSWORD=replace-with-a-strong-password
```

Then start the stack:

```bash
sudo ./install.sh
```

## Finish the setup

1. Open AdGuard Home at `http://SERVER_IP:3000`.
2. Complete its setup wizard. Keep DNS on port `53`.
3. Open wg-easy at `http://SERVER_IP:51821`.
4. Sign in with the credentials from `.env` and create a client.
5. Forward UDP port `51820` from your router to the server.

WireGuard clients use `10.8.0.1` as their DNS server, so DNS requests go through AdGuard Home.

## Security

Only UDP port `51820` should be forwarded from the Internet.

Do not publicly expose:

- `53/tcp` or `53/udp` — AdGuard DNS
- `3000/tcp` — initial AdGuard setup
- `51821/tcp` — wg-easy web UI running in insecure HTTP mode

On a directly exposed VPS, restrict these ports with the provider firewall or the host firewall.

## Useful commands

```bash
# Show status
docker compose ps

# Show logs
docker compose logs -f

# Update containers
docker compose pull && docker compose up -d

# Stop the stack
docker compose down
```

## Port 53 is already in use

On Ubuntu or Debian, `systemd-resolved` may be listening on port 53. Follow the official AdGuard Home Docker documentation to disable its local DNS stub before starting this stack.

## Data

Persistent files are stored under `./data/` and are ignored by Git.

## License

MIT
