# 2026-09-12: unexpected Pi reboots were 5 V brownouts

## Boot history

| Boot | Started (journal clock) | Ended | How it ended |
| --- | --- | --- | --- |
| A | 17:07 | 18:09:27 | Clean: `./pi-install.sh` at 18:08:57, then `sudo reboot` at 18:09:23. |
| B | 18:09:29 | 18:15:32 | Abrupt. Last lines are `sslocal` "No route to host" errors, no shutdown sequence. |
| C | 18:11:54 (stale clock; NTP synced at 18:21:41) | 18:23:33 | Abrupt, ~10 s after the last manual `nmcli` command. |
| D | 18:23:20 (stale clock) | 18:23:21 | Abrupt after ~2 s. The journal (467 lines) holds only kernel boot and USB enumeration. |
| E (current) | 18:23:23 (stale clock; real ≈18:24:40) | — | 4 s into boot: `hwmon hwmon1: Undervoltage detected!`, `Voltage normalised` 2 s later. |

The Pi has no RTC; each boot starts on the clock saved by the previous one, so
boot start times overlap until `systemd-timesyncd` syncs. Order the boots by
`journalctl --list-boots` index, not by timestamp.

## Why it is power and not software

- Boots B, C and D have no `Shutting down`, `reboot.target` or panic/oops lines
  at all; they simply stop mid-log. Boot A, the deliberate reboot, shows the full
  systemd shutdown sequence for comparison.
- `kernel.panic` is `0` and no `RuntimeWatchdogSec` is configured, so a kernel
  crash or hang would *stay* hung; nothing in software can produce an instant,
  unlogged reset.
- Boot E logged the undervoltage flag at the exact moment the stick on USB port
  `1-1.1.1.4` dropped off the bus and re-enumerated (18:23:26–18:23:27 journal
  clock). The same "all sticks disconnect a few seconds after boot" pattern
  appears at the start of boot B (18:09:34, three sticks at once).
- Every reset coincided with modem activity: sticks and a hub were physically
  rearranged 18:12:58–18:13:45 (boot B), both modems were reconnecting at
  18:23:25 (boot C), and both sticks enumerate together at every boot (D, E).

## Hardware facts

- Two Alcatel sticks (`1bbb:00b6`), each declaring `bMaxPower=500mA`,
  bus-powered (`bmAttributes=80`).
- They hang off three chained hubs: VIA `2109:3431` → Genesys `05e3:0610` →
  Genesys `05e3:0610`. All three claim self-powered (`bmAttributes=e0`), but
  that is a static descriptor bit and does not prove a hub PSU is attached.
- Only two sticks are on the bus now; the EE stick from the afternoon table in
  `../carrier-profiles/2026-09-12-tesco-attach-apn.md` is absent. Physical placement also changed: TalkMobile is now at
  `1-1.1.1.4`, Tesco at `1-1.1.2`.
- `vcgencmd get_throttled` does **not** work on the custom kernel
  (`Can't open device file: /dev/vcio_gencmd`). Use the kernel hwmon lines
  instead: `journalctl -b -k | grep -iE 'voltage|throttl'`.

## How to check next time

```bash
journalctl --list-boots                      # abrupt ends = no shutdown lines in that boot
journalctl -b -1 --no-pager | tail -30       # previous boot's last lines
journalctl -b 0 -k | grep -iE 'voltage'      # rpi_volt hwmon: "Undervoltage detected!"
journalctl -b 0 -k | grep -E 'usb 1-1.*(USB disconnect|New USB device)'
```

Not fixed. Until the 5 V supply (Pi PSU/cable and/or hub power) is sorted,
every modem reconnect or replug is a chance for another reset.


## Related

The hub-branch collapse two days later (`2026-09-14-hub-branch-collapse.md`) is
the same supply question one hub further down.
To count undervoltage events per 10 min bucket:

```bash
sudo dmesg -T | grep 'Undervoltage detected' | awk '{print substr($4,1,4)"0"}' | sort | uniq -c
```
