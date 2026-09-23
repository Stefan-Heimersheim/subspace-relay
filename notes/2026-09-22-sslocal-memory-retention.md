# 2026-09-22: sslocal sitting on 500 MB after an outage (glibc arena retention)

Found while investigating the same afternoon's modem trouble
(`connectivity-loss/2026-09-22-modem-flapping-weak-signal.md`): the netlog page
felt slow and `sslocal` was at 518 MB RSS on a 1.8 GB Pi.

## 1. Not a leak

Observed at 16:40: `sslocal` (shadowsocks-rust 1.24.0, TUN mode, static glibc
malloc, no jemalloc) at 518 MB RSS, VmHWM the same, ~400 established sockets
to the VPS plus 94 in FIN-WAIT-1. The Pi had 47 MB free and `kcompactd` was
taking a quarter of a core. Over the next minute RSS stayed at exactly
510 268 kB while the connection count moved between 223 and 255.

Where the memory was (`/proc/<pid>/smaps`):

* `[heap]` 356 kB.
* 58 anonymous mappings totalling 490 MB, the top eight each 65 496 kB with
  48-65 MB resident. Those are glibc's per-thread malloc arenas (64 MB heaps
  minus a guard page). sslocal runs 7 threads (`sslocal`, 4
  `tokio-runtime-w`, `smoltcp-poll`, `notify-rs inoti`), so it gets up to 8
  arenas.

Test: attach gdb for a moment and ask glibc to give freed memory back.

```
sudo gdb -q -batch -p $(pidof sslocal) -ex 'call (int)malloc_trim(0)'
```

Result: RSS 510 272 kB → 93 660 kB, established sockets 251 → 247 (noise),
tunnel unaffected (`ping -I tun0 1.1.1.1` fine straight after). Freed memory
that trims away on request is allocator retention, not a leak. glibc only
returns memory from the top of an arena on its own; free chunks in the middle
stay resident until something calls `malloc_trim`, which nothing in sslocal
does.

What fills the arenas: the 16:30-16:32 outage stalled a few hundred downstream
connections at once (211 distinct `10.255.0.1:<port>` sources in the failure
log, ~400 established plus ~90 half-closed upstream sockets at the peak). Each
one holds smoltcp TCP buffers on the tun side, relay buffers and an upstream
socket. But by 17:21 RSS was back up to 330 MB with only 8 tunnel errors in
between and ~275 established connections, so ordinary browsing traffic from
one laptop refills the arenas too. The surge just gets there faster.

Why it matters on a 1.8 GB Pi: a few hundred MB of dead weight leaves under
100 MB free, memory compaction runs constantly, and everything that allocates
gets slower. That, plus the USB hangs stalling anything that touched
1-1.2.2, is the most likely reason the netlog page felt slow. Measured at
16:41 the page's `/data` endpoint answers in 33 ms for a 5 min window and
64 ms for the whole day (3.5 MB), so the page itself is fine.

Unrelated but noticed: on 2026-09-20 sslocal died twice with
`thread 'smoltcp-poll' panicked at smoltcp-0.12.0/src/wire/tcp.rs:81:13:
attempt to subtract sequence numbers with underflow` (SIGABRT, restarted by
systemd within 5 s). Upstream smoltcp bug; keep an eye on it.

Candidate fixes, none applied:

* `Environment=MALLOC_ARENA_MAX=2 MALLOC_TRIM_THRESHOLD_=1048576` in
  `shadowsocks-client.service`: two arenas instead of eight, and glibc trims
  once 1 MB is free at the top. Cheapest, one `daemon-reload` + restart.
* A jemalloc build of shadowsocks-rust (its `jemalloc` cargo feature), which
  purges freed pages on a timer.
* `MemoryHigh=` on the unit as a backstop so the kernel reclaims from sslocal
  before the rest of the box starves.
* One-off relief without a restart: the gdb `malloc_trim` line above.

## 2. What was changed on the device

Only the `malloc_trim` call on the running sslocal at 16:47. No config or unit
changes.

## 3. Open

Decide on the allocator setting (candidate fixes above). Nothing applied yet.
