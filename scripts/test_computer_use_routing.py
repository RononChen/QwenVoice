import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).parent / "lib" / "computer_use_routing.py"
SPEC = importlib.util.spec_from_file_location("computer_use_routing", MODULE_PATH)
ROUTING = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(ROUTING)


class ComputerUseRoutingTests(unittest.TestCase):
    def fixture(
        self,
        *,
        identity_match=True,
        top_level_enabled=False,
        node_repl_declared=True,
        node_repl_enabled=None,
        bundled_content_variant="node-repl",
        stale_command=False,
        stale_notify=False,
        desktop_version="26.707.41301",
        plugin_override=False,
        plugin_installed=True,
        plugin_enabled=True,
        skill_present=True,
        wrapper_present=True,
        known_bad_helper=False,
        copied_plugin_source=False,
        inventory_cache_path_mismatch=False,
        wrong_node_repl_command=False,
        unrelated_global_service_path=False,
    ):
        temporary = tempfile.TemporaryDirectory()
        root = Path(temporary.name)
        home = root / ".codex"
        desktop = root / "Applications" / "ChatGPT.app"
        desktop_info = desktop / "Contents" / "Info.plist"
        desktop_info.parent.mkdir(parents=True)
        with desktop_info.open("wb") as handle:
            plistlib.dump({
                "CFBundleIdentifier": "com.openai.codex",
                "CFBundleShortVersionString": desktop_version,
                "CFBundleVersion": "5103",
            }, handle)

        installed_plugin_root = home / "plugins" / "cache" / "openai-bundled" / "computer-use" / "1.2.3"
        plugin_root = (
            home / "copied-computer-use" / "1.2.3"
            if copied_plugin_source
            else installed_plugin_root
        )
        source = plugin_root / "Codex Computer Use.app"
        runtime = home / "computer-use" / "Codex Computer Use.app"
        app_source = desktop / ROUTING.APP_BUNDLED_RELATIVE_APP
        source_executable = source / ROUTING.SERVICE_RELATIVE_EXECUTABLE
        runtime_executable = runtime / ROUTING.SERVICE_RELATIVE_EXECUTABLE
        app_source_executable = app_source / ROUTING.SERVICE_RELATIVE_EXECUTABLE
        for executable in (source_executable, runtime_executable, app_source_executable):
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b"same-helper")

        transport = {
            "command": "./Codex Computer Use.app/Contents/SharedSupport/SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient",
            "args": ["mcp"],
            "cwd": ".",
        }
        (plugin_root / ".codex-plugin").mkdir()
        (plugin_root / ".mcp.json").write_text(json.dumps({"mcpServers": {"computer-use": transport}}))
        metadata = {"version": "1.2.3"}
        if bundled_content_variant is not None:
            metadata["bundledContentVariant"] = bundled_content_variant
        (plugin_root / ".codex-plugin" / "plugin.json").write_text(json.dumps(metadata))
        skill = plugin_root / ROUTING.PLUGIN_SKILL_RELATIVE_PATH
        wrapper = plugin_root / ROUTING.PLUGIN_WRAPPER_RELATIVE_PATH
        if skill_present:
            skill.parent.mkdir(parents=True)
            skill.write_text("---\nname: computer-use\n---\n")
        if wrapper_present:
            wrapper.parent.mkdir(parents=True)
            wrapper.write_text("export function setupComputerUseRuntime() {}\n")

        command = "/tmp/stale/SkyComputerUseClient" if stale_command else transport["command"]
        notify_path = "/tmp/stale/SkyComputerUseClient" if stale_notify else str(runtime / ROUTING.CLIENT_RELATIVE_EXECUTABLE)
        config = home / "config.toml"
        config.parent.mkdir(parents=True, exist_ok=True)
        node_repl_section = ""
        if node_repl_declared:
            node_repl_command = (
                root / "wrong" / "node_repl"
                if wrong_node_repl_command
                else desktop / ROUTING.DESKTOP_NODE_REPL_RELATIVE_EXECUTABLE
            )
            node_repl_section = (
                "[mcp_servers.node_repl]\n"
                + f'command = "{node_repl_command}"\n'
                'args = ["--transport", "stdio"]\n'
                + (
                    f'enabled = {str(node_repl_enabled).lower()}\n'
                    if node_repl_enabled is not None
                    else ""
                )
                + "\n"
            )
        config.write_text(
            (
                f'SKY_CUA_SERVICE_PATH = "{root / "unrelated" / "Codex Computer Use.app"}"\n'
                if unrelated_global_service_path
                else ""
            )
            + f'notify = ["{notify_path}", "turn-ended"]\n\n'
            + '[plugins."computer-use@openai-bundled"]\nenabled = true\n\n'
            + node_repl_section
            + "[mcp_servers.node_repl.env]\n"
            + f'SKY_CUA_SERVICE_PATH = "{source}"\n\n'
            + '[mcp_servers."computer-use"]\n'
            + f'command = "{command}"\n'
            + 'args = ["mcp"]\n'
            + 'cwd = "."\n'
            + f'enabled = {str(top_level_enabled).lower()}\n'
            + ('\n[plugins."computer-use@openai-bundled".mcp_servers.computer-use]\nenabled = true\n' if plugin_override else "")
        )

        build = ROUTING.KNOWN_BAD_AX_BOUNDS_BUILD if known_bad_helper else "1000400"
        uuid = ROUTING.KNOWN_BAD_AX_BOUNDS_UUID if known_bad_helper else "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        source_identity = self.identity(source, "hash-a", build=build, uuid=uuid)
        runtime_identity = self.identity(
            runtime,
            "hash-a" if identity_match else "hash-b",
            build=build,
            uuid=uuid,
        )
        app_source_identity = self.identity(app_source, "hash-a", build=build, uuid=uuid)
        inventory = {
            "pluginInventoryAvailable": True,
            "pluginInventoryError": None,
            "pluginInventoryCLI": "/Applications/ChatGPT.app/Contents/Resources/codex",
            "computerUsePluginInstalled": plugin_installed,
            "computerUsePluginEnabled": plugin_enabled,
            "computerUsePluginVersion": "1.2.3",
            "computerUsePluginInventoryPath": str(root / "marketplace" / "computer-use"),
            "computerUsePluginInventoryCachePath": (
                str(root / "wrong-inventory-cache")
                if inventory_cache_path_mismatch
                else None
            ),
        }
        return {
            "temporary": temporary,
            "home": home,
            "config": config,
            "desktop": desktop,
            "sourceExecutable": source_executable,
            "runtimeExecutable": runtime_executable,
            "sourceIdentity": source_identity,
            "runtimeIdentity": runtime_identity,
            "appSourceIdentity": app_source_identity,
            "inventory": inventory,
        }

    @staticmethod
    def identity(app, digest, *, build="1000400", uuid="AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"):
        return {
            "appPath": str(app),
            "exists": True,
            "executablePath": str(app / ROUTING.SERVICE_RELATIVE_EXECUTABLE),
            "bundleIdentifier": "com.openai.sky.CUAService",
            "shortVersion": f"26.708.{build}",
            "bundleVersion": build,
            "teamIdentifier": "2DC432GLL2",
            "designatedRequirement": "identifier com.openai.sky.CUAService",
            "executableSHA256": digest,
            "executableUUIDs": [uuid],
            "executableUUID": uuid,
            "codesignValid": True,
        }

    def status(self, fixture, commands, *, crashes=None, related=None):
        identities = {
            fixture["sourceIdentity"]["appPath"]: fixture["sourceIdentity"],
            fixture["runtimeIdentity"]["appPath"]: fixture["runtimeIdentity"],
            fixture["appSourceIdentity"]["appPath"]: fixture["appSourceIdentity"],
        }
        related = related or {
            "mcpClientProcessCount": 0,
            "turnEndedClientCount": 0,
            "notificationClientProcessCount": 0,
            "nodeReplProcessCount": 1,
            "stdioAppServerCount": 0,
            "zombieChildCount": 0,
            "orphanedComputerUseClientCount": 0,
            "duplicateComputerUseClientSetCount": 0,
            "computerUseProcessFamilies": {},
            "staleClientSetDetected": False,
        }
        with mock.patch.object(ROUTING, "process_ids", return_value=list(commands)), mock.patch.object(
            ROUTING, "process_command", side_effect=lambda pid: commands[pid]
        ), mock.patch.object(
            ROUTING, "bundle_identity", side_effect=lambda path: identities[str(path)]
        ), mock.patch.object(
            ROUTING, "_macos_version", return_value="26.5.2"
        ), mock.patch.object(
            ROUTING, "related_process_counts", return_value=related
        ), mock.patch.object(
            ROUTING, "service_crash_reports", return_value=crashes or []
        ), mock.patch.object(
            ROUTING, "plugin_inventory", return_value=fixture["inventory"]
        ):
            return ROUTING.routing_status(
                config_path=fixture["config"],
                codex_home=fixture["home"],
                desktop_app=fixture["desktop"],
            )

    def make_fixture(self, **kwargs):
        fixture = self.fixture(**kwargs)
        self.addCleanup(fixture["temporary"].cleanup)
        return fixture

    @staticmethod
    def bounds_trap_ips(*, uuid=ROUTING.KNOWN_BAD_AX_BOUNDS_UUID, build=ROUTING.KNOWN_BAD_AX_BOUNDS_BUILD):
        registers = [{"value": 0} for _ in range(22)]
        registers[8] = {"value": 4}
        registers[21] = {"value": 5}
        header = {
            "app_name": ROUTING.PROCESS_NAME,
            "app_version": f"26.708.{build}",
            "build_version": build,
            "slice_uuid": uuid.lower(),
        }
        body = {
            "bundleInfo": {"CFBundleVersion": build},
            "exception": {"type": "EXC_BREAKPOINT", "signal": "SIGTRAP"},
            "threads": [{
                "triggered": True,
                "queue": "com.apple.root.user-initiated-qos.cooperative",
                "threadState": {
                    "x": registers,
                    "esr": {"description": "(Breakpoint) brk 1"},
                },
                "frames": [
                    {"imageOffset": value}
                    for value in (*ROUTING.KNOWN_BAD_AX_BOUNDS_OFFSETS, 6971280)
                ],
            }],
        }
        return json.dumps(header) + "\n" + json.dumps(body)

    def test_healthy_desktop_managed_runtime_and_manifest_entry_pass(self):
        fixture = self.make_fixture()
        status = self.status(fixture, {101: str(fixture["runtimeExecutable"])})
        self.assertTrue(status["readyForSession"])
        self.assertTrue(status["routingReady"])
        self.assertTrue(status["readyForDiagnostic"])
        self.assertTrue(status["readyForSuite"])
        self.assertEqual(status["routingStatus"], "expected")
        self.assertTrue(status["pluginManifestMirrorEntryPresent"])
        self.assertTrue(status["computerUseUsesNodeRepl"])
        self.assertTrue(status["nodeReplServerDeclared"])
        self.assertTrue(status["nodeReplServerEnabled"])
        self.assertTrue(status["computerUseManifestServerDeclared"])
        self.assertTrue(status["computerUseManifestMirrorEntryPresent"])
        self.assertFalse(status["computerUseManifestMirrorEnabled"])
        self.assertFalse(status["computerUseManifestMirrorConflicting"])
        self.assertTrue(status["pluginInventoryCachePathConsistent"])
        self.assertTrue(status["nodeReplConfiguredSourceMatchesInventoryCache"])
        self.assertTrue(status["nodeReplServerCommandMatchesDesktop"])
        self.assertFalse(status["duplicateTransportDefinitionPresent"])
        self.assertTrue(status["desktopManagedNotifyPresent"])
        self.assertEqual(status["routingExpectationSource"], "observed-desktop-build")
        self.assertTrue(status["computerUsePluginInstalled"])
        self.assertTrue(status["computerUsePluginEnabled"])
        self.assertTrue(status["computerUseServerAvailable"])
        self.assertTrue(status["computerUseSkillExpectedAvailable"])
        self.assertTrue(status["computerUseWrapperAvailable"])
        self.assertEqual(status["helperBuild"], "1000400")
        self.assertEqual(status["helperUUID"], "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        self.assertEqual(status["helperSHA256"], "hash-a")

    def test_unrelated_global_service_path_does_not_override_node_repl_env(self):
        fixture = self.make_fixture(unrelated_global_service_path=True)
        status = self.status(fixture, {101: str(fixture["runtimeExecutable"])})
        self.assertTrue(status["routingReady"])
        self.assertEqual(
            status["nodeReplConfiguredServicePath"],
            fixture["sourceIdentity"]["appPath"],
        )
        self.assertTrue(status["nodeReplConfiguredSourceMatchesInventoryCache"])

    def test_copied_plugin_source_is_not_the_installed_inventory_cache(self):
        fixture = self.make_fixture(copied_plugin_source=True)
        status = self.status(fixture, {101: str(fixture["runtimeExecutable"])})
        self.assertFalse(status["routingReady"])
        self.assertFalse(status["nodeReplConfiguredSourceMatchesInventoryCache"])
        self.assertTrue(
            any("does not match the installed plugin inventory cache app" in error for error in status["routingErrors"])
        )

    def test_inventory_cache_path_mismatch_is_rejected(self):
        fixture = self.make_fixture(inventory_cache_path_mismatch=True)
        status = self.status(fixture, {101: str(fixture["runtimeExecutable"])})
        self.assertFalse(status["routingReady"])
        self.assertFalse(status["pluginInventoryCachePathConsistent"])
        self.assertTrue(
            any("inventory cache path does not match" in error for error in status["routingErrors"])
        )

    def test_wrong_node_repl_command_is_rejected(self):
        fixture = self.make_fixture(wrong_node_repl_command=True)
        status = self.status(fixture, {101: str(fixture["runtimeExecutable"])})
        self.assertFalse(status["routingReady"])
        self.assertFalse(status["nodeReplServerCommandMatchesDesktop"])
        self.assertTrue(
            any("not the current ChatGPT Desktop-bundled executable" in error for error in status["routingErrors"])
        )

    def test_plugin_install_enable_server_skill_and_wrapper_are_independent_gates(self):
        cases = (
            ({"plugin_installed": False}, "not installed"),
            ({"plugin_enabled": False}, "not enabled"),
            ({"node_repl_declared": False}, "Node REPL MCP server is missing"),
            ({"node_repl_enabled": False}, "Node REPL MCP server is disabled"),
            ({"skill_present": False}, "skill is missing"),
            ({"wrapper_present": False}, "Node wrapper is missing"),
        )
        for options, message in cases:
            with self.subTest(options=options):
                fixture = self.make_fixture(**options)
                status = self.status(fixture, {101: str(fixture["runtimeExecutable"])})
                self.assertFalse(status["routingReady"])
                self.assertFalse(status["readyForDiagnostic"])
                self.assertFalse(status["readyForSuite"])
                self.assertTrue(any(message in error for error in status["routingErrors"]))

    def test_known_bad_helper_blocks_suites_but_allows_explicit_diagnostic_policy(self):
        fixture = self.make_fixture(known_bad_helper=True)
        status = self.status(fixture, {101: str(fixture["runtimeExecutable"])})
        self.assertTrue(status["routingReady"])
        self.assertTrue(status["readyForDiagnostic"])
        self.assertFalse(status["readyForSuite"])
        self.assertFalse(status["readyForSession"])
        self.assertFalse(status["ready"])
        self.assertTrue(status["knownBadHelperDetected"])
        self.assertEqual(status["knownBadHelperRule"]["classification"], "ax-tree-bounds-trap-1000366")
        self.assertTrue(any("known AX tree bounds trap" in value for value in status["suiteBlockers"]))

    def test_plugin_cache_fallback_is_session_fatal_not_declared_crash_cause(self):
        fixture = self.make_fixture()
        status = self.status(fixture, {101: str(fixture["sourceExecutable"])})
        self.assertFalse(status["ready"])
        self.assertEqual(status["routingStatus"], "fallback")
        self.assertTrue(status["unexpectedPluginCacheFallbackForThisBuild"])
        self.assertTrue(any("fallback routing observed" in error for error in status["errors"]))

    def test_missing_duplicate_and_unknown_services_fail(self):
        fixture = self.make_fixture()
        missing = self.status(fixture, {})
        self.assertEqual(missing["routingStatus"], "missing")
        duplicate = self.status(fixture, {
            101: str(fixture["runtimeExecutable"]),
            102: str(fixture["sourceExecutable"]),
        })
        self.assertEqual(duplicate["routingStatus"], "duplicate")
        unknown_path = fixture["home"] / "other" / "Codex Computer Use.app" / ROUTING.SERVICE_RELATIVE_EXECUTABLE
        unknown = self.status(fixture, {103: str(unknown_path)})
        self.assertEqual(unknown["routingStatus"], "unknown")
        self.assertTrue(unknown["unknownLiveServicePath"])

    def test_source_runtime_identity_mismatch_fails(self):
        fixture = self.make_fixture(identity_match=False)
        status = self.status(fixture, {101: str(fixture["runtimeExecutable"])})
        self.assertFalse(status["sourceRuntimeIdentityMatch"])
        self.assertFalse(status["sourceRuntimeExecutableHashMatch"])
        self.assertFalse(status["computerUseServicePathVerified"])

    def test_enabled_manifest_mirror_conflicts_with_node_repl_variant(self):
        fixture = self.make_fixture(top_level_enabled=True)
        status = self.status(fixture, {101: str(fixture["runtimeExecutable"])})
        self.assertTrue(status["commandConfiguredEntryPresent"])
        self.assertTrue(status["pluginManagedEntryPresent"])
        self.assertTrue(status["computerUseManifestMirrorEnabled"])
        self.assertTrue(status["computerUseManifestMirrorConflicting"])
        self.assertTrue(status["duplicateTransportDefinitionPresent"])
        self.assertFalse(status["ready"])
        self.assertTrue(any("conflicts with node-repl" in error for error in status["routingErrors"]))

    def test_stale_command_and_notify_paths_fail(self):
        fixture = self.make_fixture(stale_command=True, stale_notify=True)
        status = self.status(fixture, {101: str(fixture["runtimeExecutable"])})
        self.assertTrue(status["staleCommandPathPresent"])
        self.assertTrue(status["staleNotifyPathPresent"])
        self.assertFalse(status["ready"])

    def test_plugin_managed_policy_entry_is_reported_without_transport_command(self):
        fixture = self.make_fixture(plugin_override=True, bundled_content_variant=None)
        status = self.status(fixture, {101: str(fixture["runtimeExecutable"])})
        self.assertTrue(status["pluginManagedEntryPresent"])
        override = next(entry for entry in status["computerUseConfigEntries"] if entry["scope"] == "plugin-override")
        self.assertIsNone(override["command"])
        self.assertTrue(status["ready"])

    def test_unverified_desktop_version_blocks_automatic_path_assumption(self):
        fixture = self.make_fixture(desktop_version="26.800.1")
        status = self.status(fixture, {101: str(fixture["runtimeExecutable"])})
        self.assertEqual(status["routingExpectationSource"], "unverified-desktop-build")
        self.assertIsNone(status["expectedRuntimePath"])
        self.assertFalse(status["ready"])

    def test_dyld_compatibility_classification_precedes_routing(self):
        classification, dyld, signatures = ROUTING.classify_crash(
            "OS_REASON_DYLD Symbol not found: _swift_task_addPriorityEscalationHandler EXC_BREAKPOINT"
        )
        self.assertEqual(classification, "dyld-compatibility")
        self.assertTrue(dyld)
        self.assertIn("OS_REASON_DYLD", signatures)

    def test_accessibility_observer_breakpoint_is_classified_without_claiming_root_cause(self):
        classification, dyld, signatures = ROUTING.classify_crash(
            "EXC_BREAKPOINT SIGTRAP thread name AXNotificationObserver"
        )
        self.assertEqual(classification, "breakpoint-with-accessibility-observers")
        self.assertFalse(dyld)
        self.assertIn("AXNotificationObserver", signatures)

    def test_exact_1000366_ax_bounds_trap_uses_uuid_offsets_and_registers(self):
        metadata = ROUTING._crash_metadata(self.bounds_trap_ips())
        self.assertEqual(metadata["classification"], "ax-tree-bounds-trap-1000366")
        self.assertTrue(metadata["knownBadBoundsTrap"])
        self.assertEqual(metadata["helperUUID"], ROUTING.KNOWN_BAD_AX_BOUNDS_UUID)
        self.assertEqual(metadata["helperBuild"], ROUTING.KNOWN_BAD_AX_BOUNDS_BUILD)
        self.assertEqual(metadata["faultRegisters"], {"x8": 4, "x21": 5})

    def test_near_match_sigtrap_does_not_claim_the_known_bounds_failure(self):
        metadata = ROUTING._crash_metadata(
            self.bounds_trap_ips(uuid="BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")
        )
        self.assertEqual(metadata["classification"], "breakpoint-sigtrap")
        self.assertFalse(metadata["knownBadBoundsTrap"])

    def test_accessibility_bad_access_with_recursive_tree_evidence_is_ax_stack_exhaustion(self):
        classification, dyld, signatures = ROUTING.classify_crash(
            "EXC_BAD_ACCESS UIElementTree.add UIElementTree.add AccessibilitySupport"
        )
        self.assertEqual(classification, "ax-stack-exhaustion")
        self.assertFalse(dyld)
        self.assertIn("EXC_BAD_ACCESS", signatures)

    def test_plugin_inventory_reads_installed_and_available_sections_without_mutation(self):
        payload = {
            "installed": [{
                "pluginId": ROUTING.COMPUTER_USE_PLUGIN_ID,
                "installed": True,
                "enabled": True,
                "version": "1.0.1000400",
                "source": {"path": "/tmp/computer-use"},
            }],
            "available": [],
        }
        result = ROUTING.subprocess.CompletedProcess([], 0, json.dumps(payload), "")
        with mock.patch.object(ROUTING, "_codex_cli", return_value=Path("/tmp/codex")), mock.patch.object(
            ROUTING, "_run", return_value=result
        ) as runner:
            inventory = ROUTING.plugin_inventory()
        runner.assert_called_once_with(["/tmp/codex", "plugin", "list", "--available", "--json"])
        self.assertTrue(inventory["pluginInventoryAvailable"])
        self.assertTrue(inventory["computerUsePluginInstalled"])
        self.assertTrue(inventory["computerUsePluginEnabled"])
        self.assertEqual(inventory["computerUsePluginInventoryPath"], "/tmp/computer-use")

    def test_plugin_inventory_reports_uninstalled_plugin_and_invalid_json(self):
        available = {
            "installed": [],
            "available": [{
                "pluginId": ROUTING.COMPUTER_USE_PLUGIN_ID,
                "installed": False,
                "enabled": False,
                "version": "1.0.1000366",
                "source": {"path": "/tmp/marketplace/computer-use"},
            }],
        }
        with mock.patch.object(ROUTING, "_codex_cli", return_value=Path("/tmp/codex")), mock.patch.object(
            ROUTING,
            "_run",
            return_value=ROUTING.subprocess.CompletedProcess([], 0, json.dumps(available), ""),
        ):
            inventory = ROUTING.plugin_inventory()
        self.assertTrue(inventory["pluginInventoryAvailable"])
        self.assertFalse(inventory["computerUsePluginInstalled"])
        self.assertFalse(inventory["computerUsePluginEnabled"])
        with mock.patch.object(ROUTING, "_codex_cli", return_value=Path("/tmp/codex")), mock.patch.object(
            ROUTING,
            "_run",
            return_value=ROUTING.subprocess.CompletedProcess([], 0, "not-json", ""),
        ):
            invalid = ROUTING.plugin_inventory()
        self.assertFalse(invalid["pluginInventoryAvailable"])
        self.assertIn("invalid JSON", invalid["pluginInventoryError"])

    def test_new_crash_reports_are_detected_and_classified(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            old = root / "SkyComputerUseService-2026-07-10-100000.ips"
            new = root / "SkyComputerUseService-2026-07-10-100001.ips"
            old.write_text('{"exception":{"type":"EXC_BREAKPOINT","signal":"SIGTRAP"}}')
            baseline = ROUTING.service_crash_reports(root)
            new.write_text('{"exception":{"type":"EXC_BAD_ACCESS"}}')
            delta = ROUTING.new_service_crash_reports(baseline, root)
            self.assertEqual([item["path"] for item in delta], [str(new)])
            self.assertEqual(delta[0]["classification"], "bad-access")

    def test_related_process_families_are_counted_separately(self):
        output = "\n".join((
            "100 1 S /Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
            "101 100 S /tmp/SkyComputerUseClient mcp",
            "102 100 S /tmp/SkyComputerUseClient turn-ended",
            "103 100 S /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl",
            "104 100 S /tmp/codex app-server --listen stdio://",
            "105 100 Z <defunct>",
        ))
        result = ROUTING.subprocess.CompletedProcess([], 0, output, "")
        with mock.patch.object(ROUTING, "_run", return_value=result), mock.patch.object(
            ROUTING, "DESKTOP_APP", Path("/Applications/ChatGPT.app")
        ):
            counts = ROUTING.related_process_counts()
        self.assertEqual(counts["mcpClientProcessCount"], 1)
        self.assertEqual(counts["turnEndedClientCount"], 1)
        self.assertEqual(counts["notificationClientProcessCount"], 1)
        self.assertEqual(counts["nodeReplProcessCount"], 1)
        self.assertEqual(counts["stdioAppServerCount"], 1)
        self.assertEqual(counts["zombieChildCount"], 1)
        self.assertEqual(len(counts["computerUseProcessFamilies"]["mcpClients"]), 1)
        self.assertEqual(len(counts["computerUseProcessFamilies"]["notificationClients"]), 1)
        self.assertTrue(counts["staleClientSetDetected"])

    def test_multiple_live_node_repls_are_diagnostic_not_stale_by_count_alone(self):
        output = "\n".join((
            "100 1 S /Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
            "101 100 S /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl",
            "102 100 S /Applications/ChatGPT.app/Contents/Resources/cua_node/bin/node_repl",
        ))
        result = ROUTING.subprocess.CompletedProcess([], 0, output, "")
        with mock.patch.object(ROUTING, "_run", return_value=result), mock.patch.object(
            ROUTING, "DESKTOP_APP", Path("/Applications/ChatGPT.app")
        ):
            counts = ROUTING.related_process_counts()
        self.assertEqual(counts["nodeReplProcessCount"], 2)
        self.assertFalse(counts["staleClientSetDetected"])

    def test_audit_uses_only_read_only_system_commands(self):
        fixture = self.make_fixture()
        commands = []

        def record(command):
            commands.append(command)
            return ROUTING.subprocess.CompletedProcess(command, 1, "", "")

        with mock.patch.object(ROUTING, "_run", side_effect=record):
            ROUTING.routing_status(
                config_path=fixture["config"],
                codex_home=fixture["home"],
                desktop_app=fixture["desktop"],
            )

        self.assertTrue(commands)
        self.assertLessEqual(
            {Path(command[0]).name for command in commands},
            {"pgrep", "codesign", "sw_vers", "ps", "dwarfdump", "codex"},
        )
        forbidden = {"rm", "kill", "open", "ditto", "launchctl", "tccutil"}
        self.assertFalse(any(Path(command[0]).name in forbidden for command in commands))


if __name__ == "__main__":
    unittest.main()
