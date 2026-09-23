# 2026-09-12: Tesco SIM would not connect — the NV attach APN

The Tesco Mobile SIM registered and attached on LTE but every activation
failed with a bare `MBIM status error: Failure` after a 40 s timeout, from
NetworkManager and from `mmcli --simple-connect` alike. The MBIM trace showed
`nw error: none`: the network never answered the PDN activation request.

The durable conclusions (per-carrier APN tolerance, the NV profile 1 table,
the diagnostic recipe) are in README "Modem profile storage (NV) and the attach
APN"; this note keeps the session record.

## Root cause

The sticks' NV profile 1 (the LTE attach profile) held a leftover M2M APN,
`latitude.bsci.com`. EE and TalkMobile tolerate attaching with a foreign APN
and then activate any PDN; O2/Tesco silently ignores the PDN activation
request. Only the exact `prepay.tesco-mobile.com` works, on both the attach
profile and the connect request; `dummy` and `mobile.o2.co.uk` both fail
either way. No username or password is needed. Both `ipv4` and `ipv4v6`
connect.

## Changes made

Live on the Pi:

- Tesco stick NV profile 1 set to `prepay.tesco-mobile.com` / `IPV4V6` /
  `auth=NONE`, applied with `AT+CFUN=1,1`. Persists in the modem, travels with
  the stick, not the SIM.
- `upstream-tesco.nmconnection` installed; the three profiles whose
  autoconnect was disabled during debugging (`upstream-auto-cdc-wdm1`,
  `upstream-dummy-cdc-wdm1`, `upstream-vodafone`) restored to `autoconnect yes`.

In the repo (merged as #11): `etc_files_pi/upstream-tesco.nmconnection`
(SIM-matched, `sim-operator-id=23410`, priority 55), installed by
`pi-install.sh`; README corrected from "any non-empty APN works" to
per-carrier.

## State afterwards

| modem | USB path | port | SIM | NM profile | public IP seen |
| --- | --- | --- | --- | --- | --- |
| EE (23430) | `1-1.1.1.4` | `cdc-wdm0` / `wwan0` | redacted | `upstream-dummy-cdc-wdm0` | EE range |
| Tesco (23410) | `1-1.1.1.2` | `cdc-wdm1` / `wwan1` | redacted | `upstream-tesco` | O2 range |
| TalkMobile (23415) | `1-1.2` | `cdc-wdm2` / `wwan2` | — | `upstream-dummy-cdc-wdm2` | Vodafone range |

`ip mptcp endpoint show` listed all three as subflows, each with its own
`ip rule` and table (100/101/102). (Ports and paths moved later; see
`2026-09-12-sim-operator-id-race.md` and the connectivity-loss notes.)

## Open items

- The attach APN is per-stick, so moving the Tesco SIM to another modem needs
  profile 1 set on that modem too. Possible helper: read each SIM's operator
  id, set profile 1 from a mapping table, reboot the modem only on change. Not
  decided.
- Vodafone and TalkMobile share MCCMNC 23415, so a SIM-matched Vodafone profile
  is not possible; it stays an unbound priority-40 fallback. Vodafone's attach
  APN requirement is untested.
- TalkMobile's own MSISDN was not reported by the modem (`own:` absent).

## Lessons

- Debug one modem at a time; never restart ModemManager/NetworkManager
  wholesale while the others carry live traffic.
- `mmcli -m N --reset` wedges these sticks. `AT+CFUN=1,1` is the recovery, and
  a physical replug also works.
- `python3` + `pyserial` is available on the Pi for AT work.
