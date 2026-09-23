# 2026-09-16: all three modems hung at 21:05 — hub-wide MBIM stall

Question asked: "What happened to all my modems a few minutes ago?" All three
upstreams (EE, Tesco, Talkmobile/Vodafone) dropped within ~60 s of each other
at about 21:06 local and did not come back on their own. Stefan replugged one
stick by hand at 21:08 to get internet back.

Answer: the three sticks stopped answering on their MBIM control channels at the
same instant. The USB bus never saw a disconnect, so the kernel never
re-enumerated them, and ModemManager eventually gave up on each one. This is a
hub/power event, not a cellular one, and not the Pi's own 5V rail this time.

## 1. Timeline (journalctl, boot of 2026-09-16 20:48)

| time | event |
| --- | --- |
| 20:58:20 | wwan2 (Vodafone SIM, port 1-1.1.1.4) lost carrier, bearer attempts failed for ~20 s, recovered by itself. Unrelated to what follows. |
| 21:05:46 | kernel: `cdc_mbim 1-1.1.1.4:1.3: Unexpected error -71` (EPROTO on the MBIM interface). |
| 21:05:52 | ModemManager: `[modem3/bearer8] reloading stats failed: Transaction timed out` — first sign cdc-wdm2 is dead. |
| 21:06:08 | cdc-wdm1 (modem1) starts timing out. |
| 21:06:09 | cdc-wdm0 (modem2) starts timing out. |
| 21:06:28 | `[modem3] port cdc-wdm2 timed out 10 consecutive times, marking modem as invalid`; NM: wwan2 `activated -> unmanaged (reason 'unmanaged-link-not-init', managed-type: 'removed')`. |
| 21:06:49 | same for modem1 / cdc-wdm1 / wwan1. |
| 21:06:50 | same for modem2 / cdc-wdm0 / wwan0. **All upstreams gone.** |
| 21:08:24 | manual replug of 1-1.1.1.4: `USB disconnect, device number 17`, preceded by a burst of ~35 more `Unexpected error -71`. |
| 21:08:34 | re-enumerated as device 18, then again at 21:08:44 as device 19 (the stick's usual double-enumeration on insert). |
| 21:09:12 | new modem4 on cdc-wdm2 connected, on `upstream-dummy-cdc-wdm2` (the SIM-profile race, see `../carrier-profiles/2026-09-12-sim-operator-id-race.md`). |

State after the manual replug:

- `mmcli -L` lists one modem (modem4). `nmcli dev` has no cdc-wdm0 / cdc-wdm1.
- `lsusb -t` still shows all three sticks enumerated with all 5 interfaces,
  `option` and `cdc_mbim` bound, and `/dev/cdc-wdm{0,1,2}` all exist. The two
  untouched sticks are firmware-hung but electrically present.

## 2. Why "hub or power", not cellular or the Pi

- Three different carriers stalled within 25 s of each other. A network-side
  cause cannot do that.
- No `USB disconnect` for 1-1.1.1.2 or 1-1.1.4 — the sticks did not lose VBUS
  long enough to drop off the bus, they just stopped responding.
- All three hang off hub `1-1.1` (dev 009): two via the child hub `1-1.1.1`
  (dev 010, ports 2 and 4), one directly on port 4 of `1-1.1`.
- Pi 5V rail is clean: `/sys/class/hwmon/hwmon1/in0_lcrit_alarm` = 0 and
  `vcgencmd get_throttled` = `0x0` for the whole boot. So unlike the 09-12
  and 09-15 events this was **not** a Pi undervoltage.
- Best guess: the hub's own supply sagged under simultaneous TX load, or the
  hub silicon glitched. `-71` (EPROTO) from the host controller is the
  signature of a device that stopped ACKing mid-transaction. Same shape as
  the 2026-09-14 18:08 event in `2026-09-14-hub-branch-collapse.md` (EE stick stops answering MBIM,
  `error -71`), minus the "disabled by hub" port faults this time.

## 3. Recovery without touching cables — what was tried

### 3a. Driver unbind/rebind: does NOT work (control channel only)

```
for d in 1-1.1.1.2 1-1.1.4; do
  echo $d | sudo tee /sys/bus/usb/drivers/usb/unbind
  sleep 2
  echo $d | sudo tee /sys/bus/usb/drivers/usb/bind
done
```

Run at 21:19:15. Looked like a success at first:

- kernel re-attached `option` ttys and `cdc_mbim` for both sticks within 2 s,
  with **no** `reset` or `new high-speed USB device` line — this only
  re-probes the drivers, the device itself is never reset.
- ModemManager created modem5 (EE) and modem6 (Tesco) at 21:19:37/39, both
  registered LTE and reported bearer `connected: yes` with an address,
  gateway and DNS within 3 s.
- NM activated `upstream-dummy-cdc-wdm0` and `upstream-tesco`; the dispatcher
  added `ip rule` 100/101, table defaults and MPTCP endpoints correctly.

But the data path was dead:

| iface | tx pkts | rx pkts | `ping -I` 1.1.1.1 |
| --- | --- | --- | --- |
| wwan0 | 195 | 0 | 100% loss |
| wwan1 | 213 | 0 | 100% loss |
| wwan2 (physically replugged) | — | — | 0% loss, 37 ms |

So the MBIM control channel wakes up under a rebind, the modem happily
reports a connected bearer, but the NTB data session on the stick is still
wedged. Beware: `mmcli`/`nmcli` say "connected" and everything looks green.
Only the RX counter (or a ping) tells the truth.

### 3b. USB device reset (USBDEVFS_RESET): WORKS

This is what a physical replug does electrically: a port reset and full
re-enumeration of the device. `/usr/bin/usbreset` is already installed
(usbutils), or the ioctl can be issued from python:

```
sudo usbreset /dev/bus/usb/001/015     # 1-1.1.1.2, EE
sudo usbreset /dev/bus/usb/001/016     # 1-1.1.4, Tesco
```

(bus/dev numbers from `cat /sys/bus/usb/devices/<port>/{busnum,devnum}`.)

Run at 21:21:42 and 21:21:46. Result:

- kernel: `usb 1-1.1.1.2: reset high-speed USB device number 15 using
  xhci_hcd`, ttys and cdc_mbim re-attached 200 ms later. Same for 1-1.1.4.
  The device number is kept (15/16), so `/dev/bus/usb` paths stay stable.
- ModemManager created modem7 (EE) and modem8 (Tesco); both connected and NM
  activated `upstream-dummy-cdc-wdm0` and `upstream-tesco` by 21:22:06 and
  21:22:09 — about 25 s after the reset.
- EE handed out a new address (100.71.34.43/29, was 10.53.83.104/28), Tesco
  kept 10.137.77.135. All three interfaces now have rx > 0 and 0% ping loss
  through each of wwan0, wwan1, wwan2.

Total outage for the two untouched sticks: 21:06:49 → 21:22:09, ~15 min,
all of it waiting for a human. The fix itself takes ~25 s.

## 4. Takeaways

1. **Detection signature** for a watchdog: `ModemManager: <err> [modemN] port
   cdc-wdmN timed out 10 consecutive times, marking modem as invalid`, or
   NM `state change: activated -> unmanaged (reason
   'unmanaged-link-not-init')` on a wwan device while the USB device is still
   present in `/sys/bus/usb/devices/`. A stick that is truly unplugged
   re-enumerates by itself and needs nothing.
2. **Remedy**: `usbreset` on the stuck device node. Not driver rebind — that
   produces a false "connected" with a dead data path.
3. The 4-port-hub tree (`1-1.1` → `1-1.1.1`) is the common ancestor of all
   three sticks; a hub-level event takes all upstreams down at once, which is
   exactly what MPTCP redundancy cannot protect against. Powering the sticks
   from separate hubs/ports, or a powered hub with a real supply, is the
   structural fix. `uhubctl` is not installed; unknown whether either hub
   supports per-port power switching.
4. Two of three sticks came back on `upstream-dummy-*` profiles rather than
   their SIM-matched ones (EE this time). That is the existing
   sim-operator-id race, not part of this incident, but every reset re-rolls
   the dice.

## 5. Follow-up 2026-09-17: it recurred, and is now handled automatically

The same signature four times in one morning, on a fresh boot each time
(hard reboot at ~09:34, another at ~09:56): `cdc_mbim 1-1.2.N:1.3:
Unexpected error -71` on two sticks in the same second (09:36:34, 09:58:15,
10:16:55/10:17:06, 10:28:27/10:28:48), ModemManager marking each invalid ~45 s
later, no USB disconnect, Pi 5 V clean. The sticks now enumerate under
`1-1.2.x` (StarTech hub 14b0:045a), and the Tesco stick even failed its
first enumeration at boot (`can't set config #1, error -71`). Hub or its
supply, as before.

What changed:

- **Relay repo, branch `fix/eproto-hub-hang-recovery`**: `modem-watchdog.service`
  (`etc_files_pi/sbin-modem-watchdog`, installed by `pi-install.sh`). Every
  20 s it compares the Alcatel devices in `/sys/bus/usb/devices` with the USB
  port behind each ModemManager modem; a stick with no modem for 60 s gets
  `usbreset BBB/DDD`, at most once per 5 min per port, logged to `/dev/kmsg`.
  Installed and enabled on the Pi; it survives reboot. README section
  "Hub-wide MBIM hang and the modem-watchdog".
- **usbreset argument form**: this usbutils build rejects
  `/dev/bus/usb/001/NNN` ("No such device found"); use `001/NNN`,
  `1bbb:00b6` or the product name. The examples in section 3b above used the
  path form and only worked by luck of an older binary or a typo in my notes;
  treat `BBB/DDD` as the correct form.
- **connectivity_logging** (local commits, no remote): the power/USB chart
  gets level 6 `mbim-error` (the `-71` line, with port and errno) and level 7
  `usb-reset` (the watchdog's kmsg line). journald turns the `modem-watchdog:`
  prefix into the syslog identifier, so the live `journalctl -o cat` tail
  sees `usbreset 1-1.2.N (...)` without the prefix; the parser accepts both.

Verified live: 10:28:48 stick 1-1.2.2 hung, 10:28:51 watchdog reset it,
10:28:52 re-enumerated, connected ~25 s later; netlog logged both records.
Before the watchdog, each of these outages waited for a human replug.

Still open: the structural fix (sticks on separate hubs or a powered hub), and
the `sim-operator-id` race that every reset re-rolls.
