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

## Raspberry Pi setup

On a Raspberry Pi (tested with Raspberry Pi OS) clone this repo and run
the command printed by the VPS installer, e.g.
```bash
sudo env SS_PASSWORD='...' VPS_IP='...' ./pi-install.sh
```
and then reboot.

## Work in progress
- Access point setup (work in progress). Currently only connecting to the router via ethernet is supported.
