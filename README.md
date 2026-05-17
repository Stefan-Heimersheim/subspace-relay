# Subspace Relay

Multipath TCP (MPTCP)-based redundant internet connection. Connect your
devices to a Raspberry Pi with multiple e.g. LTE internet connections.
The Raspberry Pi will aggregate all links and redundantly send packages
through all links; a VPS receives the redundant streams and merges them.

This uses my [linux-mptcp-redundant](https://github.com/Stefan-Heimersheim/linux-mptcp-redundant/)
as most existing kernels don't have a redundant MPTCP scheduler.

The functionality here is similar to [OpenMPTCPRouter](https://github.com/Ysurac/openmptcprouter),
an OpenWRT-based project.

## VPS setup

On a VPS (tested with Debian 13 and Ubuntu 24.04) clone this repo and run
```bash
sudo ./vps-install.sh
```

It installs packages, generates a Shadowsocks password (`SS_PASSWORD`),
detects the public IP (`VPS_IP`), and prints the install command for the
Raspberry Pi. That printed command contains the `SS_PASSWORD` and `VPS_IP`
environment variables.

The VPS installer treats disabled kernel MPTCP support as fatal.

## Raspberry Pi setup

On a Raspberry Pi (tested with Raspberry Pi OS) clone this repo and run
the command printed by the VPS installer, e.g.
```bash
 sudo env SS_PASSWORD='...' VPS_IP='...' ./pi-install.sh
```
and then reboot.

The leading space avoids bash history when `HISTCONTROL=ignorespace` or
`ignoreboth` is enabled.

## High-level setup

The Raspberry Pi is the client-side router. Client devices connect to it via
`eth0` (`192.168.2.1/24`) and, when enabled, the `wlan0` access-point profile.
The Pi has one or more upstream LTE modems exposed as `wwan*` interfaces. Those
LTE links are not offered directly to clients; they are used as the outer paths
for an MPTCP connection to the VPS.

The tunnel is a Shadowsocks-rust TUN tunnel. On the Pi, `sslocal` creates
`tun0` (`10.255.0.1/30`) and connects to the VPS using MPTCP with the redundant
scheduler from the custom kernel. On the VPS, `ssserver` accepts that connection,
decapsulates traffic, and NATs it out through the VPS WAN interface. The Pi
installs `0.0.0.0/1` and `128.0.0.0/1` routes through `tun0`, so client traffic
is routed through the redundant LTE-to-VPS path.

The Pi also keeps a direct route to the VPS public IP via one LTE interface.
That route is deliberately outside `tun0`; otherwise the tunnel transport would
try to reach the VPS through itself and loop. Per-LTE source-routing tables let
MPTCP open subflows over each `wwan*` link while the main client-facing default
route can still point at `tun0`.

## Service ownership

NetworkManager owns physical and client-facing link configuration on the Pi:
`eth0`, LTE modem profiles, the Ethernet-like modem profiles `eth1` through
`eth8`, and the optional `wlan0` AP profile. The LTE and Ethernet-like modem
profiles are marked `never-default=true`; they supply addresses and gateways for
their own source-routing tables, but they do not become the ordinary system
default route. `eth0` is a static client LAN and is explicitly not an MPTCP
subflow endpoint. `auto-lte` is the preferred GSM profile; APN-specific
profiles are fallbacks.

`dnsmasq` owns DHCP for the wired client LAN on `eth0`. It gives clients
addresses in `192.168.2.0/24`, default gateway `192.168.2.1`, and public DNS
resolvers. Its DNS server is disabled with `port=0`; it is not the Pi's caching
or forwarding DNS resolver. NetworkManager DNS management is disabled, and the
Pi installer writes `/etc/resolv.conf` with public resolvers for the Pi itself.
The `wlan0` AP profile uses NetworkManager's `ipv4.method=shared`, so when that
profile is activated NetworkManager owns the AP-side address sharing for that
interface.

`shadowsocks-client.service` owns the Pi tunnel process and full-tunnel routes.
It starts `sslocal`, which creates `tun0`, enables `tcp_and_udp` tunnel mode,
and uses top-level `mptcp=true` so the TCP connection to the VPS is an MPTCP
connection. The unit sets `tun0` MTU to `1200`, then installs the two
half-default routes via `tun0` with `ip route replace`. `shadowsocks-server.service`
owns the matching VPS-side `ssserver` process, runs as the dedicated
`shadowsocks` system user, and also uses `tcp_and_udp` and `mptcp=true`.

`mptcp-limits.service` owns the Pi boot-time MPTCP subflow limits. The VPS
installer applies the same limits directly during install. The custom Pi kernel
and both `99-mptcp.conf` files enable MPTCP; the Pi config also selects the
`redundant` scheduler.

`networkmanager-dispatcher-99-mptcp-wwan` owns hotplug behavior for modem
interfaces. On `wwan*` and `eth1` through `eth8` up events it adds an MPTCP
subflow endpoint, creates an `ip rule` for traffic sourced from that modem
address, installs that modem's default route into its per-interface table, adds
per-uplink NAT for direct-mode traffic, and maintains the direct VPS bypass
route. `wwanN` uses table `100+N` and metric `700+N`; `ethN` uses table `200+N`
and metric `800+N`. On down events it removes the endpoint, the exact
source-IP rule saved for that interface, the per-uplink NAT rule, and tries to
move the bypass route to another reachable modem link. A systemd timer runs the
same bypass health check every 60 seconds so a stale-but-up link can be
replaced without waiting for a link flap.

iptables owns baseline NAT and TCP MSS clamping on the Pi. Traffic leaving
`tun0` is masqueraded, TCP SYN packets crossing `tun0` are clamped to MSS 1160,
and dynamic direct-uplink NAT for `wwan*` and `eth1` through `eth8` is managed
by the dispatcher. The `wlan0` AP profile uses NetworkManager
`ipv4.method=shared`, so NetworkManager owns AP-side NAT. On the VPS,
decapsulated traffic leaving the VPS WAN interface is masqueraded. IPv4
forwarding is enabled on both hosts through sysctl. UDP is carried by the
Shadowsocks `tcp_and_udp` tunnel mode; there is no separate UDP relay service.
ICMP is not given a separate owner in this repo, so its behavior is whatever the
TUN/tunnel path and kernel routing support.

## Updating pinned artifacts

Downloaded root-installed artifacts are pinned by SHA256 in `config.sh`. When
bumping `SS_RUST_VERSION`, `KERNEL_RELEASE`, or `KERNEL_PKG_VERSION`, download
the new release artifacts from their upstream release pages and update:
`SS_RUST_SHA256_AARCH64_UNKNOWN_LINUX_GNU`,
`SS_RUST_SHA256_X86_64_UNKNOWN_LINUX_GNU`, `KERNEL_IMAGE_DEB_SHA256`, and
`KERNEL_HEADERS_DEB_SHA256`. The installers refuse to unpack or install an
artifact whose checksum does not match the configured value.

udev owns the Alcatel modem driver fix. The rule detects the affected USB
interface and runs `alcatel-mbim-fix`, which rebinds the device from `option` to
`cdc_mbim` so ModemManager/NetworkManager can bring it up as an MBIM modem.

## File inventory

- `README.md` - project overview, install instructions, architecture notes, and
  this file inventory.
- `LICENSE` - repository license.
- `config.sh` - shared configuration defaults for both installers: VPS address,
  Shadowsocks settings, pinned artifact versions and hashes, Pi AP/LTE settings,
  and optional VPS WAN interface override.
- `lib.sh` - shared installer helpers for root escalation, logging, template
  rendering, idempotent file installation, Shadowsocks-rust downloads, and IPv4
  validation.
- `vps-install.sh` - idempotent VPS installer. Installs packages, detects or
  reads the VPS IP and WAN interface, creates or reuses the Shadowsocks password,
  installs `ssserver`, applies sysctl/firewall config, and prints the Pi install
  command.
- `pi-install.sh` - idempotent Pi installer. Installs packages, downloads and
  selects the custom MPTCP kernel, installs NetworkManager/dnsmasq/systemd/udev
  config, renders LTE/AP/Shadowsocks templates, and enables services.
- `etc_files_pi/NetworkManager.conf` - disables NetworkManager DNS/resolv.conf
  management and enables the keyfile plugin used by the connection profiles.
- `etc_files_pi/auto-lte.nmconnection` - preferred generic GSM profile using
  NetworkManager provider auto-configuration.
- `etc_files_pi/boot-config.txt.snippet` - reference snippet for selecting the
  custom Pi kernel and initramfs in `/boot/firmware/config.txt`.
- `etc_files_pi/dnsmasq.conf` - DHCP-only configuration for clients on `eth0`
  with gateway `192.168.2.1` and public DNS options.
- `etc_files_pi/ee-lte.nmconnection.template` - EE GSM fallback profile for
  `cdc-wdm1`.
- `etc_files_pi/eth-lte.nmconnection.template` - NetworkManager Ethernet
  profile template for modem links `eth1` through `eth8`.
- `etc_files_pi/eth0.nmconnection` - NetworkManager profile for the wired
  client LAN at `192.168.2.1/24`, with no default route and MPTCP explicitly
  disabled.
- `etc_files_pi/iptables-rules.v4` - persistent Pi NAT rules for `tun0`,
  TCP MSS clamping for the `tun0` path, and comments for dispatcher-managed
  direct-uplink NAT and NetworkManager-managed `wlan0` AP NAT.
- `etc_files_pi/journald-99-persistent.conf` - enables persistent systemd
  journal storage with size caps so logs survive reboots without unbounded SD
  card growth.
- `etc_files_pi/mptcp-bypass-health.service` - systemd one-shot that asks the
  dispatcher to repair the direct VPS bypass route.
- `etc_files_pi/mptcp-bypass-health.timer` - periodic 60-second timer for the
  bypass health service.
- `etc_files_pi/mptcp-limits.service` - systemd one-shot that sets MPTCP subflow
  and accepted-address limits on boot.
- `etc_files_pi/networkmanager-dispatcher-99-mptcp-wwan` - NetworkManager
  dispatcher hook that manages MPTCP endpoints, per-modem source routing, and
  the direct VPS bypass route for `wwan*` and `eth1` through `eth8`
  interfaces.
- `etc_files_pi/sbin-alcatel-mbim-fix` - helper run by udev to rebind the
  affected Alcatel modem interface to `cdc_mbim`.
- `etc_files_pi/shadowsocks-client.json.template` - Pi `sslocal` TUN-mode
  configuration template with MPTCP and TCP/UDP enabled.
- `etc_files_pi/shadowsocks-client.service` - systemd unit for the Pi
  Shadowsocks client, including the `tun0` MTU adjustment.
- `etc_files_pi/sysctl-99-forward.conf` - enables IPv4 forwarding on the Pi.
- `etc_files_pi/sysctl-99-mptcp.conf` - enables MPTCP on the Pi and selects the
  redundant scheduler.
- `etc_files_pi/talkmobile-lte.nmconnection.template` - Talkmobile GSM fallback
  profile for `cdc-wdm0`.
- `etc_files_pi/udev-99-alcatel-mbim.rules` - udev rule that detects the
  affected Alcatel USB modem interface and runs the MBIM rebind helper.
- `etc_files_pi/vodafone-lte.nmconnection.template` - Vodafone GSM fallback
  profile for `cdc-wdm0`.
- `etc_files_pi/wlan0-AP.nmconnection.template` - optional NetworkManager WiFi
  AP profile using `${AP_SSID}`, `${AP_PSK}`, and `${AP_SUBNET}.1/24`.
- `etc_files_vps/iptables-rules.v4` - persistent VPS NAT rule template; the
  installer replaces `ens3` with the detected or configured WAN interface.
- `etc_files_vps/shadowsocks-server.json.template` - VPS `ssserver`
  configuration template with MPTCP and TCP/UDP enabled.
- `etc_files_vps/shadowsocks-server.service` - systemd unit for the VPS
  Shadowsocks server.
- `etc_files_vps/sysctl-99-forward.conf` - enables IPv4 forwarding on the VPS.
- `etc_files_vps/sysctl-99-mptcp.conf` - enables MPTCP on the VPS.
