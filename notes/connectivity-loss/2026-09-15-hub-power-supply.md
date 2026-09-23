# 2026-09-15: hub power supply — 12 V adaptor into the TP-Link hub, undervoltage anyway

Working note from the evening of 2026-09-15, 20:51 UK time: three more
undervoltage events despite the hub having 12.2 V input; the plan was to raise
it to 12.4 V. Possibly correlated with a `usb-enum-fail`, possibly just from
wiggling the PSU; it did disconnect the EE modem, so that stretch of the
netlog is an invalid period.

## Supply history

- At the time the modem hub was a TP-Link UH710 fed from a 20 V USB-PD cable
  through a variable 12 V adaptor.
- Since replaced by a StarTech 4-port hub (`14b0:045a`, sticks on `1-1.2.x`)
  with its own 5 V aux input. See `2026-09-16-hub-wide-mbim-hang.md` onwards
  for its behaviour.
- Earlier chain and the unbranded 214b hub: `2026-09-14-hub-branch-collapse.md`.

## Also noted

Idea for `connectivity_logging`: plot link quality as a function of track
percentage, ignoring samples when GPS accuracy is bad or a power event
happened in the previous minute or the next ten seconds.
