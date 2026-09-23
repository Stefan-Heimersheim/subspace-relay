# Guide for agents

## Context

`subspace-relay` turns a Raspberry Pi 4 with several LTE USB sticks (Alcatel
IK41, one UK carrier per SIM, on a USB hub) into a Wi-Fi/Ethernet router whose
uplink is one Multipath TCP connection: every packet goes over every modem at
once (a *redundant* MPTCP scheduler), tunnelled through Shadowsocks to a VPS
that merges the copies. It is used on trains, so the environment is hostile
by design: cell handovers, tunnels with no signal, a 5 V supply that browns
out, and the power cord being pulled at the end of every journey. Judge log
noise against that before treating it as a fault. Read `README.md` for what
the system does and how it is installed; the sections on modem NV profiles,
carrier middleboxes and Alcatel quirks are the accumulated hard-won knowledge.
The repo is two idempotent Bash installers (`pi-install.sh`, `vps-install.sh`,
sharing `lib.sh` and `config.sh`) plus the config trees they install
(`etc_files_pi/`, `etc_files_vps/`); there is no test suite.

Hardware, as of September 2026: the sticks and a u-blox GPS sit on a StarTech
4-port hub (`14b0:045a`) with its own 5 V aux input; before that a TP-Link
UH710 fed 12 V from a 20 V USB-PD cable through a variable adaptor, which still
browned out. Power and hub history is in `notes/connectivity-loss/`.

Related repos by the same maintainer:

- [linux-mptcp-redundant](https://github.com/Stefan-Heimersheim/linux-mptcp-redundant):
  the kernel with the redundant scheduler, pinned by version and SHA in
  `config.sh` and required on both ends.
- `connectivity_logging` (checked out next to this repo on the Pi): logs
  per-modem link quality, power events and GPS during rides and plots them.
  It reads this repo's kernel-log lines (e.g. `modem-watchdog:`), so keep those
  message formats stable.

## Development

- Branch from `main`, one PR per change. Stacked PRs are fine. The maintainer
  merges; agents do not.
- Never force-push. If a push is rejected, `git fetch` first: GitHub rewrites
  stacked branches after the PR below them merges.
- No git credential helper or `gh` login is set up on the Pi. `~/.env` may
  hold a `GH_TOKEN`; source it and pass it to `gh` or a one-off git
  credential helper for the push. Never commit it or copy it into git config.
- End every commit message with an attribution trailer matching the existing
  history, e.g. `Co-authored-by: Claude Fable 5.1 <noreply@anthropic.com>` or
  `Co-authored-by: Codex GPT-6 Astra <noreply@openai.com>`.
- Verification means running the change on the real Pi or VPS (`ssh net`
  reaches the VPS). The installers are meant to be re-run in place, so a
  change to them is tested by re-running them and checking the diff they
  report. Keep them idempotent.
- The Pi is usually carrying live traffic. Debug one modem at a time; never
  restart ModemManager or NetworkManager wholesale, and never run
  `mmcli --reset` on these sticks (see README "Alcatel modem quirks and
  recovery" for what works instead). Ask before anything that takes all
  uplinks down.
- When adding or removing a file under `etc_files_*`, update the
  "File inventory" in `README.md`. When bumping a pinned release in
  `config.sh`, update the matching `*_SHA256` values.

## Where to write things

- **`README.md` is for users.** Setup, architecture, how the pieces own which
  config, carrier behaviour, and recovery procedures that a future operator
  needs. Nothing else goes there; in particular no incident timelines, no
  dated status, and nothing about a particular SIM, journey or train line.
- **`notes/` is for everything else worth keeping**: investigations,
  incidents, hardware quirks, log excerpts, things that were tried and why
  they failed, per-journey observations. One file per topic named
  `YYYY-MM-DD-short-slug.md`; add a line to `notes/README.md`. Write it so
  that a reader can tell what was observed, what was concluded, and what
  remains open. When a note yields a durable rule, distil that rule into the
  README and link back to the note.
- **Code comments stay short.** One line on *why* when it is not obvious, no
  incident history and no debugging narrative in the scripts, units or
  NetworkManager profiles; that lives in `notes/`.
