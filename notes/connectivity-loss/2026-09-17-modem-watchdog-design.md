# 2026-09-17: modem-watchdog design rationale

Why `etc_files_pi/sbin-modem-watchdog` does what it does. This was the script's
header comment; it lives here so the script stays short. Incidents that shaped
it: `2026-09-16-hub-wide-mbim-hang.md`, `2026-09-17-mbim-session-wedged.md`,
`2026-09-23-watchdog-clock-jump.md`.

Failure mode (see README "Hub-wide MBIM hang"): the kernel logs
`cdc_mbim 1-1.2.N:1.3: Unexpected error -71`, the stick stays enumerated with
all its interfaces and drivers bound, ModemManager times out ten times and
drops the modem, and nothing recovers it until the device is reset. A driver
rebind is not enough (control channel returns, data path stays dead); a USB
port reset (what usbreset does, and what a physical replug does) is.

Detection is by state, not by log line: an Alcatel USB device that has had no
MBIM-backed ModemManager modem for GRACE seconds. That also covers a stick
that failed enumeration at boot (`can't set config #1, error -71`) and one
whose MBIM function is wedged in firmware (README "Wedged MBIM session"): a
usbreset that does not force re-enumeration leaves cdc-wdmN dead, ModemManager
falls back to an AT-only modem on the ttyUSB ports ("[Vodafone] IK41VE..." with
wwanN ignored), and that stick can never carry traffic. Such a modem counts as
missing here. After REPLUG_AFTER consecutive resets without an MBIM modem the
watchdog says so once, because only a physical replug has cleared that state.

Each reset is written to /dev/kmsg so it appears in `journalctl -k` next to
the kernel's own USB events, and the connectivity logger plots it in its
power/USB chart (level 7 for a reset, level 8 for "needs a physical replug").
journald turns the "modem-watchdog:" prefix into the syslog identifier, so the
MESSAGE field starts at "usbreset ..." / "<port> needs ...".
