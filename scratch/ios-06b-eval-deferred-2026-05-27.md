# iOS 0.6B Speed catalog evaluation — deferred

**Date:** 2026-05-27  
**Plan todo:** optional-06b-eval (only if entitled 1.7B still fails)

## Decision

**Do not evaluate** adding 0.6B Speed packages to `qwenvoice_ios_model_catalog.json` yet.

## Preconditions not met

1. Apple `com.apple.developer.kernel.increased-memory-limit` not approved in provisioning.
2. Entitled device proof matrix (phase 3) not run — 2026-05-27 `xcodebuild` failed because CoreDevice reported iPhone 17 Pro **unavailable** to Xcode.
3. No entitled peak-RSS or admission-failure data for 1.7B Speed on hardware.

## When to reopen

After `entitlement-ready` verify and phase 3 on iPhone 17 Pro **still** shows:

- `model_admission_blocked` or Jetsam during load/generation with background apps closed, **or**
- Extension peak RSS consistently above entitled headroom with Speed 4-bit only.

Then follow [`docs/reference/ios-device-proof-matrix.md`](../docs/reference/ios-device-proof-matrix.md) phase 6.

## Expected tradeoff (if reopened)

- Lower peak RAM (~0.6B weights vs 1.7B).
- Quality/latency delta vs current Speed 1.7B — must be judged on device, not Simulator.
