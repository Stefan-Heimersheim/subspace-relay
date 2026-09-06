# Optional defaults for vps-install.sh and pi-install.sh. You can leave this
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
SS_RUST_SHA256_AARCH64_UNKNOWN_LINUX_GNU="dc56150cb263e1e150af33cc4c6542035aab3edf602e340842cca4138a4d5c51"
SS_RUST_SHA256_X86_64_UNKNOWN_LINUX_GNU="5f528efb4e51e732352f5c69538dcc76e8cf8f6d1a240dfb5b748a67f0b05f65"

# Pinned Raspberry Pi custom-kernel package hashes.
KERNEL_IMAGE_DEB_SHA256="15dff0282bb5de93220d1d396d170a944b4631f9975b5b7c747b8ed9fc55c699"
KERNEL_HEADERS_DEB_SHA256="5172d7892052a2af0e5ddef38a9b1f3b5d1115ce7f03620c54a3c2a40b0b43e3"

# ------- Pi-only -------
# WiFi access point. Generated random PSK if left blank.
AP_SSID="PiMPTCP"
AP_PSK=""           # leave blank for openssl-generated random; will be saved into the .nmconnection
AP_SUBNET="192.168.4"  # AP serves $AP_SUBNET.0/24 with $AP_SUBNET.1 as the Pi

# ------- VPS-only -------
# WAN interface name (auto-detected if empty).
VPS_WAN_IFACE=""
