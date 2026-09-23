# 2026-09-22: modems flapping after a power-loss boot

Question asked: "What is going on with the device right now? Earlier even the
netlog page was really slow to load, and the devices seem to be switching
between various statuses", then "Why is sslocal growing?", then "some of the
modems still seemed to be weird / again. Can you document everything please?
Including the separate ss thing."

Short version: the Pi came back from a two-day power gap at 16:17. The
Talkmobile stick hung twice on USB and the watchdog reset it both times. Since
then all three sticks have been hopping cells with RSRP swinging between -72
and -115 dBm, which makes ModemManager's bearer connects fail and
NetworkManager loop. Separately, sslocal was found holding 510 MB of freed memory; that is written
up in `../2026-09-22-sslocal-memory-retention.md`.

## 1. Timeline (journalctl, boot of 2026-09-22 16:17)

The boot's journal starts with Sunday's date because the Pi has no RTC and the
clock was restored from the last saved time until NTP synced at 16:17:57.

| time | event |
| --- | --- |
| Sun 20 15:01 | Previous boot's journal stops mid-stream (no shutdown record). Power was gone from then until today. |
| 16:17 | Boot. All three Alcatel sticks enumerate; 1-1.2.1 (EE, cdc-wdm2), 1-1.2.2 (Talkmobile, cdc-wdm0), 1-1.2.3 (Tesco, cdc-wdm1). GPS on 1-1.2.4 alive but `sats 0, fix 0` for the whole boot. |
| 16:22:11 | kernel: `cdc_mbim 1-1.2.2:1.3: Unexpected error -71` (Talkmobile). NM marks cdc-wdm0 `unmanaged-link-not-` 45 s later. |
| 16:24:14 | modem-watchdog: `usbreset 1-1.2.2 (001/010, 1bbb:00b6): no ModemManager modem for 60 s`. Kept device number 10 (interfaces re-bound, no re-enumeration) but this time MBIM probed fine. |
| 16:24:38 | cdc-wdm0 back on `upstream-dummy-cdc-wdm0`. |
| 16:28:39 | Second `-71` on 1-1.2.2. |
| 16:30:38 | Second watchdog reset, same device number, again recovered. Because the modem came back each time the watchdog's per-port reset counter was cleared, so no "needs a physical replug" message is pending. |
| 16:30:39-16:32:05 | sslocal: 680 `TCP tunnel failure ... No route to host` while the host route to the VPS (pinned to wwan0) was gone and the `unreachable ... metric 9999` fallback route was live. |
| 16:32:18 | cdc-wdm0 `modem-no-carrier`, re-registers, connected again 16:32:36. |
| 16:33-16:40 | EE stick (cdc-wdm2, RSRP -109/-115) fails `modem-no-carrier` twice and is auto-reconnected. Cosmetic: it is on the never-default `dummy` profile. |
| 16:40 | State at the first look: Talkmobile and Tesco connected, both paths pinging the VPS at 43/49 ms with 0 % loss. MPTCP endpoints wwan0 + wwan1. |
| 16:55:07, 17:01:16 | Tesco (cdc-wdm1) drops `modem-no-carrier` twice, reconnects within seconds each time. Its RSRP had fallen from -80 to -114 dBm between 16:55 and 17:00. |
| 17:15-17:16 | EE: `registration in network failed: Network timeout` three times, `couldn't connect bearer: Failure` 19 times in total. |
| 17:20:35-17:21:14 | Tesco: `couldn't connect bearer: Unknown error` 10 times, then `Failure` 35 times. NM's `upstream-tesco` has `autoconnect-retries -1`, so it retries immediately: `prepare -> failed (reason 'unknown')` five times per second for ~3 s. ModemManager shows this as `registered -> connecting -> registered` several times a second. |
| 17:21:19 | Tesco modem drops to `enabled`, registration `idle`, signal 0 %. A 1 s network scan sees only `23420 3 UK (forbidden)`. |
| 17:22 | Tesco re-registers on yet another cell (07D25487) at -97 dBm, then -105 dBm. NM shows cdc-wdm1 `disconnected`. |
| 17:23 | At time of writing: Talkmobile and EE connected (both on `dummy` profiles), Tesco registered but not connected. MPTCP endpoints are now wwan0 + wwan2 (EE), so EE is carrying the second subflow. |

## 2. The modems: two different things

### 2a. Talkmobile USB hang, twice (16:22 and 16:28)

The familiar `-71` MBIM hang on port 1-1.2.2, see `2026-09-16-hub-wide-mbim-hang.md`
and `2026-09-17-mbim-session-wedged.md`. Only this stick, not the hub. Both
watchdog resets kept the device number, and unlike 2026-09-17 the MBIM function
came back both times. Nothing to do; the watchdog did its job.

It hurts more than a normal stick outage because the host route to the VPS is
pinned to wwan0 (`<VPS_IP> dev wwan0 metric 700`). With wwan0 dead, every
new tunnel connection's initial MPTCP subflow black-holes. The kernel counters
for this boot: 5091 `MPCapableSYNTX`, of which 1978 `MPCapableSYNTXDrop`
(SYN retransmitted twice with no reply, then sent again without the MPTCP
option). `MPCapableSYNTXDisabled` stayed 0, so blackhole detection did not turn
MPTCP off.

### 2b. Weak and constantly changing signal on all three sticks

This is what "switching between various statuses" is from 16:40 onwards. Cell
IDs from the netlog `modem` records (time, cell, RSRP at first sighting):

| stick | cells seen 16:18-17:22 |
| --- | --- |
| wwan0 Talkmobile | 00671218 (-104) → 00217F26 → 0037DD0E → 00352018 (-108) → 07C2460A → 07F41A14 (-84) |
| wwan1 Tesco | 085AC073 (-77) → 07C6EC7A (-81) → 07CA167D (-78) → 080C0487 → 07C2466E → 07D3A66E → 07B76378 (-81) → 07D25487 (-97) |
| wwan2 EE | 00920305 (-72) → 007E650C (-115) → 007F9A01 (-87) → 00510201 (-111) → 00510200 (-92) → 0000CA1A → 00002440 → 003C510D |

Eight to ten cells per stick in an hour, RSRP anywhere from -72 to -115 dBm,
SNR 0 to -5 dB on Tesco at 17:22. Either the box is moving or it is on the
fringe of several cells. GPS cannot say which: zero fixes and zero satellites
all boot (`clk -1.96`), the cold-start starvation from
`connectivity_logging/gps-aiding-plan.md`.

The failure mode at the bottom of the signal range is consistent across
sticks: ModemManager's simple-connect gets through registration and then the
bearer activation fails (`couldn't connect bearer: Failure` / `Unknown error`),
the modem falls back to `registered`, NM records `modem-no-carrier` or
`prepare -> failed (reason 'unknown')` and, with `autoconnect-retries -1`,
retries at once. None of it is a USB or firmware fault: no `-71`, no
`Busy`, no watchdog action after 16:30, `mmcli` still answers on all three.

The tight retry loop (five NM activations a second at 17:21) is the one thing
worth changing here. Something like `connection.autoconnect-retries 4` plus
NM's default 5 min back-off, or leaving the stick to ModemManager until its
signal is back above about -100 dBm, would stop the log spam and the
bearer churn. Not changed.

## 3. What was changed on the device

Nothing for the modems: no config, unit or route changes.

## 4. Open items

1. Rate-limit the NM autoconnect loop on the upstream profiles (section 2b).
2. GPS has had no fix all boot. If the box is stationary and indoors that is
   expected; if it is moving, the cold-start aiding plan is what fixes it.
3. The host route to the VPS on wwan0 only means a wwan0 hang takes every new
   tunnel connection with it even though wwan1/wwan2 are up. Same single-homing
   as `../mptcp/2026-09-15-bypass-route-and-blackhole-timer.md`; worth a look
   at whether the route can follow the healthiest stick rather than a fixed
   interface.
