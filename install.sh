#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "Error: host networking requires a Linux host." >&2
  exit 1
fi

if [[ ${EUID} -ne 0 ]]; then
  echo "Run this script as root: sudo ./install.sh" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "Error: curl is required." >&2
  exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "Docker was not found. Installing Docker Engine..."
  curl -fsSL https://get.docker.com | sh
fi

if ! docker compose version >/dev/null 2>&1; then
  echo "Error: Docker Compose v2 is required." >&2
  exit 1
fi

if [[ ! -f .env ]]; then
  cp .env.example .env
  echo "Created .env from .env.example."
  echo "Edit .env, then run: sudo ./install.sh"
  exit 0
fi

set -a
# shellcheck disable=SC1091
source .env
set +a

if [[ -z "${WG_HOST:-}" || "${WG_HOST}" == "vpn.example.com" ]]; then
  echo "Error: set WG_HOST in .env to your public IP address or DNS name." >&2
  exit 1
fi

if [[ -z "${WG_PASSWORD:-}" || "${WG_PASSWORD}" == "replace-with-a-strong-password" ]]; then
  echo "Error: set a strong WG_PASSWORD in .env." >&2
  exit 1
fi

cat >/etc/sysctl.d/99-wireguard.conf <<'SYSCTL'
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
SYSCTL
sysctl --system >/dev/null

mkdir -p data/wireguard data/adguard/work data/adguard/conf

docker compose pull
docker compose up -d

echo
echo "Installation complete."
echo "wg-easy UI:    http://SERVER_IP:${WG_UI_PORT:-51821}"
echo "AdGuard setup: http://SERVER_IP:3000"
echo
echo "Forward UDP port ${WG_PORT:-51820} from your router to this host."
echo "Do not expose ports 53, 3000, or ${WG_UI_PORT:-51821} to the public Internet."
