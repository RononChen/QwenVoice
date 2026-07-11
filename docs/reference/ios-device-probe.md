# iOS device and mirroring readiness probe

Implementation:
[`ios_device_state.sh`](../../scripts/lib/ios_device_state.sh),
[`ios_coredevice_probe.py`](../../scripts/lib/ios_coredevice_probe.py), and
[`ios_mirror_discovery.sh`](../../scripts/lib/ios_mirror_discovery.sh).

## Purpose

Fail fast before a Computer Use UI lane when CoreDevice cannot reach the paired physical iPhone or
Apple's iPhone Mirroring process is unavailable. Discovery uses the stable
`com.apple.ScreenContinuity` bundle identity plus known localized process names and reads no
user-scoped configuration.

## Verdicts

| Verdict | Exit | Meaning |
| --- | ---: | --- |
| `READY` | 0 | Physical device reachable and selected lane ready |
| `MIRROR_UNAVAILABLE` | 10 | Open iPhone Mirroring for Computer Use |
| `DEVICE_UNREACHABLE` | 14 | Connect, trust, and make the paired device available |

## Commands

```sh
scripts/ios_device.sh device-state
scripts/ios_device.sh device-state --json-v2 --lane computer-use
scripts/ios_device.sh device-state watch --interval 2 --count 3
python3 scripts/lib/ios_coredevice_probe.py probe --device "$QVOICE_IOS_DEVICE_ID"
```

The process probe establishes only that the mirror is running. The repository iOS skill separately
requires a current Computer Use screenshot containing live device content before it records
the live mirrored Vocello screen.

## Response

1. `MIRROR_UNAVAILABLE`: open iPhone Mirroring, establish the device session, rerun the skill
   bootstrap, and record capability.
2. `DEVICE_UNREACHABLE`: connect and trust the phone, enable Developer Mode, and retry.
3. `READY`: run `scripts/ios_agent_ui.sh doctor --suite <suite> --json`.

See [`ios-device-testing.md`](ios-device-testing.md).
