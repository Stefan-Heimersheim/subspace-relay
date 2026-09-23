# 2026-09-14: the 214b hub branch collapsing (18:08 and 18:21)

Two events with the same shape. Not a Pi undervoltage: the last hwmon
`Undervoltage detected!` was 18:00:50 (the 17:50–18:00 cluster while the sticks
enumerated), and no `over-current change` line appeared at either time.

## Topology at the time

VIA `1-1` → Genesys `1-1.3` → Genesys `1-1.3.1` → port 4: EE stick (`wwan0`,
`cdc-wdm0`); port 3: an unbranded 4-port "USB2.0 HUB" `214b:7250` at
`1-1.3.1.3`, carrying Talkmobile on `.1` and Tesco on `.4`. The Genesys
`1-1.3.1` hub had ports 1 and 2 free.

## 18:08, previous boot (`journalctl -b -1`)

1. 18:07:51 the EE stick, which is *not* on the 214b hub, stops answering MBIM:
   `[modem1] port cdc-wdm0 timed out N consecutive times` every 5 s, `marking
   modem as invalid` at 18:08:39. The whole `1-1.3.1` branch was unhealthy 17 s
   before anything visibly dropped.
2. 18:08:08–18:08:11 the 214b hub disables its own ports 4 and 1 five times
   (`usb 1-1.3.1.3-port4: disabled by hub (EMI?), re-enabling...`). Every
   re-enumeration fails with `-71` (`can't set config #1`, `can't read
   configurations`, `device descriptor read/64, error -71`). "disabled by hub"
   is the hub's port logic reporting a link fault, not the host.
3. 18:08:11 the Tesco stick comes back only at **full speed** (`new full-speed
   USB device`, `not running at top speed; connect to a high speed hub`), i.e.
   the high-speed chirp handshake failed on a link that was high-speed a minute
   earlier. Degraded electrical link: contacts, cable or the hub's 5 V.
4. 18:11–18:13 that full-speed stick (now `modem6`, `wwan1`) flaps
   `connected -> disconnecting` every 21 s (`failed to disconnect bearers:
   Bearer already being disconnected`).
5. EE stick disconnects at 18:09:48, 18:10:07, 18:13:48; the 8–10 s gaps on two
   of them look like hand replugs, the 0.25 s one is a self-reset.
6. `sudo reboot` at 18:15:37.

## 18:21, current boot

Same lead-in: `cdc-wdm0` timeouts from 18:20:51. At 18:21:23 both sticks under
the 214b hub drop, then at 18:21:24 the hub itself drops and never comes back:
full-speed attempts with `-32`, `Device not responding to setup address`,
`usb 1-1.3.1-port3: attempt power cycle`, `device not accepting address 14,
error -71`, `unable to enumerate USB device`. The hub has been absent from
`lsusb` since. Manual replug of the remaining EE stick at 18:23:44 (8 s gap);
it self-reset again at 18:24:02.

## Reading

Two independent devices on the `1-1.3.1` branch failing within seconds, with
the Pi rail fine, points at the supply feeding that branch. The sticks are
bus-powered 500 mA each; two of them transmitting LTE through a cheap
possibly-unpowered hub fed through two more hubs is a long resistive path. The
214b hub then failing to enumerate at all suggests it is dying or on a marginal
connector. The `cdc-wdm0` timeout run is a ~17 s early warning of the next one.

`netlog` (`../connectivity_logging`) recorded all of this as `kind: power`
records (`usb-disconnect` / `usb-connect` / `usb-enum-fail` with `port`), so the
first chart at <http://192.168.4.1:8080/> shows it.

## Next step

Retire the 214b hub: the Genesys `1-1.3.1` hub has ports 1 and 2 free, so all
three sticks fit on it directly if they physically clear each other. If a
separate hub is unavoidable, use one with its own PSU. If the same pattern
recurs with the 214b hub gone, the fault is upstream in the Genesys hub or its
supply.


## Open

Power supply unresolved, see `2026-09-12-pi-brownout-reboots.md`. Remove the
`214b:7250` hub first. (By 2026-09-17 the sticks were on a StarTech `14b0:045a`
hub as `1-1.2.x`; see `2026-09-16-hub-wide-mbim-hang.md`.)
