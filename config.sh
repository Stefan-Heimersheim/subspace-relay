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

# Pinned linux-mptcp-redundant release (https://github.com/Stefan-Heimersheim/linux-mptcp-redundant/releases)
KERNEL_REPO="https://github.com/Stefan-Heimersheim/linux-mptcp-redundant"
KERNEL_RELEASE="v6.12.107-2"
KERNEL_PKG_VERSION="6.12.107-2"
KERNEL_VERSION="6.12.107-v8-mptcp-redundant"     # Pi, arm64
KERNEL_VPS_VERSION="6.12.107-mptcp-redundant"    # VPS, amd64
KERNEL_IMAGE_DEB_SHA256="fd92389ba38991876040b3a1b39ec05c6c771e7650cbe8e77a79fcd5a4e5af95"
KERNEL_HEADERS_DEB_SHA256="615a9192f45595d762b1b4dda7ff1dce7ad6658d987e324e09d6c64d7212db8f"
KERNEL_VPS_IMAGE_DEB_SHA256="bce2ce4f76f9a49edbdaaf3a7afb28e79975ffcde1d4dca9f5cd834fcb46a56d"
KERNEL_VPS_HEADERS_DEB_SHA256="f59672f7d31457b7ff7f2951c7b68fe12da4890e5012ad3478150bfe707eeb6a"

# ------- Pi-only -------
# WiFi access point. Generated random PSK if left blank.
AP_SSID="PiMPTCP"
AP_PSK=""           # leave blank for openssl-generated random; will be saved into the .nmconnection
AP_SUBNET="192.168.4"  # AP serves $AP_SUBNET.0/24 with $AP_SUBNET.1 as the Pi

# ------- VPS-only -------
# WAN interface name (auto-detected if empty).
VPS_WAN_IFACE=""
