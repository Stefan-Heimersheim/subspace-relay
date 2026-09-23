# 2026-09-15: the 10:55 tunnel gap — bypass-route single-homing and the MPTCP blackhole timer

Investigation of a gap seen on the netlog page (`../connectivity_logging`) at
about 10:55 local: `wwan1` (Tesco) and `mptcp` both went dark while `wwan0`
(EE) and `wwan2` (Talkmobile) kept logging. Question asked: is MPTCP redundancy
not working, or is this a measurement failure of the TTFB and drip probes?

Answer: the gap is real, but it is a **connection-setup** failure, not a loss
of an established multipath connection. Two separate defects contributed, one
known and one new.

## 1. Evidence

Source: `connectivity_logging/log/2026-09-15.jsonl`, boot of 2026-09-15,
service started 10:44:46.

### HTTP probe outages (runs of >= 2 consecutive `ttfb: null`)

| path | windows |
| --- | --- |
| wwan0 EE | 10:47:53–10:50:11, 10:51:59–10:52:06 |
| wwan1 Tesco | 10:47:57–10:49:35, **10:54:25–10:55:35** |
| wwan2 Talkmobile | 10:44:57–10:45:18, 10:47:51–10:49:57, 10:53:09–10:53:59 |
| mptcp | 10:47:58–10:49:36, **10:54:20–10:55:38** |

`mptcp` matches `wwan1` to the second in both of its windows, and is unaffected
when `wwan0` (10:51:59) or `wwan2` (10:53:09) drop on their own. That asymmetry
is the whole finding: the tunnel is coupled to Tesco specifically, not to
"any path being down".

The 10:47:53–10:50:11 window hit all three modems at once and is a genuine
common outage (see GPS below), not a tunnel problem.

### The Tesco side was real radio

`modem` records for `wwan1`, 10:53:32–10:56:28: RSRP −101 → −112 → −83,
RSRQ ~−14, SNR ~0, state `connected` throughout, **cell `07FE0A7A` unchanged**
— a coverage dip, not a handover and not a detach. Ping on `wwan1` over the
same window ran at roughly 70 % loss (e.g. 2/12, 3/10, 4/14 per 10 s) while
`wwan0` and `wwan2` stayed at 10/10.

GPS puts the train stationary for it: speed 22 m/s at 10:53:16, 0.06 m/s from
10:54:20 to 10:55:08, back to 16 m/s at 10:55:40. Both this dip and the
10:47–10:50 all-carrier outage happened while stopped, i.e. they are
location-specific holes, not tunnels.

### The probes measure connection setup

- `ttfb` opens a **new** connection every 2 s.
- `drip` opens a **new** 60 s connection and reconnects when it ends.
- `ping` has no `mptcp` series at all by design: `sslocal` answers ICMP itself.

During the dip the `mptcp` drip that was *already running* finished normally
(`gap: null, rc: 0` at 10:54:23 — a clean 60 s completion), and the next one
got its first byte only at 10:55:37, logged as `gap: 61.666`. So existing
connections were not broken; new ones could not be made. The plot cannot show
that distinction, which is why the gap looks total.

## 2. Root cause A (known): the VPS bypass route is pinned to Tesco

```
$ ip route | grep <VPS_IP>
<VPS_IP> dev wwan1 metric 701
unreachable <VPS_IP> metric 9999
```

Every `sslocal` connection's **initial subflow** follows this route, so it must
go over Tesco. MPTCP protects connections that already exist; it cannot join
EE or Talkmobile onto a connection whose SYN never got through. With Tesco at
70 % loss, connection setup failed for 75 s even though two healthy paths were
sitting idle.

This is the mechanism README.md already describes under "Why this makes
redundancy fail instead of merely degrading" — there triggered by O2's
MPTCP-stripping proxy, here by an ordinary radio hole. The dispatcher
(`etc_files_pi/networkmanager-dispatcher-99-mptcp-wwan`,
`ensure_vps_bypass_route`) deliberately leaves the route on whichever modem
came up first, and nothing prefers a non-O2 carrier.

Note that the port move to 10001 did its job: Tesco passes MPTCP now
(`MPCapableSYNACKRX 272` against `MPCapableSYNTX 281`, `MPJoinSynAckRx 318`
for the boot). The remaining Tesco coupling is routing, not the proxy.

## 3. Root cause B (new): the kernel had switched MPTCP off entirely

While checking the above, the Pi was found in this state:

```
MPTcpExtMPCapableSYNTXDisabled  31 per 20 s     (MPCapableSYNTX delta: 0)
MPTcpExtBlackhole               1
net.mptcp.blackhole_timeout = 3600
```

Every new SYN was going out **without `MP_CAPABLE`**, on every path. Confirmed
by opening an `IPPROTO_MPTCP` socket bound to each modem address (the recipe in
README.md, "How to tell"):

| bound to | result before the fix |
| --- | --- |
| wwan0 EE | `MPCapableSYNTXDisabled 2` |
| wwan1 Tesco | `MPCapableSYNTXDisabled 1` |
| wwan2 Talkmobile | `MPCapableSYNTXDisabled 2` |

EE and Talkmobile pass MPTCP untouched, so this was not a carrier effect: it is
the kernel's own **active-fallback blackhole detection**
(`net/mptcp/ctrl.c`). When MP_CAPABLE handshakes fail, the kernel assumes a
stripping middlebox and stops offering MPTCP on new sockets for
`blackhole_timeout` seconds — one hour by default. On a mobile link a radio
hole is indistinguishable from such a middlebox, so a dip like 10:54 can cost
an hour of redundancy: every flow opened in that hour is plain single-path TCP
over whichever modem holds the bypass route (Tesco).

The subflows visible on `wwan0`/`wwan2` at the time were pre-blackhole
connections still alive; everything opened after the trip was single-path.

The counters are cumulative since boot, so the exact moment it tripped cannot
be recovered from them — but unanswered `MP_CAPABLE` SYNs during the 10:54 dip
are exactly what the detector looks for, and joins were still working earlier
in the boot.

## 4. Fix applied

`net.mptcp.blackhole_timeout = 0` disables the mechanism (the kernel returns
early from `mptcp_active_should_disable()` when the timeout is 0, so it also
lifts an already-active disable immediately).

Added to `etc_files_pi/sysctl-99-mptcp.conf` (so `pi-install.sh` installs it)
and applied live:

```bash
sudo install -m 644 etc_files_pi/sysctl-99-mptcp.conf /etc/sysctl.d/99-mptcp.conf
sudo sysctl -p /etc/sysctl.d/99-mptcp.conf
```

Verified immediately afterwards with the same per-modem probe:

| bound to | result after the fix |
| --- | --- |
| wwan0 EE | `MPCapableSYNTX 5, MPCapableSYNACKRX 5, MPJoinSynTx 8, MPJoinSynAckRx 6` |
| wwan1 Tesco | `MPCapableSYNTX 5, MPCapableSYNACKRX 5, MPJoinSynTx 8, MPJoinSynAckRx 6` |
| wwan2 Talkmobile | `MPCapableSYNTX 6, MPCapableSYNACKRX 5, MPJoinSynTx 6, MPJoinSynAckRx 6` |

`SYNTX == SYNACKRX` on all three and joins flowing again; `ss -tn '( dport =
:10001 )'` shows subflows on `wwan0` and `wwan2` alongside the `wwan1` initial
subflows. The VPS side was left alone — it only accepts connections, and the
blackhole timer applies to the active opener.

## 5. Not done yet

1. **Move the bypass route off Tesco** and make the dispatcher prefer a non-O2
   modem instead of whichever came up first
   (`ip route replace <VPS_IP> dev wwan0 ...` live; the preference belongs
   in `ensure_vps_bypass_route`). This does not remove setup-time
   single-homing, it only puts it on the better radio. Deliberately deferred:
   it disturbs new connections on a live tunnel.
2. **Real setup-time redundancy**, which MPTCP does not provide: either a short
   connect timeout plus retry in `sslocal`, or per-modem bypass routes with the
   initial connect raced across them, or a pool of pre-established connections
   so that flows do not depend on a SYN getting through during a dip.
3. **README.md** still says the O2 proxy is the reason the tunnel is coupled to
   Tesco. Since the 10001 move that is no longer the active cause; the routing
   pin is. Worth a correction there.

## 6. How to check this again

```bash
# is MPTCP being offered at all?
nstat -az | grep -E 'MPCapableSYNTX|MPCapableSYNACKRX|MPCapableFallbackSYNACK|SYNTXDisabled|Blackhole'
# which modem carries the initial subflow of every new connection?
ip route get <VPS_IP>
# are joins actually landing? (subflow local addresses should span the modems)
ss -tn state established '( dport = :10001 )'
```

`MPCapableSYNTXDisabled` growing while `MPCapableSYNTX` stays flat means the
blackhole timer is active — which, after this change, should no longer happen.

## 7. Related: the netlog plot itself

Same session, `../connectivity_logging/web/index.html`:

- The ms charts (`ping`, `http`, `drip`) had lost their y-axis ticks. uPlot
  picks an axis's default `filter` from the scale: `distr >= 3 && log == 10`
  gets the log-10 tick filter, which nulls every non-decade split. The custom
  ms scale uses `distr: 100` and inherits the default `log: 10`, so on a
  0–100 ms ping axis every tick was dropped. Fixed with an explicit
  `filter: (u, splits) => splits`.
- Tick density is now limited by pixel spacing (`msSplits`, >= 34 px apart)
  rather than by how many candidates fall in range.
