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
# Runtime: iptables-persistent. Install-time: curl (fetch ssserver + public
# IP), gettext-base (envsubst), xz-utils (extract). jq: reads password from
# existing config.
apt_ensure iptables-persistent curl gettext-base xz-utils jq

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
: "${SS_PORT:=10001}"
: "${SS_METHOD:=chacha20-ietf-poly1305}"
: "${VPS_WAN_IFACE:=$(ip route show default | awk '/default/ {print $5; exit}')}"
[ -n "$VPS_IP" ] || die "could not detect public VPS IP; set VPS_IP in config.sh or the environment"
require_ipv4 VPS_IP "$VPS_IP"
[ -n "$VPS_WAN_IFACE" ] || die "could not detect WAN interface; set VPS_WAN_IFACE in config.sh"
export VPS_IP SS_PORT SS_METHOD SS_PASSWORD VPS_WAN_IFACE

note "shadowsocks-rust ssserver"
install_ss_rust "${SS_RUST_VPS_ARCH:-x86_64-unknown-linux-gnu}" ssserver

# grub_entry_for_kernel VERSION [GRUB_CFG] — print the GRUB menu entry path
# ("<submenu id>><entry id>") of the non-recovery entry for that kernel, as
# accepted by grub-set-default. Distro-neutral: matches "with Linux VERSION".
grub_entry_for_kernel() {
    local ver=$1 cfg=${2:-/boot/grub/grub.cfg}
    [ -r "$cfg" ] || return 1
    awk -v ver="$ver" '
        function id(line) {
            if (match(line, /\$menuentry_id_option .[^ ]+/) == 0) return ""
            s = substr(line, RSTART, RLENGTH); sub(/^\$menuentry_id_option ./, "", s); sub(/.$/, "", s)
            return s
        }
        /^submenu / { sub_id = id($0); next }
        /^}/ { sub_id = ""; next }
        /^[[:space:]]*menuentry / && index($0, "with Linux " ver) && !index($0, "recovery") {
            e = id($0); if (e == "") next
            print (sub_id != "" ? sub_id ">" e : e); exit
        }
    ' "$cfg"
}

# Make the custom kernel the GRUB default.
grub_default_custom_kernel() {
    local entry
    if ! command -v grub-set-default >/dev/null 2>&1 || [ ! -r /boot/grub/grub.cfg ]; then
        warn "no GRUB found; make ${KERNEL_VPS_VERSION} the default kernel with your bootloader/provider console"
        return 0
    fi
    if grep -q '^GRUB_DEFAULT=' /etc/default/grub; then
        sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
    else
        echo 'GRUB_DEFAULT=saved' >> /etc/default/grub
    fi
    update-grub >/dev/null 2>&1 || warn "update-grub failed"
    entry=$(grub_entry_for_kernel "$KERNEL_VPS_VERSION") || true
    [ -n "$entry" ] || die "no GRUB entry for ${KERNEL_VPS_VERSION} in /boot/grub/grub.cfg"
    grub-set-default "$entry"
    log "GRUB default: ${KERNEL_VPS_VERSION} (${entry})"
}

# Install the custom MPTCP kernel and make it the GRUB default
install_custom_kernel() {
    note "custom MPTCP kernel"
    local image_deb headers_deb cache url_base
    image_deb="linux-image-${KERNEL_VPS_VERSION}_${KERNEL_PKG_VERSION}_amd64.deb"
    headers_deb="linux-headers-${KERNEL_VPS_VERSION}_${KERNEL_PKG_VERSION}_amd64.deb"
    cache="/tmp/mptcp-kernel-${KERNEL_RELEASE}"
    url_base="${KERNEL_REPO}/releases/download/${KERNEL_RELEASE}"

    if [ "$(uname -r)" = "$KERNEL_VPS_VERSION" ]; then
        log "running kernel already matches ${KERNEL_VPS_VERSION}"
        grep -qw redundant /proc/sys/net/mptcp/available_schedulers 2>/dev/null \
            || die "running kernel ${KERNEL_VPS_VERSION} has no 'redundant' MPTCP scheduler"
        log "redundant MPTCP scheduler available"
        return 0
    fi
    if [ "$(dpkg-query -W -f='${Version}' "linux-image-${KERNEL_VPS_VERSION}" 2>/dev/null || true)" = "$KERNEL_PKG_VERSION" ] &&
       [ "$(dpkg-query -W -f='${Version}' "linux-headers-${KERNEL_VPS_VERSION}" 2>/dev/null || true)" = "$KERNEL_PKG_VERSION" ]; then
        log "kernel packages already installed (${KERNEL_PKG_VERSION})"
        grub_default_custom_kernel
        return 0
    fi
    install -d "$cache"
    fetch_url "${url_base}/${image_deb}" "${cache}/${image_deb}"
    fetch_url "${url_base}/${headers_deb}" "${cache}/${headers_deb}"
    verify_sha256 "${cache}/${image_deb}" "${KERNEL_VPS_IMAGE_DEB_SHA256:-}" "$image_deb"
    verify_sha256 "${cache}/${headers_deb}" "${KERNEL_VPS_HEADERS_DEB_SHA256:-}" "$headers_deb"
    dpkg -i "${cache}/${image_deb}" "${cache}/${headers_deb}" || \
        apt-get install -f -y || \
        die "kernel package install failed; dpkg repair with apt-get install -f also failed"
    grub_default_custom_kernel
    log "installed ${KERNEL_VPS_VERSION}; it boots on the next reboot"
}

install_custom_kernel

note "kernel MPTCP capability check"
if [ "$(sysctl -n net.mptcp.enabled 2>/dev/null)" != "1" ]; then
    die "MPTCP is disabled in the kernel; this setup will not work."
fi
if ! grep -qw redundant /proc/sys/net/mptcp/available_schedulers 2>/dev/null; then
    warn "running kernel $(uname -r) has no 'redundant' scheduler: downloads to the Pi are not redundant until the VPS boots ${KERNEL_VPS_VERSION}"
fi

note "sysctl"
install_file "$SRC/sysctl-99-mptcp.conf"   /etc/sysctl.d/99-mptcp.conf
install_file "$SRC/sysctl-99-forward.conf" /etc/sysctl.d/99-forward.conf
sysctl --system >/dev/null 2>&1 || warn "some sysctl settings were not applied (expected on the stock kernel: net.mptcp.scheduler=redundant)"

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
render_template_force "$SRC/shadowsocks-server.json.template" /etc/shadowsocks/server.json 0600
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
$( [ "$(uname -r)" = "$KERNEL_VPS_VERSION" ] || printf '%s\n' \
"  - Reboot to start the MPTCP kernel ${KERNEL_VPS_VERSION} (the stock kernel
    stays installed); net.mptcp.scheduler=redundant takes effect then." )

Run this on the Pi:
   sudo env SS_PASSWORD=$(shell_quote "$SS_PASSWORD") VPS_IP=$(shell_quote "$VPS_IP") ./pi-install.sh
EOF
