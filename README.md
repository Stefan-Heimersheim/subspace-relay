# Subspace Relay

Multipath TCP (MPTCP)-based redundant internet connection. Connect your
devices to a Raspberry Pi with multiple e.g. LTE internet connections.
The Raspberry Pi will aggregate all links and redundantly send packages
through all links; a VPS receives the redundant streams and merges them.

Requires [linux-mptcp-redundant](https://github.com/Stefan-Heimersheim/linux-mptcp-redundant/)
or another kernel with a redundant MPTCP scheduler, on both the router (e.g.
Raspberry Pi) and the server (e.g. VPS).

The functionality here is similar to [OpenMPTCPRouter](https://github.com/Ysurac/openmptcprouter),
an OpenWRT-based project.

## VPS setup

On a VPS (tested with Debian 13 and Ubuntu 24.04) clone this repo and run
```bash
sudo ./vps-install.sh
```

It installs the custom kernel, packages, generates a Shadowsocks password (`SS_PASSWORD`),
detects the public IP (`VPS_IP`), and prints the install command for the
Raspberry Pi. That printed command contains the `SS_PASSWORD` and `VPS_IP`
environment variables.

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
route can still point at `tun0`. Which modem holds that direct route decides
which carrier every tunnel connection's *initial* subflow uses, and on a carrier
that strips MPTCP that silently turns the whole tunnel into single-path TCP; see
"Carrier middleboxes and MPTCP" below.

## Service ownership

NetworkManager owns physical and client-facing link configuration on the Pi: the
`downstream-eth0` client LAN, the GSM modem profiles, the Ethernet-like modem
profiles `upstream-eth1` through `upstream-eth8`, and the optional
`downstream-wlan0` AP profile. The upstream modem profiles are marked
`never-default=true`; they supply addresses and gateways for their own
source-routing tables, but they do not become the ordinary system default route.
`downstream-eth0` is a static client LAN and is explicitly not an MPTCP subflow
endpoint. The SIM-matched `upstream-tesco` profile has top autoconnect priority
(55), followed by the device-bound `upstream-dummy-cdc-wdm` profiles (50),
`upstream-auto-cdc-wdm` (45) and the unbound `upstream-vodafone` (40).

GSM APN tolerance varies by carrier, so the profiles are layered. EE and
TalkMobile connect and carry real traffic with essentially any APN setting — a
correct APN, a nonsense APN, no APN line at all, or provider auto-configuration;
the only hard failure there is an empty `apn=` value, which makes the modem
refuse to activate. For those SIMs the preferred `upstream-dummy-cdc-wdm`
profiles are device-bound with a placeholder `apn=dummy`, so each modem has its
own working profile regardless of the SIM inserted, and `upstream-auto-cdc-wdm`
uses provider auto-configuration (`auto-config=true`) as the next choice; that
one requires the `mobile-broadband-provider-info` APN database, without which
activation fails like an empty `apn=`.

O2 and its MVNOs are strict and need the exact APN in two places: as the
profile's `apn=` *and* as the modem's own LTE attach APN, which lives in the
modem's non-volatile profile table and is not set by NetworkManager. With the
wrong attach APN the network silently ignores every PDN activation request and
the modem reports a bare `MBIM status error: Failure`. Hence `upstream-tesco`,
which carries the real `prepay.tesco-mobile.com` APN and outranks the
dummy/auto tiers; it is matched on `sim-operator-id=23410` rather than bound to a
control port, so it follows the SIM between modems and is never tried on another
carrier's SIM. `upstream-vodafone` remains an unbound last-resort profile because
a Vodafone SIM was finnicky in the past and needed a specific APN
(`wap.vodafone.co.uk`); the EE- and TalkMobile-specific profiles were dropped
since the dummy/auto profiles cover them. See the section below for the attach-APN
procedure and the Alcatel modem quirks.

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
address, installs that modem's default route into its per-interface table, and
maintains the direct VPS bypass route. On down events it removes the
endpoint/rule and tries to move the bypass route to another available modem
link.

iptables owns baseline NAT and TCP MSS clamping on the Pi. Traffic leaving
`tun0` is masqueraded, TCP SYN packets crossing `tun0` are clamped to MSS 1160,
and the `wlan0` AP profile uses NetworkManager `ipv4.method=shared`, so
NetworkManager owns AP-side NAT. On the VPS, decapsulated traffic leaving the
VPS WAN interface is masqueraded. IPv4 forwarding is enabled on both hosts
through sysctl. UDP is carried by the Shadowsocks `tcp_and_udp` tunnel mode;
there is no separate UDP relay service. ICMP is not given a separate owner in
this repo, so its behavior is whatever the TUN/tunnel path and kernel routing
support.

## Modem profile storage (NV) and the attach APN

Each modem keeps its own settings in non-volatile storage (NV) inside the stick —
a small flash area holding, among other things, a table of 3GPP data profiles.
NV is owned by the modem, not by the Pi: changes there survive reboots, replugs
and reinstalls, and they travel with the stick rather than with the SIM. Nothing
in this repo writes NV during installation, so a stick carries whatever its
previous owner left behind.

Both Alcatel sticks currently hold four 3GPP profiles, numbered 1-4. Profile 1 is
the *default profile* (QMI default profile number 1), and that is the one the
modem uses for its **LTE attach**: on LTE the modem must name an APN at the
moment it attaches, before NetworkManager is involved at all, and the network
creates a default EPS bearer for it. NetworkManager's `apn=` only applies to the
connect request that follows. Both sticks shipped with profile 1 set to
`latitude.bsci.com` (an M2M APN from their previous life); profiles 2-4 hold
further leftovers (`3300.bsci.com`, an empty APN, `uk.lebara.mobi`) and are
unused here.

Read the attach APN and the profile table with `qmicli` — these sticks expose QMI
through the MBIM port, and `-p` shares that port with the running ModemManager:

```bash
sudo qmicli -p -d /dev/cdc-wdmN --device-open-mbim --wds-get-lte-attach-parameters
sudo qmicli -p -d /dev/cdc-wdmN --device-open-mbim --wds-get-profile-list=3gpp
```

Change the attach APN by modifying profile 1, then reboot the modem so it
re-attaches (a radio or `mmcli --disable/--enable` cycle is not enough, and
`mmcli --reset` wedges this firmware — see "Alcatel modem quirks" below):

```bash
sudo qmicli -p -d /dev/cdc-wdmN --device-open-mbim \
  --wds-modify-profile="3gpp,1,apn=<apn>,pdp-type=IPV4V6,auth=NONE"
# then, on one of that modem's AT ports, reboot it:
printf 'AT+CFUN=1,1\r' > /dev/ttyUSBn
```

Which settings each carrier needs, as tested on these modems:

| SIM | NetworkManager profile | Attach APN (NV profile 1) | MPTCP passes? |
| --- | --- | --- | --- |
| EE (MCCMNC 23430) | any non-empty APN; `upstream-dummy-cdc-wdmN` (`apn=dummy`) works | irrelevant — connects fine with the leftover `latitude.bsci.com` | yes, on every port tested |
| TalkMobile (23415, Vodafone MVNO) | any non-empty APN, as EE | irrelevant — connects fine with the leftover `latitude.bsci.com` | yes, on every port tested |
| Tesco Mobile (23410, O2 MVNO) | `upstream-tesco`, exactly `prepay.tesco-mobile.com`; `dummy` and `mobile.o2.co.uk` both fail | must also be `prepay.tesco-mobile.com`, or every connect fails | **no** — O2's TCP proxy strips it on all but 7 ports, see below |
| Vodafone (23415) | `upstream-vodafone`, `wap.vodafone.co.uk` | not tested | not tested |

No username or password is needed on any of them, including Tesco, whose
published `tescowap`/`password` credentials are not required (`auth=NONE`
connects). An empty `apn=` always fails. Because the attach APN lives in the
stick and not on the SIM, moving a SIM to another modem can require setting
profile 1 on that modem too.

Note that Vodafone and its MVNO TalkMobile share MCCMNC 23415, so
`sim-operator-id` cannot distinguish them; that is why `upstream-vodafone` stays
an unbound low-priority fallback rather than being SIM-matched like
`upstream-tesco`. A TalkMobile SIM connects on the dummy profile long before the
Vodafone profile is reached.

## Carrier middleboxes and MPTCP

Not every mobile network passes MPTCP, and a network that does not breaks this
setup silently. Tested on 2026-09-12 with the three SIMs above against the VPS
and against `check.mptcp.dev`:

- **EE and TalkMobile pass MPTCP untouched**, both as the initial subflow
  (`MP_CAPABLE`) and as a joined subflow (`MP_JOIN`), on every port tried. A
  connection opened over one of them with the other joining gives a genuinely
  redundant two-path connection.
- **O2, and therefore Tesco Mobile, runs a transparent TCP proxy on IPv4** that
  terminates nearly every TCP connection. The SYN-ACK the Pi sees comes from the
  proxy, not from the VPS: it carries the proxy's own TCP fingerprint (`mss 1348,
  wscale 12, win 65535` where the VPS itself sends `wscale 7, win 65160`) and
  every MPTCP option is gone. The kernel then does what RFC 8684 requires and
  falls back to plain TCP, without any log message. Even a SYN to a port nothing
  listens on "connects" from a Tesco SIM, because the proxy accepts it before
  ever talking to the server. `MP_JOIN` is hit the same way: a join SYN sent over the
  O2 link comes back without the join option and the kernel resets that subflow,
  so an O2 modem can never be added as a second path either. The proxy is
  IPv4-only as far as we can tell, but the Tesco bearer returns no IPv6
  configuration even when asked for `ipv4v6`, so that is no escape.

### Why this makes redundancy fail instead of merely degrading

`sslocal` opens a new MPTCP connection to the VPS for every client flow. The
initial subflow of each follows the direct VPS bypass route in the main table,
and the dispatcher hands that route to whichever modem came up first and leaves
it there. If that modem is on O2, *every* tunnel connection is downgraded to
single-path TCP over O2 and the other modems' endpoints never get a join,
because a fallen-back connection cannot add subflows. Unplugging the O2 modem
then drops every client connection while unplugging the others changes nothing,
which is exactly what a redundancy test on 2026-09-12 showed. With an EE or
TalkMobile modem holding the bypass route the tunnel is MPTCP again, but the O2
modem still contributes nothing.

### How to tell

The MPTCP MIB counters give the answer without a packet capture. On the Pi:

```bash
nstat -az | grep -E 'MPCapableSYNTX|MPCapableSYNACKRX|MPCapableFallbackSYNACK|MPJoinSynTx|MPJoinSynAckRx'
```

A healthy Pi has `MPCapableSYNACKRX` close to `MPCapableSYNTX` and a growing
`MPJoinSynAckRx`. The broken state looks like `SYNTX 196, SYNACKRX 0,
FallbackSYNACK 175, MPJoinSynTx 0`. To test one carrier in isolation, open an
MPTCP socket bound to that modem's address and watch the counters move:

```bash
nstat -n   # reset the delta counters
python3 -c 'import socket; s=socket.socket(socket.AF_INET, socket.SOCK_STREAM, 262); s.bind(("<modem ip>",0)); s.connect(("<vps ip>", 10001)); s.close()'
nstat | grep -E 'MPCapableSYNACKRX|MPCapableFallbackSYNACK'
```

(`262` is `IPPROTO_MPTCP`.) `MPCapableSYNACKRX 1` means the carrier passes
MPTCP on that port; `MPCapableFallbackSYNACK 1` means it does not. A capture on
the modem interface shows the stripped SYN-ACK directly:

```bash
tcpdump -ni wwanN -v 'tcp port 10001 and tcp[tcpflags] & tcp-syn != 0'
```

### Ports the O2 proxy does not intercept

The proxy is applied per destination port, and a few ports are left alone,
apparently so that VoIP and VPN clients keep working. From an O2/Tesco SIM the
following ports reach the VPS directly, with the VPS's own TCP fingerprint in
the SYN-ACK and every MPTCP option intact: **20, 53, 1723, 5060, 10000, 10001
and 10002** — FTP-data, DNS, PPTP, SIP and a small block above 10000. Every
other port we have used, including 80, 443 and the former default 8388, is
proxied.
With a temporary MPTCP listener on the VPS, all seven passed `MP_CAPABLE` from
Tesco, and on 5060 and 10001 a connection opened over EE received working
`MP_JOIN`s from both Tesco and TalkMobile. The carrier still clamps MSS to 1348
on those ports, which is harmless.

Of the seven, 10001 is the sensible choice for this tunnel. 53 collides with
`systemd-resolved` on the VPS and is intercepted or rate-limited on many other
networks; 5060 is inspected by SIP application-level gateways on other carriers
and home routers, which may mangle non-SIP traffic; 1723 is often blocked as
PPTP. 10000-10002 carry no such baggage, and 10001 was verified on all three
carriers. This is carrier policy and can change without notice; the counters
above are the way to notice.

So the options for making an O2/Tesco link carry a redundant subflow are:

1. Run `ssserver` on one of the exempt ports (`SS_PORT=10001` in `config.sh`).
   Cheapest by far, and the preferred route.
2. Wrap the O2 path in a UDP tunnel such as WireGuard to the VPS and run the
   MPTCP subflow inside it, so the proxy never sees TCP options. UDP passes on
   all three carriers. Measured with a UDP echo on the VPS: EE and Tesco return
   payloads up to at least 1600 bytes (fragments allowed), TalkMobile drops
   payloads of 1472 bytes and above, so keep the outer tunnel MTU under about
   1400 there.
3. A different APN is not an option for Tesco (only `prepay.tesco-mobile.com`
   connects), and IPv6 is not offered on the bearer.

None of this is implemented yet; the installer does not check the carrier and
the dispatcher does not care which modem gets the bypass route.

## Alcatel modem quirks and recovery

The upstream modems are Alcatel `1bbb:00b6` sticks (Qualcomm MDM9607, firmware
`MPSS.JO.2.0.2.c1.7-00004-9607_`), driven by ModemManager's `generic` plugin over
MBIM. They have a number of sharp edges.

udev owns the Alcatel modem driver fix. The rule detects the affected USB
interface and runs `alcatel-mbim-fix`, which rebinds the device from `option` to
`cdc_mbim` so ModemManager/NetworkManager can bring it up as an MBIM modem.

**Identify a stick by its USB path, not by its modem index or `cdc-wdmN` name.**
Both change on every re-enumeration, and a debug session can easily walk a modem
index from 1 to 3. Map the stable paths with:

```bash
for m in $(mmcli -L | grep -o 'Modem/[0-9]*' | cut -d/ -f2); do
  echo "modem $m: $(mmcli -m $m | grep -m1 'device:' | grep -o '1-1\.[0-9.]*')"
done
```

**QMI is available through the MBIM port.** Use `qmicli --device-open-mbim` with
`-p` so it shares the port with the running ModemManager rather than fighting it.
This is how the NV profile table above is read and written.

**AT ports: use them directly.** `mmcli --command` is refused unless
ModemManager runs in debug mode (`Unauthorized: Operation only allowed in debug
mode`). ModemManager holds the AT ports open but does not poll them on an MBIM
modem, so writing to them directly is tolerated. Of each stick's three ttys, two
answer AT and one does not; map them with:

```bash
readlink -f /sys/class/tty/ttyUSB*/device | grep -o '1-1\.[0-9.]*'
```

**Never use `mmcli -m N --reset`.** It wedges this firmware: the modem comes back
in offline mode (`AT+CFUN?` returns `+CFUN: 7`, QMI operating mode `offline`,
MBIM software radio `off`) and then refuses every way back — `mmcli --enable`,
`--set-power-state-on`, `mbimcli --set-radio-state=on`,
`qmicli --dms-set-operating-mode=online` and `AT+CFUN=1` all fail with
`Invalid transition`, `Failure` or `+CME ERROR: 4`. Toggling
`/sys/bus/usb/devices/<path>/authorized` re-enumerates the device on the host but
does **not** cut VBUS, so the firmware keeps running and stays wedged.

**`AT+CFUN=1,1` is the way out**, and also the way to force a re-attach after
changing the attach APN. It reboots the modem: the device drops off the USB bus
and comes back about 30 seconds later, registered and attached. A physical
unplug/replug does the same.

**Getting the real reason a connect failed.** NetworkManager only ever reports
`Unknown error`, and ModemManager at default verbosity only `MBIM status error:
Failure`. The network's reject cause is visible solely in debug logs:

```bash
sudo mmcli -G DEBUG
CURSOR=$(journalctl -u ModemManager -n0 --show-cursor | grep -o 'cursor: .*' | cut -d' ' -f2)
sudo mmcli -m N --timeout=90 --simple-connect="apn=<apn>,ip-type=ipv4"
sudo mmcli -G INFO
journalctl -u ModemManager --after-cursor="$CURSOR" | grep -iE "nw error|activated|status error"
```

A line such as `session ID '0': deactivated (requested IP type: ipv4, activated
IP type: default, nw error: none)` means the network sent no reject cause at all
and simply never answered the PDN activation request — the signature of a wrong
attach APN, as opposed to an auth, subscription or IP-family problem, which all
produce a non-zero `nw error`.

**Debugging one modem without disturbing the relay.** Never restart
ModemManager or NetworkManager wholesale: the other modem is carrying live
upstream traffic. Instead set `connection.autoconnect no` on every profile that
can bind to that port (`upstream-dummy-cdc-wdmN`, `upstream-auto-cdc-wdmN` and
the unbound carrier profiles), `nmcli device disconnect cdc-wdmN`, then clear
stale bearers with `mmcli -m N --simple-disconnect` and
`--delete-bearer=<path>`. Restore autoconnect afterwards. Left alone, NM retries
every few seconds, bearers pile up, and the modem starts answering
`MBIM status error: Busy` to new requests while an earlier connect is still in
flight — a symptom that masks the real failure.

## Updating pinned artifacts

Downloaded root-installed artifacts are pinned in `config.sh`. When bumping
`SS_RUST_VERSION` or the `KERNEL_*` release and version variables, update the
matching `*_SHA256` values from the upstream release notes.

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
  installs `ssserver`, installs the custom MPTCP kernel, applies
  sysctl/firewall config, and prints the Pi install command.
- `pi-install.sh` - idempotent Pi installer. Installs packages, downloads and
  selects the custom MPTCP kernel, installs NetworkManager/dnsmasq/systemd/udev
  config, renders LTE/AP/Shadowsocks templates, and enables services.
- `etc_files_pi/NetworkManager.conf` - disables NetworkManager DNS/resolv.conf
  management and enables the keyfile plugin used by the connection profiles.
- `etc_files_pi/boot-config.txt.snippet` - reference snippet for selecting the
  custom Pi kernel and initramfs in `/boot/firmware/config.txt`.
- `etc_files_pi/dnsmasq.conf` - DHCP-only configuration for clients on `eth0`
  with gateway `192.168.2.1` and public DNS options.
- `etc_files_pi/downstream-eth0.nmconnection` - NetworkManager profile for the
  wired client LAN at `192.168.2.1/24`, with no default route and MPTCP
  explicitly disabled.
- `etc_files_pi/downstream-wlan0.nmconnection.template` - optional NetworkManager
  WiFi AP profile using `${AP_SSID}`, `${AP_PSK}`, and `${AP_SUBNET}.1/24`.
- `etc_files_pi/iptables-rules.v4` - persistent Pi NAT rules for `tun0`,
  TCP MSS clamping for the `tun0` path, and comments for NetworkManager-managed
  `wlan0` AP NAT.
- `etc_files_pi/journald-99-persistent.conf` - enables persistent systemd
  journal storage with size caps so logs survive reboots without unbounded SD
  card growth.
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
- `etc_files_pi/udev-99-alcatel-mbim.rules` - udev rule that detects the
  affected Alcatel USB modem interface and runs the MBIM rebind helper.
- `etc_files_pi/upstream-auto-cdc-wdm.nmconnection.template` - generic GSM
  profile using NetworkManager provider auto-configuration, rendered once per
  modem control port (`cdc-wdm0` through `cdc-wdm7`) with
  `${MODEM_IFACE}`/`${MODEM_ID}` as `upstream-auto-cdc-wdm0` through
  `upstream-auto-cdc-wdm7`.
- `etc_files_pi/upstream-dummy-cdc-wdm.nmconnection.template` - preferred
  device-bound GSM profile with a placeholder `apn=dummy`, rendered per modem
  control port as `upstream-dummy-cdc-wdm0` through `upstream-dummy-cdc-wdm7`.
- `etc_files_pi/upstream-eth.nmconnection.template` - NetworkManager Ethernet
  profile template for modem links `eth1` through `eth8`, rendered as
  `upstream-eth1` through `upstream-eth8`.
- `etc_files_pi/upstream-tesco.nmconnection` - Tesco Mobile GSM profile with the
  required `prepay.tesco-mobile.com` APN, matched on `sim-operator-id=23410`
  instead of a control port, at autoconnect priority 55.
- `etc_files_pi/upstream-vodafone.nmconnection` - Vodafone GSM fallback profile
  with a hardcoded `wap.vodafone.co.uk` APN and no device binding.
- `etc_files_vps/iptables-rules.v4` - persistent VPS NAT rule template; the
  installer replaces `ens3` with the detected or configured WAN interface.
- `etc_files_vps/shadowsocks-server.json.template` - VPS `ssserver`
  configuration template with MPTCP and TCP/UDP enabled.
- `etc_files_vps/shadowsocks-server.service` - systemd unit for the VPS
  Shadowsocks server.
- `etc_files_vps/sysctl-99-forward.conf` - enables IPv4 forwarding on the VPS.
- `etc_files_vps/sysctl-99-mptcp.conf` - enables MPTCP on the VPS and selects
  the redundant scheduler (accepted once the custom kernel is running).
