#!/usr/bin/env bash
set -Eeuo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

log() {
  printf '[+] %s\n' "$*"
}

warn() {
  printf '[!] %s\n' "$*" >&2
}

die() {
  printf '[x] %s\n' "$*" >&2
  exit 1
}

if [[ "$(uname -s)" != "Linux" ]]; then
  die "Host networking requires a Linux host."
fi

if [[ ${EUID} -ne 0 ]]; then
  die "Run this script as root: sudo ./install.sh"
fi

install_packages() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y "$@"
  elif command -v yum >/dev/null 2>&1; then
    yum install -y "$@"
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache "$@"
  else
    die "Install these packages first: $*"
  fi
}

missing_packages=()
command -v curl >/dev/null 2>&1 || missing_packages+=(curl)
command -v openssl >/dev/null 2>&1 || missing_packages+=(openssl)

if ((${#missing_packages[@]})); then
  log "Installing required packages: ${missing_packages[*]}"
  install_packages "${missing_packages[@]}"
fi

if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker Engine..."
  curl -fsSL https://get.docker.com | sh
fi

if command -v systemctl >/dev/null 2>&1; then
  systemctl enable --now docker >/dev/null 2>&1 || true
fi

if ! docker compose version >/dev/null 2>&1; then
  die "Docker Compose v2 is required. Install the Docker Compose plugin and run this script again."
fi

for _ in {1..10}; do
  docker info >/dev/null 2>&1 && break
  sleep 1
done

docker info >/dev/null 2>&1 || die "The Docker daemon is not running."

is_ipv4() {
  local ip=${1:-} octet
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1

  IFS=. read -r -a octets <<<"$ip"
  for octet in "${octets[@]}"; do
    ((10#$octet <= 255)) || return 1
  done
}

detect_public_ipv4() {
  local endpoint ip
  local endpoints=(
    "https://api.ipify.org"
    "https://ifconfig.me/ip"
    "https://icanhazip.com"
  )

  for endpoint in "${endpoints[@]}"; do
    ip=$(curl -4fsS --connect-timeout 3 --max-time 5 "$endpoint" 2>/dev/null | tr -d '[:space:]') || true
    if is_ipv4 "$ip"; then
      printf '%s\n' "$ip"
      return 0
    fi
  done

  return 1
}

detect_local_ipv4() {
  local ip

  if command -v ip >/dev/null 2>&1; then
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}') || true
    if is_ipv4 "$ip"; then
      printf '%s\n' "$ip"
      return 0
    fi
  fi

  if command -v hostname >/dev/null 2>&1; then
    ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
  fi
  if is_ipv4 "$ip"; then
    printf '%s\n' "$ip"
    return 0
  fi

  return 1
}

get_env_value() {
  local key=$1
  sed -n "s/^${key}=//p" .env 2>/dev/null | tail -n 1 | tr -d '\r'
}

set_env_value() {
  local key=$1 value=$2

  if grep -q "^${key}=" .env; then
    sed -i "s|^${key}=.*$|${key}=${value}|" .env
  else
    printf '%s=%s\n' "$key" "$value" >>.env
  fi
}

if [[ ! -f .env ]]; then
  [[ -f .env.example ]] || die ".env.example is missing."
  cp .env.example .env
  log "Created .env."
fi

wg_host=$(get_env_value WG_HOST)
if [[ -z $wg_host || $wg_host == "vpn.example.com" ]]; then
  if wg_host=$(detect_public_ipv4); then
    set_env_value WG_HOST "$wg_host"
    log "Detected public IPv4: $wg_host"
  elif wg_host=$(detect_local_ipv4); then
    set_env_value WG_HOST "$wg_host"
    warn "Public IPv4 detection failed; using local IPv4 $wg_host. Update WG_HOST in .env if the server is behind NAT."
  else
    die "Could not detect an IPv4 address. Set WG_HOST manually in .env."
  fi
fi

wg_password=$(get_env_value WG_PASSWORD)
if [[ -z $wg_password || $wg_password == "replace-with-a-strong-password" ]]; then
  wg_password=$(openssl rand -hex 24)
  set_env_value WG_PASSWORD "$wg_password"
  log "Generated a strong wg-easy password."
fi

wg_username=$(get_env_value WG_USERNAME)
if [[ -z $wg_username ]]; then
  wg_username=admin
  set_env_value WG_USERNAME "$wg_username"
fi

wg_port=$(get_env_value WG_PORT)
if [[ -z $wg_port ]]; then
  wg_port=51820
  set_env_value WG_PORT "$wg_port"
fi

wg_ui_port=$(get_env_value WG_UI_PORT)
if [[ -z $wg_ui_port ]]; then
  wg_ui_port=51821
  set_env_value WG_UI_PORT "$wg_ui_port"
fi

wg_dns=$(get_env_value WG_DNS)
if [[ -z $wg_dns ]]; then
  wg_dns=10.8.0.1
  set_env_value WG_DNS "$wg_dns"
fi

chmod 600 .env

cat >/etc/sysctl.d/99-wireguard.conf <<'SYSCTL'
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
SYSCTL
sysctl -p /etc/sysctl.d/99-wireguard.conf >/dev/null

mkdir -p data/wireguard data/adguard/work data/adguard/conf

docker compose --env-file .env config >/dev/null
log "Pulling container images..."
docker compose --env-file .env pull
log "Starting WireGuard and AdGuard Home..."
docker compose --env-file .env up -d

local_ip=$(detect_local_ipv4 || true)
local_ip=${local_ip:-SERVER_IP}

echo
printf '%s\n' "Installation complete."
printf 'wg-easy UI:       http://%s:%s\n' "$local_ip" "$wg_ui_port"
printf 'AdGuard setup:     http://%s:3000\n' "$local_ip"
printf 'WireGuard endpoint: %s:%s/udp\n' "$wg_host" "$wg_port"
printf 'Username:          %s\n' "$wg_username"
printf 'Password:          %s\n' "$wg_password"
printf 'Credentials file:  %s/.env\n' "$PWD"
echo
printf 'Forward UDP port %s from your router to %s.\n' "$wg_port" "$local_ip"
printf 'Do not expose ports 53, 3000, or %s to the public Internet.\n' "$wg_ui_port"
