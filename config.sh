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

# Pinned custom-kernel package hashes (linux-mptcp-redundant release
# ${KERNEL_RELEASE}, see pi-install.sh / vps-install.sh for the tag and
# versions). Pi: arm64 "-v8" packages. VPS: amd64 packages.
KERNEL_IMAGE_DEB_SHA256="5fc95a9af6e44fe3bef67ada82148712f4f627dbef3254311c1c8db9f4a202b7"
KERNEL_HEADERS_DEB_SHA256="d2278d6d0aa3b7a19e582aa492594faf46cff99892f42c3969034c853c02c790"
KERNEL_VPS_IMAGE_DEB_SHA256="e8ce88020e19a2e227a68987c794cdd833f9507a0eea3d396ae0ba8011509082"
KERNEL_VPS_HEADERS_DEB_SHA256="0089f95a0ba3e63a1c118f3635eb172707b7b30131c1693727ca1109909fc3c4"

# ------- Pi-only -------
# WiFi access point. Generated random PSK if left blank.
AP_SSID="PiMPTCP"
AP_PSK=""           # leave blank for openssl-generated random; will be saved into the .nmconnection
AP_SUBNET="192.168.4"  # AP serves $AP_SUBNET.0/24 with $AP_SUBNET.1 as the Pi

# ------- VPS-only -------
# WAN interface name (auto-detected if empty).
VPS_WAN_IFACE=""
