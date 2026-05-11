# Optional defaults for vps-install.sh, pi-install.sh, and pi-post-reboot.sh. You can leave this
# file as-is: vps-install.sh generates SS_PASSWORD and VPS_IP, then prints the
# exact pi-install.sh command to run on the Pi.

# ------- Shadowsocks (shared between Pi client and VPS server) -------
VPS_IP=""
SS_PORT=8388
SS_METHOD="chacha20-ietf-poly1305"
SS_PASSWORD=""

# Pinned shadowsocks-rust release (https://github.com/shadowsocks/shadowsocks-rust/releases)
SS_RUST_VERSION="v1.24.0"
# Architectures: aarch64-unknown-linux-gnu  for Pi
#                x86_64-unknown-linux-gnu   for VPS
SS_RUST_PI_ARCH="aarch64-unknown-linux-gnu"
SS_RUST_VPS_ARCH="x86_64-unknown-linux-gnu"

# ------- Pi-only -------
# SIM APNs. Empty string disables installing that profile.
TALKMOBILE_APN="talkmobile.co.uk"
EE_APN="eesecure"   # NOT "everywhere" — see CLAUDE.md
VODAFONE_APN="wap.vodafone.co.uk"

# WiFi access point. Generated random PSK if left blank.
AP_SSID="PiMPTCP"
AP_PSK=""           # leave blank for openssl-generated random; will be saved into the .nmconnection
AP_SUBNET="192.168.4"  # AP serves $AP_SUBNET.0/24 with $AP_SUBNET.1 as the Pi

# Routing mode: "full" (half-default routes via tun0 capture all
# traffic — the default on the live Pi since 2026-05-09) or "split"
# (default to wlan/wwan; tunnel only for explicit --interface tun0).
ROUTING_MODE="full"

# ------- VPS-only -------
# WAN interface name (auto-detected if empty).
VPS_WAN_IFACE=""
