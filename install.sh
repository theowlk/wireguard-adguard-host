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
  die "Run this script as root: sudo bash install.sh"
fi

install_dependencies() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl openssl iproute2 iptables
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y curl openssl iproute iptables
  elif command -v yum >/dev/null 2>&1; then
    yum install -y curl openssl iproute iptables
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl openssl iproute2 iptables
  else
    die "Install curl, openssl, iproute2 and iptables first."
  fi
}

if ! command -v curl >/dev/null 2>&1 ||
  ! command -v openssl >/dev/null 2>&1 ||
  ! command -v ip >/dev/null 2>&1 ||
  ! command -v iptables >/dev/null 2>&1; then
  log "Installing required networking tools..."
  install_dependencies
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
  local -a octets

  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r -a octets <<<"$ip"

  for octet in "${octets[@]}"; do
    ((10#$octet <= 255)) || return 1
  done
}

is_ipv4_cidr() {
  local cidr=${1:-} ip prefix

  [[ $cidr == */* ]] || return 1
  ip=${cidr%/*}
  prefix=${cidr#*/}

  is_ipv4 "$ip" || return 1
  [[ $prefix =~ ^[0-9]+$ ]] || return 1
  ((10#$prefix >= 0 && 10#$prefix <= 32))
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

  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") {print $(i + 1); exit}}') || true
  if is_ipv4 "$ip"; then
    printf '%s\n' "$ip"
    return 0
  fi

  ip=$(hostname -I 2>/dev/null | awk '{print $1}') || true
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

wg_ipv4_cidr=$(get_env_value WG_IPV4_CIDR)
if [[ -z $wg_ipv4_cidr ]]; then
  wg_ipv4_cidr=10.8.0.0/24
  set_env_value WG_IPV4_CIDR "$wg_ipv4_cidr"
fi
is_ipv4_cidr "$wg_ipv4_cidr" || die "WG_IPV4_CIDR is not a valid IPv4 CIDR: $wg_ipv4_cidr"

chmod 600 .env

cat >/etc/sysctl.d/99-wireguard.conf <<'SYSCTL'
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
SYSCTL
sysctl -p /etc/sysctl.d/99-wireguard.conf >/dev/null

install_firewall_rules() {
  local script_path=/usr/local/sbin/wireguard-adguard-firewall
  local config_path=/etc/default/wireguard-adguard-firewall
  local service_path=/etc/systemd/system/wireguard-adguard-firewall.service

  cat >"$config_path" <<EOF_CONFIG
VPN_SUBNET=$wg_ipv4_cidr
WG_INTERFACE=wg0
EOF_CONFIG
  chmod 600 "$config_path"

  cat >"$script_path" <<'EOF_FIREWALL'
#!/bin/sh
set -eu

. /etc/default/wireguard-adguard-firewall
out_interface=$(ip -4 route get 1.1.1.1 2>/dev/null |
  awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')

[ -n "$out_interface" ] || {
  echo "Could not detect the default IPv4 interface." >&2
  exit 1
}

iptables -w -N WGAH_FORWARD 2>/dev/null || true
iptables -w -F WGAH_FORWARD
iptables -w -A WGAH_FORWARD -i "$WG_INTERFACE" -j ACCEPT
iptables -w -A WGAH_FORWARD -o "$WG_INTERFACE" -j ACCEPT
iptables -w -C FORWARD -j WGAH_FORWARD 2>/dev/null || \
  iptables -w -I FORWARD 1 -j WGAH_FORWARD

iptables -w -t nat -N WGAH_NAT 2>/dev/null || true
iptables -w -t nat -F WGAH_NAT
iptables -w -t nat -A WGAH_NAT -s "$VPN_SUBNET" -o "$out_interface" -j MASQUERADE
iptables -w -t nat -C POSTROUTING -j WGAH_NAT 2>/dev/null || \
  iptables -w -t nat -I POSTROUTING 1 -j WGAH_NAT

printf 'WireGuard IPv4 NAT enabled: %s -> %s\n' "$VPN_SUBNET" "$out_interface"
EOF_FIREWALL
  chmod 755 "$script_path"

  if command -v systemctl >/dev/null 2>&1 && systemctl show-environment >/dev/null 2>&1; then
    cat >"$service_path" <<EOF_SERVICE
[Unit]
Description=WireGuard client forwarding and IPv4 NAT
Wants=network-online.target
After=network-online.target docker.service firewalld.service ufw.service

[Service]
Type=oneshot
ExecStart=$script_path
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SERVICE

    systemctl daemon-reload
    systemctl enable wireguard-adguard-firewall.service >/dev/null
    systemctl restart wireguard-adguard-firewall.service
  else
    "$script_path"
    warn "systemd is unavailable; the NAT rules must be reapplied after a reboot by running this installer."
  fi
}
install_firewall_rules

mkdir -p data/wireguard data/adguard/work data/adguard/conf

docker compose --env-file .env config >/dev/null
log "Pulling container images..."
docker compose --env-file .env pull
log "Starting WireGuard and AdGuard Home..."
docker compose --env-file .env up -d

local_ip=$(detect_local_ipv4 || true)
local_ip=${local_ip:-SERVER_IP}
out_interface=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "dev") {print $(i + 1); exit}}')

echo
printf '%s\n' "Installation complete."
printf 'wg-easy UI:        http://%s:%s\n' "$local_ip" "$wg_ui_port"
printf 'AdGuard setup:      http://%s:3000\n' "$local_ip"
printf 'WireGuard endpoint: %s:%s/udp\n' "$wg_host" "$wg_port"
printf 'VPN IPv4 subnet:    %s\n' "$wg_ipv4_cidr"
printf 'NAT interface:      %s\n' "${out_interface:-unknown}"
printf 'Username:           %s\n' "$wg_username"
printf 'Password:           %s\n' "$wg_password"
printf 'Credentials file:   %s/.env\n' "$PWD"
echo
printf 'Forward UDP port %s from your router to %s.\n' "$wg_port" "$local_ip"
printf 'Do not expose ports 53, 3000, or %s to the public Internet.\n' "$wg_ui_port"
