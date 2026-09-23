# 2026-09-23: MBIM error burst after a cold boot — the watchdog reset a healthy stick

Question asked: "There seem to be a lot of MBIM errors, any idea where this
might be coming from?" The journal for the morning had ~80 lines of
`cdc_mbim ... Unexpected error -71` and `MBIM error: Transaction timed out`
between 09:36 and 09:47.

Answer: the first reset was spurious and came from the modem-watchdog, which
timed its "stick missing for N s" with the wall clock. The Pi had been powered
off overnight (cord pulled), booted at about 09:35 with the saved clock from
the previous shutdown (Sep 22 18:34), and NTP then jumped the clock 15 hours
forward. The watchdog concluded the Tesco stick had been missing for 54072 s
and reset it while ModemManager was still probing it. That reset wedged the
stick, a second reset followed, then the hub itself stalled, and the watchdog
reset all three sticks. Everything was connected again by 09:47. No
undervoltage this time (hwmon alarm clear, no kernel messages).

## Timeline (journalctl, current boot; times are the journal's wall clock)

| time | event |
| --- | --- |
| "Sep 22 18:34:55" | kernel boots; this is the saved clock, real time ~09:35 (uptime confirms) |
| 09:35:59 | `systemd-timesyncd`: "Initial clock synchronization", clock jumps +15 h |
| 09:36:14 | watchdog: `usbreset 1-1.2.3 ... no ModemManager modem for 54072 s` |
| 09:36:37 | modem3 (cdc-wdm1, Tesco) probes, enables and connects |
| 09:39:56–09:40:31 | cdc-wdm1 times out 10 consecutive times, "marking modem as invalid" |
| 09:41:37 | watchdog: second `usbreset 1-1.2.3 ... for 60 s` (cooldown 300 s elapsed) |
| 09:44:19–09:44:48 | `-71` on all three sticks (1-1.2.1, 1-1.2.2, 1-1.2.3); `usb 1-1.2: clear tt 4 (9062) error -71/-75` from the StarTech hub |
| 09:45:03–09:45:09 | MM: Transaction timed out on cdc-wdm0/1/2, "Couldn't peek MBIM port" |
| 09:46:00 / 09:46:20 / 09:46:41 | watchdog resets 1-1.2.2, 1-1.2.1, 1-1.2.3 |
| 09:47:02 | all three re-probed; modems 5/6/7 connected (Talkmobile, Tesco, EE) |

Yesterday's bursts (16:22 and 16:28, port 1-1.2.2 only) were the ordinary
single-stick hang the watchdog exists for; they are not related.

## Root cause

`/usr/local/sbin/modem-watchdog` computed `now=$(date +%s)`. On a Pi with no
RTC the clock at boot is whatever `systemd-timesyncd` saved at the last
shutdown; the first NTP sync then moves it by however long the box was off.
Every watchdog timer (`missing_since`, `last_reset`) is a difference of two
such readings, so a forward jump instantly exceeds GRACE. The stick it hit was
in the normal ~25 s post-enumeration window where ModemManager has not yet
exported a modem, which is exactly what GRACE is meant to protect.

Whether the 09:44 hub stall was caused by the two resets or was going to
happen anyway is not provable from the logs. The `clear tt` errors on the hub
device are the same signature as the 2026-09-16 hub-wide hang.

## Fix (merged as #17)

Time with `/proc/uptime` (monotonic, immune to clock changes) and check
`last_reset` with `[[ -v ]]` instead of defaulting it to 0, which would
otherwise block every reset for the first COOLDOWN seconds of uptime. Bash's
`$SECONDS` is not a substitute: it is derived from the wall clock and jumps
too.

## Notes

- The repo copy (`etc_files_pi/sbin-modem-watchdog`) is on origin/main
  (#15); the local `main` checkout was behind and did not have it.
- The installed copy on the Pi differs from the repo only by the long header
  comment (moved to `2026-09-17-modem-watchdog-design.md`).
- After merging, reinstall with `pi-install.sh` or copy the script to
  `/usr/local/sbin/modem-watchdog` and `systemctl restart modem-watchdog`.

---

# Later the same morning (09:53–10:10): train coverage, and 1-1.2.3 wedging repeatedly

Question asked at 10:07: "What's happening right now on the Pi? I see weird
ping logs in connectivity_logging." Two unrelated things were going on.

## A. The ping logs: all three carriers in poor coverage at once

`netlog` pings (`ping -I wwanN 8.8.8.8`, 1/s) for 09:53–10:08:

| path | replies | lost | p50 | p90 | max |
| --- | --- | --- | --- | --- | --- |
| wwan0 Talkmobile | 464 | 358 | 48 ms | 1.8 s | 20 s |
| wwan1 Tesco | 584 | 284 | 49 ms | 20.6 s | 70 s |
| wwan2 EE | 589 | 312 | 67 ms | 4.7 s | 20 s |

- A third of pings lost on every carrier, tails of tens of seconds, and
  minutes with more than 60 replies for a 1/s ping: the modem or cell buffers
  while the link is dead and flushes the queue in one burst (e.g. wwan1 at
  10:03: 103 replies, max RTT 70 s). The `drip` stream showed 14–32 stalls
  over 2 s per path and 11 on the MPTCP path.
- Talkmobile at 9 % signal flapped registered/connected ~20 times in one
  second at 10:05:55–10:05:58 (ModemManager `simple connect` retrying step 7,
  "wait to get packet service state attached").
- GPS: `fix 0, sats 0, trk 0, inview 12` throughout, the post-power-off
  cold-start starvation (see `connectivity_logging/gps-aiding-plan.md`), not a
  receiver fault.
- The tunnel stayed up throughout (sslocal active, ~200 established
  connections to the VPS on 10001).

Nothing to fix here; this is the environment. It is the reason the netlog
exists.

## B. The Tesco stick (1-1.2.3) wedged three more times

Watchdog resets of 1-1.2.3 this boot (5 in total, plus 3 of the other sticks
during the 09:46 hub stall):

| reset | trigger |
| --- | --- |
| 09:36:14 | spurious: wall-clock jump (part 1 of this note) |
| 09:41:37 | 10 MBIM timeouts after the spurious reset |
| 09:46:41 | hub-wide stall (`clear tt` on 1-1.2), all three sticks reset |
| 09:54:46 | `-71` alone on 1-1.2.3, 10 timeouts, "no ModemManager modem for 61 s" |
| 10:09:14 | `-71` at 10:07:09, invalid at 10:07:57, back and connected by 10:09:38 |

Each recovery took ~25 s from usbreset to `connected`; the other two carriers
carried the tunnel meanwhile. Yesterday (16:22, 16:28) it was 1-1.2.2 that
hung, so this is not one bad stick, but today 1-1.2.3 is the only one failing
on its own.

### New clue: the SuperSpeed side of the hub's port bounced

`usb usb2-port2: Cannot enable. Maybe the USB cable is bad?` ×14 between
09:53:10 and 09:55:29, with `attempt power cycle` at 09:53:22. Bus 2 is the
Pi 4's USB 3 root hub; `usb2-port2` is the SuperSpeed half of the physical
port whose USB 2 half is `1-1.2`, i.e. the port the StarTech modem hub is
plugged into (`lsusb -t`: `1-1` = VL805 internal hub, `1-1.2` = StarTech
14b0:045a, sticks on `1-1.2.1/2/3`, GPS on `1-1.2.4`). The StarTech is a
USB 2.0 hub, so the xhci should never see a SuperSpeed connect attempt on
that port; getting one, repeatedly, for two minutes, means the connector's
SS pins made and broke contact — the plug moved in the socket. The 09:54:46
reset of 1-1.2.3 falls inside that window. This message has never appeared
in any earlier boot's journal.

Hypothesis (unproven): the hub's plug/cable is loose or vibrating in the Pi's
USB 3 socket on the train, and the single-stick `-71` hangs on 1-1.2.3 today
(and possibly the 09:44 hub-wide `clear tt` stall) are mechanical. Test:
reseat the hub plug (or move it to the other USB 3 port / a USB 2 port, which
also removes the SS pins from the equation), then watch `journalctl -k` for
`usb2-port2` and `-71` over the next journeys. If the errors follow the
port rather than the cable, the socket is the problem.

### Checked and ruled out

- Undervoltage: `rpi_volt` alarm 0, no kernel voltage messages this boot.
- Watchdog misbehaviour after 09:36: every later reset followed a genuine
  `-71` + "marking modem as invalid" sequence with the intended 60 s grace.
