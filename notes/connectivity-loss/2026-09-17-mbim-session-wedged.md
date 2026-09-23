# 2026-09-17: one stick's MBIM session wedged after the watchdog's first real reset

Question asked: "What's the current status of the modems?" and then "try to
bring up the 3rd modem, and investigate". EE and Tesco were fine throughout;
the Talkmobile/Vodafone stick on port 1-1.2.2 (the stick later labelled "TalkMobile" in the sim-operator-id note) was registered
but would not connect, and no software reset fixed it. Stefan replugged it at
18:11 and it connected within a minute.

## 1. Timeline (journalctl, boot of 2026-09-17 10:31)

| time | event |
| --- | --- |
| 17:21:37 | kernel: `cdc_mbim 1-1.2.2:1.3: Unexpected error -71`. Only this stick this time; EE and Tesco kept answering. |
| 17:22:21 | ModemManager: `[modem1] port cdc-wdm2 timed out 10 consecutive times, marking modem as invalid`. |
| 17:23:36 | **modem-watchdog fires for real for the first time**: `usbreset 1-1.2.2 (001/008, 1bbb:00b6): no ModemManager modem for 60 s`. The reset failed config restore (`can't restore configuration #1 (error=-71)`), so the kernel did a full `USB disconnect` and re-enumerated it as device 11. That accident is what made this reset work. |
| 17:27:03-06 | NM tries `upstream-vodafone` four times; every one fails in 0 s with `MBIM status error: Busy`. NM stops retrying. |
| 17:27:48 | modem3 drops to `enabled` (registration idle), re-registers 17:28:56, then sits at `registered`. |
| 17:28:15 | Tesco (cdc-wdm0) drops with `modem-no-carrier`, reconnects by itself at 17:28:31. Unrelated. |
| 17:34:37 | `nmcli con up upstream-vodafone` by hand: three bearers (ipv4v6, ipv4, ipv6) each fail instantly with Busy. |
| 17:35 | `mbimcli -p --query-connection-state`: session 0 `Activation state: 'activating'`, packet service attached. `--disconnect=0`: `Busy`. `mmcli --disable/--enable`: still `activating`. |
| 17:35:58 | `usbreset 001/011`: `Resetting Mobilebroadband ... ok`, but the device kept number 11 (interfaces re-bound, no re-enumeration). ModemManager's MBIM probe of cdc-wdm2 ran 17:36:00-17:36:45 and gave up: `could not grab port cdc-wdm2: unhandled port type`; new modem4 `[Vodafone] IK41VE_USBC4G_V2_EMEA`, primary port ttyUSB5, `wwan2 (ignored)`, operator name garbage (`0054003000`), signal 100 %. `mbimcli -d /dev/cdc-wdm2 --noop`: `Failure`. |
| 17:38:49 | `echo 0 > authorized; echo 1 > authorized` on 1-1.2.2: interfaces re-bound, same device number, same AT-only modem5. |
| 17:42 | `mmcli -m 5 --reset`: `Unsupported`. `--command`: needs MM debug mode. |
| 17:46-17:49 | `AT` / `AT+CFUN=1,1` on ttyUSB4 and ttyUSB3 (raw and via python termios): no reply at all. |
| 17:52:53 | Mistake while checking usbreset's exit codes: `usbreset 001/010` hit the live EE stick (1-1.2.1). It re-probed and was back on `upstream-dummy-cdc-wdm1` with a new address at 17:53:17, 24 s later. wwan1 verified with an HTTP 204 afterwards. |
| 18:11:54 | Stefan replugs 1-1.2.2: device 13, MBIM probe succeeds, modem7 connected on `upstream-dummy-cdc-wdm2` (the sim-operator-id race, `../carrier-profiles/2026-09-12-sim-operator-id-race.md`). |

## 2. What was actually wrong

The MBIM function on the stick had a data session (session ID 0) stuck in
`activating` inside the firmware. The Busy answers were the modem refusing
every context operation while that session existed, not ModemManager or NM
stepping on each other. The README's documented Busy case (a 40 s connect
still in flight while a second one is issued) looks the same in the NM log but
different in `mbimcli`: there the bearer list is what is busy, here the
firmware is.

After the soft reset at 17:35 the MBIM function did not answer at all any
more (`Transaction timed out` on open), while the AT ports still enumerated
and responded to ModemManager's probe. That is the "AT-only fallback" state:
a modem that looks alive in `mmcli -L`, reports `registered`, and can never
carry traffic because its network interface is `(ignored)`.

## 3. What clears it and what does not

| tried | result |
| --- | --- |
| clear all 9 stale bearers, `--simple-disconnect`, autoconnect off on the port's profiles (README procedure) | session still `activating` |
| `mbimcli --disconnect=0` | `Busy` |
| `mmcli --disable` then `--enable` | session still `activating` |
| `usbreset` (soft: device number unchanged) | MBIM channel dead, AT-only modem |
| `authorized` 0 then 1 in sysfs | same |
| `mmcli --reset` | unsupported for the AT-only generic modem |
| `AT+CFUN=1,1` on ttyUSB3/ttyUSB4 | no response |
| watchdog's reset at 17:23 (hard: config restore failed, full re-enumeration) | worked, but by luck |
| physical replug | worked first time |

The difference between the two `usbreset`s is whether the kernel decided to
re-enumerate. `usbreset` issues `USBDEVFS_RESET`, which is a port reset
followed by a configuration restore; if the restore succeeds the device keeps
its number and its firmware state. A wedged MBIM function survives that. Only
a failed restore (or a replug) forces the disconnect/connect that reboots the
stick. There is no per-port power switching on the StarTech hub (`uhubctl`
not installed and the hub is unlikely to support it), so software cannot
force the replug.

## 4. Changes made

- `etc_files_pi/sbin-modem-watchdog`: a stick whose only ModemManager modem is
  AT-only (primary port not `cdc-wdmN`) now counts as missing, so it is reset
  after the usual 60 s grace and 5 min cooldown, with the reason in the kmsg
  line (`ModemManager has only an AT-only modem (MBIM port dead)`). After two
  consecutive resets without an MBIM modem it logs
  `<port> needs a physical replug: ...` once and keeps retrying every 5 min.
- `README.md`: watchdog paragraph updated, new "Wedged MBIM session" section.
- `../connectivity_logging` (`netlog.py`, `web/index.html`): the replug line is
  parsed as `needs-replug`, level 8 on the power/USB chart.

## 5. Lessons

- `usbreset BBB/DDD` numbers move on every re-enumeration. Read
  `/sys/bus/usb/devices/<port>/devnum` for the port you mean, and test failure
  paths with a number that does not exist (`001/999`).
- An `[Vodafone] IK41VE...` entry in `mmcli -L` with a `ttyUSB` primary port
  is the same physical stick as `[Alcatel] Mobilebroadband`; it is the sign
  that the MBIM probe failed, not a different device.
- The 10:22 `usbreset 1-1.2.3 failed (rc 0)` line in the journal came from the
  uncommitted first draft of the watchdog, which passed a `/dev/bus/usb/...`
  path; the committed script uses `BBB/DDD` and `usbreset` does exit 1 on
  `No such device found`. Not a bug on the branch.
