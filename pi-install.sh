#!/bin/bash
# Pi pre-reboot install — fully idempotent. Reads ./config.sh for defaults;
# VPS_IP and SS_PASSWORD can be passed in the environment from vps-install.sh.
# Fetches sslocal, renders templates, and installs persistent boot-time config.
#
# Run on the Pi as root: `sudo ./pi-install.sh`

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
SRC="$ROOT/etc_files_pi"
. "$ROOT/lib.sh"
require_root "$@"

generate_psk() {
    openssl rand -base64 18 | tr -d '+/='
}

read_shadowsocks_client_config() {
    local path=$1 key=$2
    [ -s "$path" ] || return 1
    if command -v jq >/dev/null 2>&1; then
        jq -er "$key // empty" "$path" 2>/dev/null
        return
    fi
    case "$key" in
        .servers[0].server)
            sed -n 's/^[[:space:]]*"server"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$path" | head -n 1
            ;;
        .servers[0].password)
            sed -n 's/^[[:space:]]*"password"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$path" | head -n 1
            ;;
        *)
            return 1
            ;;
    esac
}

ENV_VPS_IP="${VPS_IP:-}"
ENV_SS_PASSWORD="${SS_PASSWORD:-}"
ENV_AP_PSK="${AP_PSK:-}"

CFG="$ROOT/config.sh"
[ -e "$CFG" ] || die "missing $CFG"
. "$CFG"
[ -n "$ENV_VPS_IP" ] && VPS_IP="$ENV_VPS_IP"
[ -n "$ENV_SS_PASSWORD" ] && SS_PASSWORD="$ENV_SS_PASSWORD"
[ -n "$ENV_AP_PSK" ] && AP_PSK="$ENV_AP_PSK"

# Fill defaults / recover from live config if blank.
if [ -z "${VPS_IP:-}" ]; then
    VPS_IP="$(read_shadowsocks_client_config /etc/shadowsocks/client.json '.servers[0].server' || true)"
fi
if [ -z "${SS_PASSWORD:-}" ]; then
    SS_PASSWORD="$(read_shadowsocks_client_config /etc/shadowsocks/client.json '.servers[0].password' || true)"
fi
[ -n "${VPS_IP:-}" ] || die "set VPS_IP in config.sh, pass VPS_IP=... on the command line, or keep /etc/shadowsocks/client.json on the Pi"
require_ipv4 VPS_IP "$VPS_IP"
[ -n "${SS_PASSWORD:-}" ] || die "set SS_PASSWORD in config.sh, pass SS_PASSWORD=... on the command line, or keep /etc/shadowsocks/client.json on the Pi"
: "${SS_PORT:=10001}"
: "${SS_METHOD:=chacha20-ietf-poly1305}"
: "${AP_SSID:=PiMPTCP}"
: "${AP_SUBNET:=192.168.4}"
if [ -z "${AP_PSK:-}" ]; then
    AP_PSK=$(generate_psk)
    log "generated random AP_PSK (re-run preserves it via existing nmconnection)"
fi
export VPS_IP SS_PORT SS_METHOD SS_PASSWORD AP_SSID AP_SUBNET AP_PSK

install_pi_packages() {
    note "Pi packages"
    echo iptables-persistent iptables-persistent/autosave_v4 boolean false | debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean false | debconf-set-selections
    # Runtime: network-manager modemmanager dnsmasq iptables-persistent.
    # Install-time: curl (fetch sslocal), xz-utils (extract), gettext-base
    # (envsubst), openssl (AP_PSK). vnstat: enabled as a service below.
    # jq: reads password from existing config.
    apt_ensure network-manager modemmanager mobile-broadband-provider-info \
        dnsmasq iptables-persistent \
        curl xz-utils gettext-base openssl vnstat jq
}

install_custom_kernel() {
    note "custom MPTCP kernel"
    local image_deb headers_deb cache url_base boot_config
    image_deb="linux-image-${KERNEL_VERSION}_${KERNEL_PKG_VERSION}_arm64.deb"
    headers_deb="linux-headers-${KERNEL_VERSION}_${KERNEL_PKG_VERSION}_arm64.deb"
    cache="/tmp/mptcp-kernel-${KERNEL_RELEASE}"
    url_base="${KERNEL_REPO}/releases/download/${KERNEL_RELEASE}"
    boot_config="/boot/firmware/config.txt"

    if [ "$(dpkg-query -W -f='${Version}' "linux-image-${KERNEL_VERSION}" 2>/dev/null || true)" = "$KERNEL_PKG_VERSION" ] &&
       [ "$(dpkg-query -W -f='${Version}' "linux-headers-${KERNEL_VERSION}" 2>/dev/null || true)" = "$KERNEL_PKG_VERSION" ]; then
        log "kernel packages already installed (${KERNEL_PKG_VERSION}); skipping kernel download"
    else
        install -d "$cache"
        fetch_url "${url_base}/${image_deb}" "${cache}/${image_deb}"
        fetch_url "${url_base}/${headers_deb}" "${cache}/${headers_deb}"
        verify_sha256 "${cache}/${image_deb}" "${KERNEL_IMAGE_DEB_SHA256:-}" "$image_deb"
        verify_sha256 "${cache}/${headers_deb}" "${KERNEL_HEADERS_DEB_SHA256:-}" "$headers_deb"
        dpkg -i "${cache}/${image_deb}" "${cache}/${headers_deb}" || \
            apt-get install -f -y || \
            die "kernel package install failed; dpkg repair with apt-get install -f also failed"
    fi

    install_file "/boot/vmlinuz-${KERNEL_VERSION}" /boot/firmware/kernel8-mptcp.img
    install_file "/boot/initrd.img-${KERNEL_VERSION}" /boot/firmware/initramfs8-mptcp

    note "/boot/firmware/config.txt — MPTCP kernel selection"
    touch "$boot_config"
    local need_kernel=0 need_initramfs=0 tmp
    grep -qxF 'kernel=kernel8-mptcp.img' "$boot_config" || need_kernel=1
    grep -qxF 'initramfs initramfs8-mptcp followkernel' "$boot_config" || need_initramfs=1
    if [ "$need_kernel" -eq 0 ] && [ "$need_initramfs" -eq 0 ]; then
        log "config.txt already references kernel8-mptcp.img and initramfs8-mptcp"
        return 0
    fi

    tmp=$(mktemp)
    if grep -qxF '[all]' "$boot_config"; then
        awk -v add_kernel="$need_kernel" -v add_initramfs="$need_initramfs" '
            { print }
            !done && $0 == "[all]" {
                if (add_kernel == 1) print "kernel=kernel8-mptcp.img"
                if (add_initramfs == 1) print "initramfs initramfs8-mptcp followkernel"
                done = 1
            }
        ' "$boot_config" > "$tmp"
    else
        cat "$boot_config" > "$tmp"
        printf '\n[all]\n' >> "$tmp"
        [ "$need_kernel" -eq 1 ] && printf 'kernel=kernel8-mptcp.img\n' >> "$tmp"
        [ "$need_initramfs" -eq 1 ] && printf 'initramfs initramfs8-mptcp followkernel\n' >> "$tmp"
    fi
    install_file "$tmp" "$boot_config"
    rm -f "$tmp"
    log "updated config.txt custom-kernel selection"
}

install_persistent_config() {
    note "shadowsocks-rust binary"
    install_ss_rust "${SS_RUST_PI_ARCH:-aarch64-unknown-linux-gnu}" sslocal

    note "journald"
    install -d /etc/systemd/journald.conf.d
    install_file "$SRC/journald-99-persistent.conf" /etc/systemd/journald.conf.d/99-persistent.conf
    systemctl restart systemd-journald

    note "sysctl files"
    install_file "$SRC/sysctl-99-mptcp.conf"   /etc/sysctl.d/99-mptcp.conf
    install_file "$SRC/sysctl-99-forward.conf" /etc/sysctl.d/99-forward.conf

    note "systemd units"
    install_file "$SRC/mptcp-limits.service"        /etc/systemd/system/mptcp-limits.service
    local ss_unit_tmp; ss_unit_tmp=$(mktemp)
    sed "s|__VPS_IP__|$VPS_IP|g" "$SRC/shadowsocks-client.service" > "$ss_unit_tmp"
    install_file "$ss_unit_tmp" /etc/systemd/system/shadowsocks-client.service
    rm -f "$ss_unit_tmp"
    systemctl daemon-reload
    systemctl disable mptcp-fulltunnel.service >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/mptcp-fulltunnel.service
    systemctl daemon-reload
    systemctl enable NetworkManager-wait-online.service >/dev/null 2>&1 || true
    systemctl enable mptcp-limits.service shadowsocks-client.service >/dev/null

    note "udev + helpers"
    install_file "$SRC/udev-99-alcatel-mbim.rules" /etc/udev/rules.d/99-alcatel-mbim.rules
    install_file "$SRC/sbin-alcatel-mbim-fix"      /usr/local/sbin/alcatel-mbim-fix 0755

    note "NetworkManager"
    install_file "$SRC/NetworkManager.conf" /etc/NetworkManager/NetworkManager.conf
    local dispatcher_tmp; dispatcher_tmp=$(mktemp)
    sed "s|__VPS_IP__|$VPS_IP|g" "$SRC/networkmanager-dispatcher-99-mptcp-wwan" > "$dispatcher_tmp"
    install_file "$dispatcher_tmp" /etc/NetworkManager/dispatcher.d/99-mptcp-wwan 0755
    rm -f "$dispatcher_tmp"
    install -d -m 0700 /etc/NetworkManager/system-connections

    # eth0 lifeline — static 192.168.2.1/24, never-default, NOT an MPTCP subflow.
    # This must always be present; without it NM auto-generates a DHCP "Wired
    # connection 1" that hangs and the lifeline disappears.
    install_file "$SRC/downstream-eth0.nmconnection" \
        /etc/NetworkManager/system-connections/downstream-eth0.nmconnection 0600
    # Drop NM's ephemeral autogenerated profile if it ever appeared, and the
    # legacy netplan-generated YAML stubs that originally produced netplan-eth0.
    rm -f "/etc/NetworkManager/system-connections/Wired connection 1.nmconnection"
    rm -f /etc/netplan/90-NM-*.yaml

    # Render nmconnection profiles. The keyfile plugin requires mode 0600.
    install_file "$SRC/upstream-vodafone.nmconnection" \
        /etc/NetworkManager/system-connections/upstream-vodafone.nmconnection 0600
    # SIM-matched carrier profile. Tesco (O2) rejects the dummy/auto APNs, so it
    # needs its real APN and must outrank them; see the README.
    install_file "$SRC/upstream-tesco.nmconnection" \
        /etc/NetworkManager/system-connections/upstream-tesco.nmconnection 0600
    render_template \
        "$SRC/downstream-wlan0.nmconnection.template" \
        /etc/NetworkManager/system-connections/downstream-wlan0.nmconnection 0600
    # Generic auto-config GSM profile, one per possible modem control port. NM
    # binds gsm connections to the MBIM control port (cdc-wdmN), not wwanN.
    for i in $(seq 0 7); do
        export MODEM_IFACE="cdc-wdm${i}" MODEM_ID="upstream-auto-cdc-wdm${i}"
        render_template_force \
            "$SRC/upstream-auto-cdc-wdm.nmconnection.template" \
            "/etc/NetworkManager/system-connections/upstream-auto-cdc-wdm${i}.nmconnection" 0600
        export MODEM_ID="upstream-dummy-cdc-wdm${i}"
        render_template_force \
            "$SRC/upstream-dummy-cdc-wdm.nmconnection.template" \
            "/etc/NetworkManager/system-connections/upstream-dummy-cdc-wdm${i}.nmconnection" 0600
    done
    for i in $(seq 1 8); do
        export LTE_IFACE="eth${i}" LTE_ID="upstream-eth${i}"
        render_template_force \
            "$SRC/upstream-eth.nmconnection.template" \
            "/etc/NetworkManager/system-connections/upstream-eth${i}.nmconnection" 0600
    done

    note "dnsmasq"
    install_file "$SRC/dnsmasq.conf" /etc/dnsmasq.conf
    systemctl enable dnsmasq >/dev/null
    systemctl reload dnsmasq 2>/dev/null || systemctl restart dnsmasq || true

    note "iptables rules file"
    install -d /etc/iptables
    install_file "$SRC/iptables-rules.v4" /etc/iptables/rules.v4
    systemctl enable netfilter-persistent >/dev/null

    note "/etc/shadowsocks/client.json"
    install -d /etc/shadowsocks
    render_template_force "$SRC/shadowsocks-client.json.template" /etc/shadowsocks/client.json 0600

    note "vnstat"
    systemctl enable vnstat >/dev/null 2>&1 || true
}

install_pi_packages
install_custom_kernel
install_persistent_config

cat <<EOF

Pre-reboot install complete. AP credentials (save these):
  SSID:      ${AP_SSID}
  PSK:       (in /etc/NetworkManager/system-connections/downstream-wlan0.nmconnection)
  Subnet:    ${AP_SUBNET}.0/24

Reboot now to switch kernels and let boot-time
services apply sysctl, iptables, NetworkManager, MPTCP limits, and
shadowsocks-client:
  sudo reboot
EOF
