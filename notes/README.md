# Notes

Investigations, incidents and hardware quirks, one file per topic, named
`YYYY-MM-DD-short-slug.md`. See `AGENTS.md` for what belongs here versus in
`README.md`. Durable rules distilled from these live in the README; the notes
keep the evidence, the timelines and what remains open.

## connectivity-loss/ — modems dropping off: power, hub, USB, MBIM, watchdog

- [2026-09-12 Pi brownout reboots](connectivity-loss/2026-09-12-pi-brownout-reboots.md) — abrupt reboots were 5 V undervoltage; how to tell from the journal.
- [2026-09-14 hub branch collapse](connectivity-loss/2026-09-14-hub-branch-collapse.md) — unbranded 214b hub disabling its own ports, full-speed fallback, then dying.
- [2026-09-15 hub power supply](connectivity-loss/2026-09-15-hub-power-supply.md) — 12 V-fed TP-Link UH710 still browned out; replaced by a StarTech hub with 5 V aux input.
- [2026-09-16 hub-wide MBIM hang](connectivity-loss/2026-09-16-hub-wide-mbim-hang.md) — all sticks stop answering MBIM (`-71`); driver rebind gives a false "connected", `usbreset` works; birth of the watchdog.
- [2026-09-17 MBIM session wedged](connectivity-loss/2026-09-17-mbim-session-wedged.md) — session stuck `activating`, instant `Busy`, AT-only fallback modem; only a real re-enumeration or replug clears it.
- [2026-09-17 modem-watchdog design](connectivity-loss/2026-09-17-modem-watchdog-design.md) — why the watchdog detects by state and resets the way it does.
- [2026-09-22 modem flapping in weak signal](connectivity-loss/2026-09-22-modem-flapping-weak-signal.md) — bearer connects failing at −110 dBm and NM retrying five times a second; not a USB fault.
- [2026-09-23 watchdog clock jump](connectivity-loss/2026-09-23-watchdog-clock-jump.md) — wall-clock NTP jump made the watchdog reset a healthy stick; fixed with `/proc/uptime`. Also: SuperSpeed port bounce hints the hub plug is loose.

## mptcp/ — tunnel-level redundancy

- [2026-09-12 O2 strips MPTCP](mptcp/2026-09-12-o2-strips-mptcp.md) — pull test failed because Tesco held the bypass route and O2's proxy strips MPTCP; port moved to 10001.
- [2026-09-15 bypass route and blackhole timer](mptcp/2026-09-15-bypass-route-and-blackhole-timer.md) — connection setup single-homed on the bypass route; kernel blackhole detection had switched MPTCP off for an hour, now disabled.

## carrier-profiles/ — APNs, NetworkManager profiles, SIM matching

- [2026-09-12 Tesco attach APN](carrier-profiles/2026-09-12-tesco-attach-apn.md) — NV profile 1 held a leftover M2M APN; O2 needs the exact APN there.
- [2026-09-12 sim-operator-id race](carrier-profiles/2026-09-12-sim-operator-id-race.md) — NM auto-activates before reading the SIM, so `upstream-tesco` lands on whichever stick wins; bind by device-id.

## Other

- [2026-09-22 sslocal memory retention](2026-09-22-sslocal-memory-retention.md) — 500 MB RSS is glibc arena retention, not a leak; `malloc_trim` and allocator options.
