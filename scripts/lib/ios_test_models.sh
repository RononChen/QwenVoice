# Shared model preflight for iOS on-device test/bench lanes.
#
# Weights live in the App Group on the paired iPhone — not on the Mac. Headless
# inventory uses QVOICE_IOS_MODELS_CHECK=1 → pullable models-status.json.
#
# Usage (from ios_device.sh):
#
#   . "$ROOT_DIR/scripts/lib/ios_test_models.sh"
#   ios_test_models_init "$ROOT_DIR"
#   ios_models_inventory_pull [--strict]
#
# Escape hatch:
#   QVOICE_SKIP_MODEL_INVENTORY=1  — advisory-only models check (no device launch)

# shellcheck shell=bash

IOS_TEST_REQUIRED_MODEL_IDS=(pro_custom pro_design pro_clone)

ios_test_models_init() {
  IOS_TEST_MODELS_ROOT_DIR="${1:?ios_test_models_init: root dir required}"
}

_ios_models_note() { printf '\033[0;36m==>\033[0m %s\n' "$*" >&2; }
_ios_models_warn() { printf '\033[0;33m[warn]\033[0m %s\n' "$*" >&2; }
_ios_models_die()  { printf '\033[0;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

ios_models_print_advisory() {
  _ios_models_note "iOS models live in the App Group on the paired iPhone — not on this Mac."
  _ios_models_note "Default ui-test / gate (Smoke + Sheet + ColdGeneration): install ALL Speed models once:"
  _ios_models_note "  pro_custom, pro_design, pro_clone — Vocello → Settings → Model Downloads (~6.9 GB)."
  _ios_models_note "bench-ui also needs all three; clone cells need a saved voice enrolled on the phone."
  _ios_models_note "OnDeviceDownload is opt-in (ui-test --download) — it uninstalls pro_custom in setUp."
  _ios_models_note "Run 'models check' (no --advisory) for headless inventory pull, or 'models check --strict' to gate."
  _ios_models_note "Interim probe: ios_device.sh bench \"custom:speed:Model probe.\" (locked phone OK, ~1–3 min)."
}

ios_models_print_status() {
  local json_path="$1"
  python3 - "$json_path" <<'PY'
import json, sys

path = sys.argv[1]
data = json.load(open(path))
if data.get("error"):
    print(f"  inventory error: {data['error']}")
models = data.get("models") or {}
print(f"  checkedAt: {data.get('checkedAt', '?')}")
print(f"  device: {data.get('deviceModel', '?')}")
print(f"  cloneVoicesEnrolled: {data.get('cloneVoicesEnrolled', 0)}")
print("  models:")
for mid in ("pro_custom", "pro_design", "pro_clone"):
    entry = models.get(mid) or {}
    status = entry.get("status", "missing")
    size = entry.get("sizeBytes", 0)
    size_gb = f"{size / 1_000_000_000:.2f} GB" if size else "—"
    mark = "✓" if status == "verified" else "✗"
    print(f"    {mark} {mid}: {status} ({size_gb})")
    missing = entry.get("missingPaths") or []
    for p in missing[:3]:
        print(f"        missing: {p}")
    if len(missing) > 3:
        print(f"        … +{len(missing) - 3} more")
PY
}

ios_models_strict_gate() {
  local json_path="$1"
  python3 - "$json_path" <<'PY'
import json, sys

required = ("pro_custom", "pro_design", "pro_clone")
data = json.load(open(sys.argv[1]))
if data.get("error"):
    print(f"models check --strict: inventory error — {data['error']}", file=sys.stderr)
    sys.exit(1)
models = data.get("models") or {}
failed = []
for mid in required:
    status = (models.get(mid) or {}).get("status", "missing")
    if status != "verified":
        failed.append(f"{mid} ({status})")
if failed:
    print("models check --strict: FAIL — missing or incomplete Speed tiers:", file=sys.stderr)
    for f in failed:
        print(f"  - {f}", file=sys.stderr)
    print("Install on phone: Vocello → Settings → Model Downloads", file=sys.stderr)
    sys.exit(1)
print("models check --strict: PASS (all Speed tiers verified)")
PY
}

# Launch app with QVOICE_IOS_MODELS_CHECK=1, pull diagnostics, print table.
# When strict=1, exit 1 if any required tier is not verified.
ios_models_inventory_pull() {
  local strict="${1:-0}"
  [[ -n "${IOS_TEST_MODELS_ROOT_DIR:-}" ]] || _ios_models_die "ios_test_models_init not called"

  if [[ "${QVOICE_SKIP_MODEL_INVENTORY:-}" == "1" ]]; then
    _ios_models_warn "QVOICE_SKIP_MODEL_INVENTORY=1 — skipping headless inventory"
    ios_models_print_advisory
    return 0
  fi

  ensure_mirror
  local dev
  dev="$(resolve_device)"
  if [[ ! -x "$APP_PATH/Vocello" ]] \
      || ! strings "$APP_PATH/Vocello" 2>/dev/null | rg -q "models-status.json"; then
    cmd_build
  fi
  cmd_install >/dev/null

  _ios_models_note "models inventory: headless pull (QVOICE_IOS_MODELS_CHECK=1; phone locked OK)"
  xcrun devicectl device process launch --device "$dev" --terminate-existing \
    -e '{"QVOICE_IOS_MODELS_CHECK":"1"}' "$BUNDLE_ID" >&2 || true
  sleep "${QVOICE_IOS_MODELS_INVENTORY_WAIT_SEC:-10}"

  local dest="$IOS_TEST_MODELS_ROOT_DIR/build/ios-diagnostics"
  rm -rf "$dest"
  cmd_pull "$dest" >/dev/null \
    || _ios_models_die "models inventory: pull failed (rebuild app with IOSModelsInventoryWriter?)"

  local json="$dest/models-status.json"
  [[ -f "$json" ]] || _ios_models_die "models inventory: no models-status.json (expected $json)"

  _ios_models_note "models inventory:"
  ios_models_print_status "$json"
  if (( strict )); then
    ios_models_strict_gate "$json"
  fi
}
