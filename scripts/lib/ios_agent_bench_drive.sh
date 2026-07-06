#!/usr/bin/env bash
# Shared agent-driven iOS UI bench loop (mirroir, mobile-mcp, or deprecated vision driver).
# Sourced by scripts/ios_device.sh — do not execute directly.

# _ios_agent_bench_ui <driver> [flags...]
# driver: mirroir | mcp | vision
_ios_agent_bench_ui() {
  local driver="${1:?driver required (mirroir|mcp|vision)}"; shift
  require_team

  local modes="custom,design,clone" lengths="short,medium,long" warm=3 label="" profile=0 agent_drive=0
  local profile_template="${QVOICE_IOS_PROFILE_TEMPLATE:-Time Profiler}"
  local skip_doctor=0 skip_mcp_preflight=0 skip_mirroir_preflight=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --modes) modes="${2:-}"; shift 2 ;;
      --modes=*) modes="${1#*=}"; shift ;;
      --lengths) lengths="${2:-}"; shift 2 ;;
      --lengths=*) lengths="${1#*=}"; shift ;;
      --warm) warm="${2:-3}"; shift 2 ;;
      --warm=*) warm="${1#*=}"; shift ;;
      --label) label="${2:-}"; shift 2 ;;
      --label=*) label="${1#*=}"; shift ;;
      --profile) profile=1; shift ;;
      --profile-template) profile_template="${2:-Time Profiler}"; shift 2 ;;
      --profile-template=*) profile_template="${1#*=}"; shift ;;
      --agent-drive) agent_drive=1; shift ;;
      --skip-uitest-doctor) skip_doctor=1; shift ;;
      --skip-mcp-preflight) skip_mcp_preflight=1; shift ;;
      --skip-mirroir-preflight) skip_mirroir_preflight=1; shift ;;
      -h|--help|help)
        if [[ "$driver" == "mirroir" ]]; then
          cat <<'EOF'
bench-ui-mirroir — agent-driven UI benchmark (native mirroir OCR + tap/type_text)

  scripts/ios_device.sh bench-ui-mirroir --agent-drive [--modes …] [--lengths …]
      [--warm N] [--label NOTE] [--skip-mirroir-preflight]

Requires --agent-drive: agent uses mirroir describe_screen → tap/type_text per take,
then vision-bench-wait for telemetry proof. See docs/reference/ios-agent-ui-tour.md Appendix B.6d.

Pilot:
  scripts/ios_mirroir_preflight.sh --native-only
  scripts/ios_device.sh bench-ui-mirroir --agent-drive --warm 1 --lengths medium --modes custom --label mirroir-pilot
EOF
        elif [[ "$driver" == "mcp" ]]; then
          cat <<'EOF'
bench-ui-mcp — agent-driven UI benchmark (mobile-mcp + WDA accessibility tree)

  scripts/ios_device.sh bench-ui-mcp --agent-drive [--modes …] [--lengths …]
      [--warm N] [--label NOTE] [--skip-mcp-preflight]

Requires --agent-drive: agent uses mobile-mcp tools (mobile_list_elements_on_screen,
mobile_type_keys, element tap) then vision-bench-wait. See docs/reference/mobile-mcp-ios-evaluation.md.

Pilot:
  scripts/ios_mobile_mcp.sh preflight
  scripts/ios_device.sh bench-ui-mcp --agent-drive --warm 1 --lengths medium --modes custom --label mcp-pilot
EOF
        else
          cat <<'EOF'
bench-ui-vision — DEPRECATED: Peekaboo mirror-coordinate bench

  scripts/ios_device.sh bench-ui-vision --agent-drive …

Superseded by bench-ui-mirroir. See docs/reference/ios-agent-ui-tour.md Appendix B.6d.
EOF
        fi
        return 0
        ;;
      *) die "unknown bench-ui-$driver flag: $1 (try --help)" ;;
    esac
  done

  (( agent_drive == 1 )) || die "bench-ui-$driver requires --agent-drive"

  local lane_name="bench-ui-$driver"
  local run_prefix="ios-bench-ui-$driver"
  local take_begin="MIRROIR_BENCH_TAKE_BEGIN"
  case "$driver" in
    mcp) take_begin="MCP_BENCH_TAKE_BEGIN" ;;
    vision) take_begin="VISION_BENCH_TAKE_BEGIN" ;;
  esac

  note "$lane_name step 0: device-state watch"
  "$ROOT_DIR/scripts/ios_device.sh" device-state watch --interval 2 --count 3 \
    || die "device-state not ready for $lane_name"

  if [[ "$driver" == "mirroir" && "$skip_mirroir_preflight" -eq 0 ]]; then
    note "$lane_name step 0b: mirroir preflight (--native-only)"
    "$ROOT_DIR/scripts/ios_mirroir_preflight.sh" --native-only || die "mirroir preflight failed"
  fi

  if [[ "$driver" == "mcp" && "$skip_mcp_preflight" -eq 0 ]]; then
    note "$lane_name step 0b: mobile-mcp preflight"
    "$ROOT_DIR/scripts/ios_mobile_mcp.sh" preflight || die "mobile-mcp preflight failed"
    "$ROOT_DIR/scripts/ios_mobile_mcp.sh" lock || die "could not acquire mobile-mcp automation lock"
    trap "$ROOT_DIR/scripts/ios_mobile_mcp.sh unlock" EXIT
  fi

  if (( skip_doctor == 0 )); then
    note "$lane_name step 1: uitest doctor (Mac Gate 1 advisory)"
    "$ROOT_DIR/scripts/ios_uitest_doctor.sh" || true
  fi

  note "$lane_name step 2: models check --strict"
  cmd_models check --strict || die "models check --strict failed"

  ensure_device_ready
  ensure_mirror 60
  local dev; dev="$(resolve_device)"
  local run_id="${run_prefix}-$(date +%Y%m%d-%H%M%S)"
  local out_dir="$ROOT_DIR/build/ios/bench-ui-$driver-$run_id"
  mkdir -p "$out_dir"
  local manifest="$out_dir/manifest.json"
  local log="$out_dir/bench-ui-$driver.log"

  if [[ "$driver" == "vision" ]]; then
    note "$lane_name: calibrate vision bridge"
    "$ROOT_DIR/scripts/lib/ios_vision_bridge.sh" calibrate "$out_dir/vision-bridge.json" \
      || die "vision bridge calibrate failed — is iPhone Mirroring up?"
    export QVOICE_IOS_VISION_BRIDGE="$out_dir/vision-bridge.json"
  fi

  note "$lane_name: matrix modes=$modes lengths=$lengths warm=$warm runID=$run_id"
  cmd_build
  cmd_install

  local planned
  planned="$("$ROOT_DIR/scripts/lib/ios_vision_bench_matrix.sh" emit \
    --modes "$modes" --lengths "$lengths" --warm "$warm" \
    --run-id "$run_id" --out "$manifest")"

  local clone_enrolled=1
  if [[ -f "$ROOT_DIR/build/ios-diagnostics/models-status.json" ]]; then
    clone_enrolled="$(python3 -c 'import json; d=json.load(open("build/ios-diagnostics/models-status.json")); print(int(d.get("cloneVoicesEnrolled") or 0))' 2>/dev/null || echo 1)"
  fi

  local ran=0 skipped_clone=0
  local take_idx=0
  local warm_session_mode=""
  local mode_prep_done=""

  note "$lane_name: $planned planned takes — agent drive begins"
  {
    echo "runID=$run_id"
    echo "outDir=$out_dir"
    echo "driver=$driver"
    [[ "$driver" == "vision" ]] && echo "bridge=$QVOICE_IOS_VISION_BRIDGE"
    [[ "$driver" == "vision" ]] && echo "mirrorApp=$("$ROOT_DIR/scripts/lib/ios_vision_bridge.sh" mirror-app-name)"
  } | tee "$out_dir/session.env" >&2

  while IFS= read -r take_json; do
    [[ -n "$take_json" ]] || continue
    local mode length warm_state rep text force_cold timeout take_label
    mode="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["mode"])' "$take_json")"
    length="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["length"])' "$take_json")"
    warm_state="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["warmState"])' "$take_json")"
    rep="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["rep"])' "$take_json")"
    text="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["text"])' "$take_json")"
    force_cold="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("forceColdRelaunch", False))' "$take_json")"
    timeout="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1]).get("timeoutSec", 240))' "$take_json")"
    take_label="$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["label"])' "$take_json")"

    if [[ "$mode" == "clone" && "$clone_enrolled" -eq 0 ]]; then
      warn "skipping clone take $take_label — no saved voice on device"
      skipped_clone=1
      continue
    fi

    if [[ "$force_cold" == "True" || "$force_cold" == "true" || "$force_cold" == "1" ]]; then
      cmd_vision_launch --run-id "$run_id" --force-cold 1
      warm_session_mode=""
      mode_prep_done=""
    elif [[ "$warm_session_mode" != "$mode" ]]; then
      cmd_vision_launch --run-id "$run_id" --force-cold 0
      warm_session_mode="$mode"
      mode_prep_done=""
    fi

    local take_file="$out_dir/take-${take_idx}.json"
    printf '%s\n' "$take_json" >"$take_file"
    local done_file="$out_dir/take-${take_idx}.done"
    rm -f "$done_file"

    local needs_mode_prep=0
    if [[ "$mode_prep_done" != *"|${mode}|"* ]]; then
      needs_mode_prep=1
    fi

    note "── ${take_begin} $((take_idx + 1))/$planned: $take_label ──"
    if [[ "$driver" == "mirroir" ]]; then
      cat <<EOF | tee -a "$log" >&2
${take_begin}
$(cat "$take_file")
needsModePrep=$needs_mode_prep
doneFile=$done_file
Agent steps (mirroir native — docs/reference/ios-agent-ui-tour.md Appendix B.6d):
  1. describe_screen — confirm Studio tab + segment ($mode)
  2. Mode prep (if needsModePrep=1):
     custom: tap Custom @ y≈108
     design: tap Design @ y≈108; if + brief chip, tap first STARTING POINTS row or type bench brief + Confirm
     clone: tap Clone @ y≈108; tap + reference chip; pick first SAVED VOICES row
  3. Tap OCR "Clear script" (iosStudio_benchClearScript) — or vision-launch --run-id $run_id --force-cold 0 if missing
  4. Tap composer → type_text (script from take JSON above) → SCRIPT_VERIFY N>0
  5. SINCE=\$(scripts/ios_device.sh vision-now)  # BEFORE Generate
  6. Tap Generate @ OCR ~(173, 584)
  7. scripts/ios_device.sh vision-bench-wait --run-id $run_id --since "\$SINCE" --timeout $timeout
  8. touch $done_file
EOF
      if (( needs_mode_prep == 1 )); then
        mode_prep_done="${mode_prep_done}|${mode}|"
      fi
    elif [[ "$driver" == "mcp" ]]; then
      cat <<EOF | tee -a "$log" >&2
${take_begin}
$(cat "$take_file")
Agent steps (mobile-mcp):
  1. mobile_list_elements_on_screen — confirm Studio + mode ($mode)
  2. Prepare mode per docs/reference/ios-app-guide.md (tree ids, not mirror coords)
  3. Clear composer (iosStudio_benchClearScript or select-all)
  4. SINCE=\$(scripts/ios_device.sh vision-now)  # BEFORE Generate
  5. mobile_type_keys script + dismiss keyboard + tap Generate (textInput_generateButton)
  6. scripts/ios_device.sh vision-bench-wait --run-id $run_id --since "\$SINCE" --timeout $timeout
  7. touch $done_file
EOF
    else
      cat <<EOF | tee -a "$log" >&2
${take_begin}
$(cat "$take_file")
bridge: $QVOICE_IOS_VISION_BRIDGE
Agent steps (DEPRECATED vision — prefer bench-ui-mirroir):
  1. mirroir describe_screen — confirm Studio + mode ($mode)
  2. Prepare mode per docs/reference/ios-app-guide.md
  3. Clear composer
  4. SINCE=\$(scripts/ios_device.sh vision-now)
  5. Peekaboo click/type via vision bridge → Generate
  6. scripts/ios_device.sh vision-bench-wait --run-id $run_id --since "\$SINCE" --timeout $timeout
  7. touch $done_file
EOF
    fi

    local wait_sec=0
    local take_timeout=$((timeout + 600))
    while [[ ! -f "$done_file" ]]; do
      sleep 3
      wait_sec=$((wait_sec + 3))
      if (( wait_sec > take_timeout )); then
        die "take $take_label timed out waiting for $done_file (agent must complete steps)"
      fi
    done

    ran=$((ran + 1))
    take_idx=$((take_idx + 1))
    "$ROOT_DIR/scripts/ios_device.sh" shot "$out_dir/take-${take_idx}-evidence.png" >/dev/null 2>&1 || true
  done < <(python3 - "$manifest" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1]))
for take in manifest.get("takes") or []:
    print(json.dumps(take, separators=(",", ":")))
PY
)

  printf 'VOCELLO-BENCH-UI-MANIFEST ran=%s runID=%s skippedClone=%s driver=%s\n' \
    "$ran" "$run_id" "$([[ $skipped_clone -eq 1 ]] && echo true || echo false)" "$driver" \
    | tee -a "$log" >&2
  [[ "$ran" -gt 0 ]] || die "$lane_name: no takes completed"

  local dest="$ROOT_DIR/build/ios-diagnostics"
  rm -rf "$dest"
  cmd_pull "$dest" >/dev/null || die "could not pull diagnostics after $lane_name"
  local diag="$dest"
  local engine_jsonl
  engine_jsonl="$(find "$dest" -path '*/engine/generations.jsonl' 2>/dev/null | head -1)"
  [[ -n "$engine_jsonl" ]] && diag="$(dirname "$(dirname "$engine_jsonl")")"

  note "── telemetry summary ──"
  python3 "$ROOT_DIR/scripts/summarize_generation_telemetry.py" "$diag" \
    ${label:+--label "$label"} >&2 || warn "summarizer found no engine rows"

  note "── $lane_name gate ──"
  local gate_status=0
  python3 "$ROOT_DIR/scripts/check_ios_ui_bench.py" "$diag" \
    --run-id "$run_id" --expected "$ran" | tee "$out_dir/gate.log" || gate_status=1

  if (( gate_status != 0 )); then
    warn "$lane_name FAIL (gate=$gate_status) · $out_dir"
    return 1
  fi
  note "$lane_name PASS · $out_dir"
}
