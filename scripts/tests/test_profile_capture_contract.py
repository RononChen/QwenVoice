#!/usr/bin/env python3
from __future__ import annotations

from pathlib import Path
import unittest


REPO = Path(__file__).resolve().parents[2]


def shell_function(text: str, name: str) -> str:
    prefix = f"{name}() {{\n"
    start = text.index(prefix)
    end = text.index("\n}\n", start) + 3
    return text[start:end]


class ProfileCaptureContractTests(unittest.TestCase):
    def test_macos_profile_records_cpu_and_signposts_in_one_exact_launch_trace(self) -> None:
        profile = shell_function(
            (REPO / "scripts" / "macos_test.sh").read_text(encoding="utf-8"),
            "cmd_profile",
        )
        self.assertIn('local cpu_instrument="CPU Profiler"', profile)
        self.assertIn('--instrument "$cpu_instrument" --instrument os_signpost', profile)
        self.assertIn('--launch --', profile)
        self.assertIn('--no-prompt', profile)
        self.assertIn('"$ROOT_DIR/build/vocello" bench', profile)
        self.assertNotIn("sleep ", profile)

    def test_ios_profile_records_cpu_and_signposts_after_exact_pid_attach(self) -> None:
        profile = shell_function(
            (REPO / "scripts" / "ios_device.sh").read_text(encoding="utf-8"),
            "cmd_profile",
        )
        self.assertIn('local cpu_instrument="CPU Profiler"', profile)
        self.assertIn('--instrument "$cpu_instrument" --instrument os_signpost', profile)
        self.assertIn('--attach "$target_pid"', profile)
        self.assertIn('--no-prompt', profile)
        self.assertIn("grep -q '^Starting recording'", profile)
        self.assertIn("tracer_start_deadline=$((SECONDS + tracer_start_timeout))", profile)
        self.assertNotIn("--notify-tracing-started", profile)
        self.assertIn('device process resume --device "$dev" --pid "$target_pid"', profile)
        self.assertNotIn("sleep 5", profile)


class MacOSLanguageBenchContractTests(unittest.TestCase):
    def test_auto_language_hint_uses_nonempty_command_array(self) -> None:
        function = shell_function(
            (REPO / "scripts" / "macos_test.sh").read_text(encoding="utf-8"),
            "cmd_lang_bench",
        )
        self.assertIn("local -a generate_command=(", function)
        self.assertIn('--variant "$variant"', function)
        self.assertIn('generate_command+=(--language "$ui_hint")', function)
        self.assertIn('"${generate_command[@]}"', function)
        self.assertNotIn('"${lang_args[@]}"', function)
        self.assertNotIn("ensure_mac_test_models --require", function)
        self.assertIn("require_mac_benchmark_models", function)
        self.assertIn('--evidence-manifest "$artifacts/benchmark-evidence.json"', function)

    def test_gate_records_only_after_final_crash_step(self) -> None:
        mac = (REPO / "scripts" / "macos_test.sh").read_text(encoding="utf-8")
        mac_gate = shell_function(mac, "cmd_gate")
        self.assertLess(mac_gate.index("crashes (GATE-FATAL"), mac_gate.index("record_benchmark_history"))
        self.assertIn("overall == 0 && gate_bench", mac_gate)

        ios = (REPO / "scripts" / "ios_device.sh").read_text(encoding="utf-8")
        ios_gate = shell_function(ios, "cmd_gate")
        self.assertLess(
            ios_gate.index('cmd_crashes >"$gate_dir/crashes.log"'),
            ios_gate.index("record_benchmark_history"),
        )

    def test_profiles_use_read_only_models_and_frozen_evidence_summary(self) -> None:
        profile = shell_function(
            (REPO / "scripts" / "macos_test.sh").read_text(encoding="utf-8"),
            "cmd_profile",
        )
        self.assertNotIn("ensure_mac_test_models --require", profile)
        self.assertIn('require_profile_model "$mode" "$variant"', profile)
        self.assertIn("--defer-record", profile)
        self.assertIn('--evidence-manifest "$artifacts/benchmark-evidence.json"', profile)


if __name__ == "__main__":
    unittest.main()
