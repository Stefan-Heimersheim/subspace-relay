# 2026-09-12: redundancy test failed — O2 strips MPTCP options

Pull test in the evening: unplugging the EE stick (`1-1.1.1.4`) did nothing;
unplugging the Tesco stick (`1-1.1.1.2`) killed every client connection.

## Cause

O2/Tesco's transparent TCP proxy strips MPTCP options on all but seven ports
(20, 53, 1723, 5060, 10000, 10001, 10002). Tesco happened to hold the VPS
bypass route after the 17:07 reboot, so every `sslocal` connection's initial
subflow went over Tesco and fell back to single-path TCP; the other modems
could never join. `nstat` at the time: 196 `MP_CAPABLE` SYNs sent, 0
`MP_CAPABLE` SYN-ACKs, 0 `MP_JOIN`s. EE and TalkMobile pass MPTCP cleanly in
both roles.

The full write-up, diagnostic recipe, port list and options are in README
"Carrier middleboxes and MPTCP".

## Outcome

- Shadowsocks moved to port 10001 (one of the exempt ports); with that Tesco
  passes MPTCP. Committed as "Move the Shadowsocks port to 10001".
- Decision: do **not** make the dispatcher prefer a non-O2 modem for the
  bypass route; a loud warning/error is wanted instead (not implemented).
- A UDP outer tunnel (WireGuard) for the O2 path was considered; running
  `ssserver` on an exempt port was the cheaper route and is what was done.
- Temporary test listeners on the VPS were removed again.

## Follow-up

The bypass route still single-homes connection setup on whichever modem holds
it, proxy or not: `2026-09-15-bypass-route-and-blackhole-timer.md`.
