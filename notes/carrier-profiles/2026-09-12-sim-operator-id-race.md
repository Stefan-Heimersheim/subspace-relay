# 2026-09-12: `upstream-tesco` landed on the TalkMobile stick (sim-operator-id race)

## Symptom

`upstream-tesco` was active on `cdc-wdm1`, the **TalkMobile** stick (SIM
23415). Vodafone accepts any APN, so it connected fine with
`prepay.tesco-mobile.com` (10.149.93.150, pings OK). The real Tesco stick
(`cdc-wdm0`, SIM 23410, registered home on TESCO LTE, 32 %) was left with
`upstream-dummy-cdc-wdm0` (`apn=dummy`), which O2 rejects, so ModemManager
logged `MBIM status error: Failure` every ~40 s. The stick's NV attach APN was
still correctly `prepay.tesco-mobile.com` (checked with
`qmicli --wds-get-profile-list=3gpp`); the SIM and the stick were fine.

## Root cause: `sim-operator-id` is not enforced at boot

NetworkManager 1.52.1 creates the modem devices and runs auto-activation the
instant ModemManager exports them, **before** it has read the SIM. In every
boot today it logged `policy: auto-activating connection 'upstream-tesco'` for
*all* `cdc-wdm` ports within the same millisecond (three ports in boot B, two
in C and E). The `sim-operator-id=23410` check only applies once NM has the
SIM's operator code (it does now: `busctl get-property … Device.Modem
OperatorCode` shows 23415 on cdc-wdm1 and 23410 on cdc-wdm0), which is after
the decision. A profile can only be active once, so whichever stick finishes
activation first keeps it; today TalkMobile won every time, this afternoon
Tesco won by luck.

The `MBIM status error: Busy` seen before the 18:23 reset was the README's
documented case: `nmcli connection up upstream-tesco ifname cdc-wdm1` was issued
while the previous 40 s connect attempt was still in flight.

## Fix applied live on the Pi (not in the repo)

```bash
sudo nmcli connection modify upstream-tesco gsm.device-id <device-id of the Tesco stick>
sudo nmcli device disconnect cdc-wdm0            # cancel the pending dummy attempt
sudo nmcli connection down upstream-tesco        # frees it from the TalkMobile stick
sudo nmcli --wait 90 connection up upstream-tesco ifname cdc-wdm0
```

`gsm.device-id` is NM's hash of the modem's equipment identifier (IMEI), known
at device creation, so there is no race. The Tesco stick is IMEI
<IMEI of the Tesco stick>. Since the attach APN lives in the stick's NV anyway, binding
the profile to the stick matches reality: moving the Tesco SIM to another stick
needs both profile 1 on that stick *and* the device-id updated. The
`sim-operator-id=23410` match was kept as a second guard. The change is
persisted in
`/etc/NetworkManager/system-connections/upstream-tesco.nmconnection`.

Result after the fix:

| Port | Stick / SIM | Profile | Address | Ping 1.1.1.1 |
| --- | --- | --- | --- | --- |
| `cdc-wdm0` / `wwan0` | Tesco 23410, IMEI redacted | `upstream-tesco` | 10.137.163.140/29 | OK, ~58 ms |
| `cdc-wdm1` / `wwan1` | TalkMobile 23415, IMEI redacted | `upstream-dummy-cdc-wdm1` | 10.149.68.64 | OK, ~40 ms |

Both are `ip mptcp endpoint` subflows (ids 1 and 2) with their own tables.

Useful identifiers:

| Stick | IMEI | NM device-id | Current USB path |
| --- | --- | --- | --- |
| Tesco SIM | <IMEI of the Tesco stick> | `<device-id of the Tesco stick>` | `1-1.1.2` |
| TalkMobile SIM | <IMEI of the TalkMobile stick> | `<device-id of the TalkMobile stick>` | `1-1.1.1.4` |

Read a stick's device-id with
`busctl get-property org.freedesktop.NetworkManager /org/freedesktop/NetworkManager/Devices/N org.freedesktop.NetworkManager.Device.Modem DeviceId`
(find `N` via `nmcli -f GENERAL.DBUS-PATH dev show cdc-wdmX`).


## Open items

- **Repo**: `etc_files_pi/upstream-tesco.nmconnection` still relies on
  `sim-operator-id` alone, so a reinstall (`pi-install.sh`) would reintroduce
  the race. Making the fix durable means a per-site device-id, i.e. templating
  it through `pi-install.sh`/`config.sh` (or a helper that maps SIM operator →
  stick and writes both NV profile 1 and the device-id). Not decided.
- **README**: the sentence in "Service ownership" saying `upstream-tesco` "is
  never tried on another carrier's SIM" is wrong at boot; it should say the SIM
  match only holds once NM has read the SIM, and that the profile is bound by
  device-id. The attach-APN table row for Tesco could note that the profile
  therefore follows the *stick*, not the SIM.
