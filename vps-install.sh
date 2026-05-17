#!/bin/bash
# VPS install — fully idempotent. Reads ./config.sh; fetches the
# pinned shadowsocks-rust ssserver from upstream; renders server.json
# and the iptables NAT rule for the detected (or configured) WAN iface.
#
# Run on the VPS as root: `sudo ./vps-install.sh`

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/etc_files_vps"
. "$ROOT/lib.sh"
require_root "$@"

generate_ss_password() {
    openssl rand -base64 32
}

read_shadowsocks_password() {
    local path=$1
    [ -s "$path" ] || return 1
    if command -v jq >/dev/null 2>&1; then
        jq -er '.password // empty' "$path" 2>/dev/null
        return
    fi
    sed -n 's/^[[:space:]]*"password"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$path" | head -n 1
}

detect_public_ip() {
    local ip
    ip=$(curl -4 -fsS --max-time 5 https://ifconfig.me 2>/dev/null || true)
    if [ -z "$ip" ]; then
        ip=$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
    fi
    [ -n "$ip" ] || return 1
    printf '%s\n' "$ip"
}

shell_quote() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

note "VPS packages"
echo iptables-persistent iptables-persistent/autosave_v4 boolean false | debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean false | debconf-set-selections
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    iptables-persistent curl gettext-base xz-utils dnsutils tcpdump \
    netcat-openbsd tmux vim less jq tree htop git rsync ripgrep

ENV_VPS_IP="${VPS_IP:-}"
ENV_SS_PASSWORD="${SS_PASSWORD:-}"

CFG="$ROOT/config.sh"
[ -e "$CFG" ] || die "missing $CFG"
. "$CFG"
[ -n "$ENV_VPS_IP" ] && VPS_IP="$ENV_VPS_IP"
[ -n "$ENV_SS_PASSWORD" ] && SS_PASSWORD="$ENV_SS_PASSWORD"

if [ -z "${SS_PASSWORD:-}" ]; then
    SS_PASSWORD="$(read_shadowsocks_password /etc/shadowsocks/server.json || true)"
fi
if [ -z "${SS_PASSWORD:-}" ]; then
    SS_PASSWORD="$(generate_ss_password)"
fi
: "${VPS_IP:=$(detect_public_ip)}"
: "${SS_PORT:=8388}"
: "${SS_METHOD:=chacha20-ietf-poly1305}"
: "${VPS_WAN_IFACE:=$(ip route show default | awk '/default/ {print $5; exit}')}"
[ -n "$VPS_IP" ] || die "could not detect public VPS IP; set VPS_IP in config.sh or the environment"
require_ipv4 VPS_IP "$VPS_IP"
[ -n "$VPS_WAN_IFACE" ] || die "could not detect WAN interface; set VPS_WAN_IFACE in config.sh"
export VPS_IP SS_PORT SS_METHOD SS_PASSWORD VPS_WAN_IFACE

note "shadowsocks-rust ssserver"
install_ss_rust "${SS_RUST_VPS_ARCH:-x86_64-unknown-linux-gnu}" ssserver

note "kernel MPTCP capability check"
if [ "$(sysctl -n net.mptcp.enabled 2>/dev/null)" != "1" ]; then
    die "MPTCP is disabled in the kernel; this setup will not work."
fi

note "sysctl"
install_file "$SRC/sysctl-99-mptcp.conf"   /etc/sysctl.d/99-mptcp.conf
install_file "$SRC/sysctl-99-forward.conf" /etc/sysctl.d/99-forward.conf
sysctl --system >/dev/null

note "ip mptcp limits"
ip mptcp limits set subflow 4 add_addr_accepted 4 || true

note "systemd ssserver unit"
if ! getent group shadowsocks >/dev/null; then
    groupadd --system shadowsocks
fi
if ! id -u shadowsocks >/dev/null 2>&1; then
    useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin --gid shadowsocks shadowsocks
fi
install_file "$SRC/shadowsocks-server.service" /etc/systemd/system/shadowsocks-server.service
systemctl daemon-reload
systemctl enable shadowsocks-server.service >/dev/null

note "/etc/shadowsocks/server.json"
install -d /etc/shadowsocks
render_template "$SRC/shadowsocks-server.json.template" /etc/shadowsocks/server.json 0600
chown shadowsocks:shadowsocks /etc/shadowsocks/server.json
chmod 0600 /etc/shadowsocks/server.json

note "iptables (WAN=${VPS_WAN_IFACE})"
install -d /etc/iptables
sed "s/ens3/${VPS_WAN_IFACE}/" "$SRC/iptables-rules.v4" > /etc/iptables/rules.v4
iptables-restore < /etc/iptables/rules.v4 || warn "iptables-restore failed"
systemctl enable netfilter-persistent >/dev/null

note "restart shadowsocks-server"
systemctl restart shadowsocks-server.service
sleep 1
systemctl is-active --quiet shadowsocks-server && log "shadowsocks-server active" || warn "shadowsocks-server not active — journalctl -u shadowsocks-server"

cat <<EOF

VPS install complete. Manual reminders:
  - Open TCP/UDP ${SS_PORT} in any cloud-provider firewall.
  - Confirm with: ss -lntup | grep :${SS_PORT}

Run this on the Pi:
   sudo env SS_PASSWORD=$(shell_quote "$SS_PASSWORD") VPS_IP=$(shell_quote "$VPS_IP") ./pi-install.sh
EOF
