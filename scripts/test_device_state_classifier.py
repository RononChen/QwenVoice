#!/usr/bin/env python3
"""Unit tests for ios_coredevice_probe.py — offline JSON fixtures only."""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "lib"))

import ios_coredevice_probe as probe  # noqa: E402

FIXTURES = ROOT / "Tests" / "DeviceProbeFixtures"


class CoreDeviceProbeTests(unittest.TestCase):
    def test_connected_device(self) -> None:
        data = json.loads((FIXTURES / "devicectl-list-connected.json").read_text())
        dev = probe.pick_device(data, "00000000-0000-0000-0000-000000000001")
        self.assertIsNotNone(dev)
        summary = probe.summarize_device(dev)
        self.assertTrue(summary["availableForDevelopment"])
        self.assertEqual(summary["tunnelState"], "connected")

    def test_unavailable_device(self) -> None:
        data = json.loads((FIXTURES / "devicectl-list-unavailable.json").read_text())
        dev = probe.pick_device(data, "00000000-0000-0000-0000-000000000001")
        self.assertIsNotNone(dev)
        summary = probe.summarize_device(dev)
        self.assertFalse(summary["availableForDevelopment"])

    def test_lock_state_locked_fixture_shape(self) -> None:
        raw = json.loads((FIXTURES / "lockState-locked.json").read_text())
        lock = raw["result"]["lockState"]
        self.assertFalse(lock["unlockedSinceBoot"])
        self.assertTrue(lock["passcodeRequired"])

    def test_automation_blockers_xcuitest_locked(self) -> None:
        core = {
            "reachable": True,
            "lock": {"state": "known", "deviceLocked": True, "unlockedSinceBoot": False},
        }
        ready, blockers = probe.automation_blockers(
            verdict="MIRROR_ACTIVE", coredevice=core, lane="xcuitest"
        )
        self.assertFalse(ready)
        self.assertIn("device_locked", blockers)

    def test_automation_blockers_bench_ignores_lock(self) -> None:
        core = {
            "reachable": True,
            "lock": {"state": "known", "deviceLocked": True},
        }
        ready, blockers = probe.automation_blockers(
            verdict="MIRROR_ACTIVE", coredevice=core, lane="bench"
        )
        self.assertTrue(ready)
        self.assertNotIn("device_locked", blockers)

    def test_automation_probe_degraded(self) -> None:
        ready, blockers = probe.automation_blockers(
            verdict="PROBE_DEGRADED", coredevice={"reachable": True}, lane="bench"
        )
        self.assertFalse(ready)
        self.assertIn("probe_degraded", blockers)


if __name__ == "__main__":
    raise SystemExit(unittest.main())
