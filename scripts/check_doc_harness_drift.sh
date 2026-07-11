#!/usr/bin/env bash
# Fail when active tracked content re-introduces retired development environments or UI drivers.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() { printf '\033[0;31m[doc-drift]\033[0m %b\n' "$*" >&2; exit 1; }
command -v rg >/dev/null 2>&1 || fail "ripgrep is required"

echo "==> Codex workflow and harness drift check" >&2

PATHS=(AGENTS.md README.md .agents docs scripts config .github project.yml)
EXCLUDES=(
  --glob '!build/**'
  --glob '!website/**'
  --glob '!docs/releases/**'
  --glob '!docs/post-mortem/**'
  --glob '!scripts/check_doc_harness_drift.sh'
  --glob '!scripts/check_project_inputs.sh'
)

for retired in .cursor .mirroir-mcp; do
  [[ ! -e "$retired" ]] || fail "retired tracked tree still exists: $retired"
done

for retired in \
  scripts/install_mirroir_user_config.sh \
  scripts/ios_mirroir_preflight.sh \
  scripts/ios_mobile_mcp.sh \
  scripts/lib/ios_agent_bench_drive.sh \
  scripts/lib/ios_vision_bridge.sh \
  scripts/lib/ios_measure.sh \
  scripts/ios_uitest_doctor.sh \
  scripts/enable_unattended_uitest.sh \
  scripts/check_ios_ui_bench.py \
  scripts/lib/ios_vision_bench_matrix.sh \
  scripts/lib/ios_vision_bench_wait.sh \
  scripts/lib/xcresult_shots.sh \
  scripts/lib/ios_test_models.sh \
  scripts/generate_ui_test_surface.py \
  docs/reference/ui-test-surface.md \
  docs/reference/computer-use-mcp-alternatives-cursor.md \
  docs/reference/computer-use-mcp-pilot-log.md \
  docs/reference/mobile-mcp-ios-evaluation.md \
  docs/reference/on-device-ui-testing-research-report.md \
  docs/reference/ios-agent-ui-tour.md \
  docs/post-mortem/2026-06-post-fable-development-hell.md; do
  [[ ! -e "$retired" ]] || fail "retired artifact still exists: $retired"
done

forbidden='\bCursor\b|\.cursor|(?i:mirroir|peekaboo|mobile-mcp|install_mirroir_user_config|ios_mirroir_preflight|ios_mobile_mcp|ios_agent_bench_drive|ios_vision_bridge|ios_measure|ios_vision_bench_wait|bench-ui-mirroir|bench-ui-vision|bench-ui-mcp|vision-launch|vision-now|vision-bench-wait|measure-prep|measure-now|measure-wait|measure-verify|measure-artifacts-dir|computer-use-mcp-alternatives-cursor|computer-use-mcp-pilot-log|mobile-mcp-ios-evaluation|on-device-ui-testing-research-report|ios-agent-ui-tour|post-fable-development-hell|user-axiom|axiom_get_agent|axiom_xcsym_crash|axiom_xcprof_analyze|axiom_xclog_attach|record-capability|computer-use-capability|ui-test-surface|generate_ui_test_surface|ios_test_models|IOSModelsInventoryWriter|models-status\.json)'
out="$(rg -n "$forbidden" "${PATHS[@]}" "${EXCLUDES[@]}" 2>/dev/null || true)"
[[ -z "$out" ]] || fail "retired development content returned:\n$out"

# Computer Use is the only frontend driver on both platforms. Historical negative
# statements are allowed, but no runner target, hidden hook, or bridge implementation may return.
ui_runner='VocelloiOSUITests|IOSStudioBenchHooks|ios_uitest_doctor|enable_unattended_uitest|check_ios_ui_bench|ios_vision_bench_matrix|xcresult_shots'
out="$(rg -n -i "$ui_runner" "${PATHS[@]}" "${EXCLUDES[@]}" 2>/dev/null || true)"
if [[ -n "$out" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "$line" | rg -qi 'removed|retired|prohibit|must not|do not|there is no|no macOS XCUITest|intentionally absent|must not be revived' && continue
    fail "retired UI runner content returned:\n$line"
  done <<< "$out"
fi

# Simulator mentions may explain the physical-device prohibition or CI's generic compile-only
# destination. They may not describe an active app launch or UI-test destination.
out="$(rg -n -i 'platform=iOS Simulator|build_run_sim|test_sim|launch_sim' "${PATHS[@]}" "${EXCLUDES[@]}" 2>/dev/null || true)"
if [[ -n "$out" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "$line" | rg -qi 'never|unsupported|not use|cannot|compile-only|no XCUITest|do not|prohibit' && continue
    fail "active Simulator destination returned:\n$line"
  done <<< "$out"
fi

MAC_ACTIVE=(
  AGENTS.md README.md .agents/backend-mlx.md .agents/macos-engineer.md
  .agents/release-qa-engineer.md docs/ARCHITECTURE.md docs/project-map.html
  docs/development-progress.md docs/reference/macos-app-guide.md
  docs/reference/macos-testing.md docs/reference/macos-release-qa.md
  docs/reference/macos-permissions.md docs/reference/testing-runbook.md
  docs/reference/telemetry-and-benchmarking.md docs/reference/benchmarking-procedure.md
)
out="$(rg -n -i 'VocelloMacUITests|macos_uitest_doctor|scripts/uitest_measure\.sh|macos_test\.sh journey|macos_test\.sh uitest-doctor|MacUITestSurfaceMarkers' "${MAC_ACTIVE[@]}" 2>/dev/null || true)"
if [[ -n "$out" ]]; then
  while IFS= read -r line; do
    echo "$line" | rg -qi 'removed|retired|prohibit|must not|do not|there is no|no macOS XCUITest' && continue
    fail "retired macOS frontend driver returned:\n$line"
  done <<< "$out"
fi

# Ordinary push/PR CI is deterministic-only. Parse only executable `run:` values so comments and
# step names may explain the policy without becoming false positives. Advisory `impact` reports are
# allowed; strict impact enforcement, release evidence, model-readiness, and Computer Use bootstrap
# belong to explicit frontend/release acceptance.
policy_error=""
if ! policy_error="$(python3 - <<'PY'
from pathlib import Path
import re


def abort(message: str) -> None:
    print(message)
    raise SystemExit(1)


def workflow_run_blocks(path: Path) -> list[tuple[int, str]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    blocks: list[tuple[int, str]] = []
    index = 0
    while index < len(lines):
        match = re.match(r"^(\s*)run:\s*(.*)$", lines[index])
        if not match:
            index += 1
            continue

        line_number = index + 1
        base_indent = len(match.group(1))
        value = match.group(2).strip()
        if value not in {"|", "|-", "|+", ">", ">-", ">+"}:
            blocks.append((line_number, value))
            index += 1
            continue

        body: list[str] = []
        index += 1
        while index < len(lines):
            line = lines[index]
            if line.strip() and len(line) - len(line.lstrip()) <= base_indent:
                break
            if not line.lstrip().startswith("#"):
                body.append(line)
            index += 1
        blocks.append((line_number, "\n".join(body)))
    return blocks


ci_path = Path(".github/workflows/ci.yml")
if not ci_path.is_file():
    abort("ordinary CI workflow is missing: .github/workflows/ci.yml")

for line_number, block in workflow_run_blocks(ci_path):
    command = re.sub(r"\\\n\s*", " ", block)
    command = re.sub(r"\s+", " ", command).strip()
    for match in re.finditer(
        r"\b(?:macos|ios)_agent_ui\.(?:sh|py)[\"']?\s+([A-Za-z0-9_-]+)",
        command,
    ):
        if match.group(1) != "impact":
            abort(
                f"ordinary CI invokes frontend harness command {match.group(1)!r} at "
                f"{ci_path}:{line_number}; only advisory impact reporting is allowed"
            )
    forbidden = (
        (r"\b(?:macos|ios)_agent_ui\.(?:sh|py)\b.*\bimpact\s+--check\b", "strict impact --check"),
        (r"\b(?:macos|ios)_agent_ui\.(?:sh|py)\b.*\brelease-check\b", "release-check"),
        (r"\b(?:macos|ios)_agent_ui\.(?:sh|py)\b.*\bmodel-readiness(?:-check)?\b", "model-readiness"),
        (r"\bcomputer-use-client\.mjs\b", "Computer Use client bootstrap"),
        (r"\bsky\.list_apps\s*\(", "Computer Use sky.list_apps bootstrap"),
        (r"\bSKY_CUA_SERVICE_PATH\b", "Computer Use service bootstrap"),
        (r"\bSkyComputerUse(?:Service|Client)\b", "Computer Use helper bootstrap"),
        (
            r"\bmacos_test\.sh\b\s+(?:gate|release-readiness|telemetry-overhead|ui-report|review)\b",
            "indirect macOS frontend/release gate",
        ),
        (
            r"\bios_device\.sh\b\s+(?:gate|test|ui-test|bench-ui|review)\b",
            "indirect iOS frontend/device gate",
        ),
    )
    for pattern, label in forbidden:
        if re.search(pattern, command):
            abort(
                f"ordinary CI invokes {label} at {ci_path}:{line_number}; "
                "push/PR CI must remain deterministic-only"
            )


release_script = Path("scripts/release.sh")
release_lines = release_script.read_text(encoding="utf-8").splitlines()
readiness_lines = [
    number
    for number, line in enumerate(release_lines, start=1)
    if not line.lstrip().startswith("#")
    and re.search(r"macos_test\.sh[\"']?\s+release-readiness(?:\s|$)", line)
]
if not readiness_lines:
    abort("scripts/release.sh must invoke macos_test.sh release-readiness")

# Release readiness must execute before the script can build, sign, notarize, or package an
# artifact. This is intentionally textual: the release script keeps the unconditional gate at top
# level, before any of these operations or their helper definitions.
release_boundary_lines = [
    number
    for number, line in enumerate(release_lines, start=1)
    if not line.lstrip().startswith("#")
    and re.search(
        r"^\s*(?:xcodebuild\b|codesign\b|run_codesign\b|xcrun\s+notarytool\b|hdiutil\b|local\s+args=\(codesign\b)",
        line,
    )
]
if release_boundary_lines and min(readiness_lines) >= min(release_boundary_lines):
    abort(
        "scripts/release.sh must run macOS release-readiness before build/sign/notarization/package operations"
    )


release_workflow = Path(".github/workflows/release.yml")
workflow_lines = release_workflow.read_text(encoding="utf-8").splitlines()
job_start = next(
    (index for index, line in enumerate(workflow_lines) if re.match(r"^  archive-ios:\s*$", line)),
    None,
)
if job_start is None:
    abort("release workflow is missing the archive-ios job")

job_end = len(workflow_lines)
for index in range(job_start + 1, len(workflow_lines)):
    if re.match(r"^  [A-Za-z0-9_-]+:\s*$", workflow_lines[index]):
        job_end = index
        break

job_blocks = [
    (line_number, block)
    for line_number, block in workflow_run_blocks(release_workflow)
    if job_start + 1 <= line_number <= job_end
]
ios_gate_lines = []
for line_number, block in job_blocks:
    command = re.sub(r"\\\n\s*", " ", block)
    if re.search(r"\bios_agent_ui\.sh\b\s+release-check(?:\s|$)", command):
        ios_gate_lines.append(line_number)
if not ios_gate_lines:
    abort("archive-ios must invoke scripts/ios_agent_ui.sh release-check")

archive_boundaries = [
    index + 1
    for index in range(job_start, job_end)
    if (
        re.search(r"- name:\s*Import signing assets\b", workflow_lines[index])
        or (
            not workflow_lines[index].lstrip().startswith("#")
            and re.search(r"\b(?:security\s+import|codesign|xcodebuild\s+(?:archive|-exportArchive))\b", workflow_lines[index])
        )
    )
]
if not archive_boundaries:
    abort("archive-ios has no recognized signing/import/archive boundary")
if min(ios_gate_lines) >= min(archive_boundaries):
    abort("archive-ios release-check must run before signing asset import and archive/export")
PY
)"; then
  fail "development/release gate policy drift:\n$policy_error"
fi

# Strict commands remain available for explicit frontend and release acceptance even though
# ordinary CI cannot call them.
rg -q 'macos_agent_ui\.sh" impact --check' scripts/macos_test.sh \
  || fail "macOS explicit frontend gate no longer enforces impact --check"
rg -q 'ios_agent_ui\.sh" impact --check' scripts/ios_device.sh \
  || fail "iOS explicit frontend gate no longer enforces impact --check"
for harness in scripts/lib/macos_agent_ui.py scripts/lib/ios_agent_ui.py; do
  rg -q 'add_parser\("release-check"\)' "$harness" \
    || fail "$harness no longer exposes strict release-check"
  rg -q 'add_argument\("--check"' "$harness" \
    || fail "$harness no longer exposes strict impact --check"
done

echo "==> Codex workflow and harness drift check passed" >&2
