import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from fixture_results import validate_checks, report
from gui_lock import gui_lock


class FixtureResultsTests(unittest.TestCase):
    def test_behavior_required_even_when_binary_matches(self):
        for value in [{}, {"verified_binary_unchanged": True}]:
            with self.assertRaises(ValueError):
                validate_checks(value, {"native_input"})

    def test_partial_malformed_and_false_reports_fail(self):
        for value in [None, [], {"a": 1}, {"a": "true"}, {"a": False}, {"b": True}]:
            with self.assertRaises(ValueError):
                validate_checks(value, {"a"})
        with self.assertRaises(ValueError):
            validate_checks({"a": True}, set())

    def test_complete_report_has_separate_identity_and_counts(self):
        result = report("composer", {"a": True}, {"a"}, binary_sha256="f" * 64)
        self.assertEqual(result["counts"]["passed"], 1)
        self.assertEqual(result["checks"], {"a": True})

    def test_cross_process_lock_contention_and_release(self):
        with tempfile.TemporaryDirectory() as root:
            lock = Path(root) / "lock"
            command = [
                sys.executable,
                "-c",
                "from gui_lock import gui_lock\nimport sys\nwith gui_lock(path=sys.argv[1],timeout=0): pass",
                str(lock),
            ]
            import os

            env = dict(
                os.environ,
                PYTHONPATH=str(Path(__file__).resolve().parents[2] / "scripts"),
            )
            with gui_lock(path=lock):
                self.assertNotEqual(
                    subprocess.run(command, env=env, capture_output=True).returncode, 0
                )
            self.assertEqual(
                subprocess.run(command, env=env, capture_output=True).returncode, 0
            )


class RunnerDiscoveryTests(unittest.TestCase):
    def test_compatibility_suite_counts_are_included_and_empty_reports_fail(self):
        from native_runner import native_report_counts

        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "summary.json"
            counts = dict(passed=3, failed=0, skipped=0, excluded=1)
            path.write_text(json.dumps(dict(counts=counts)))
            self.assertEqual(native_report_counts(path), counts)
            path.write_text(json.dumps(dict(counts=dict(counts, passed=0))))
            with self.assertRaises(RuntimeError):
                native_report_counts(path)

    def test_zero_discovery_fails(self):
        import importlib.util

        path = Path(__file__).resolve().parents[2] / "scripts/test.py"
        spec = importlib.util.spec_from_file_location("spookky_test_runner", path)
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        with self.assertRaises(RuntimeError):
            runner.require_discovered(0, "selected")
        runner.require_discovered(1, "selected")


class TestInventoryTests(unittest.TestCase):
    def test_existing_swift_scenarios_remain_discoverable(self):
        from collections import Counter
        import re

        root = Path(__file__).resolve().parents[2]
        expected = json.loads((root / "Tests/Inventory/swift-cases.json").read_text())
        actual = []
        for group in [
            "SpookkyUnitTests",
            "SpookkyIntegrationTests",
            "SpookkyProviderTests",
        ]:
            for source in (root / "Tests" / group).rglob("*.swift"):
                actual += re.findall(r"func (test\w+)\(", source.read_text())
        self.assertFalse(
            Counter(expected) - Counter(actual), "An existing scenario disappeared"
        )


class FixtureCleanupTests(unittest.TestCase):
    def test_failure_preserves_evidence_and_cleans_only_owned_files(self):
        from unittest.mock import patch
        import native_fixture

        class Process:
            def __init__(self, *args, **kwargs):
                self.terminated = False

            def terminate(self):
                self.terminated = True

            def wait(self, timeout=None):
                return 0

        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            unrelated = parent / "unrelated"
            unrelated.write_text("retain")
            process = Process()
            from contextlib import nullcontext

            with (
                patch.object(native_fixture, "gui_lock", return_value=nullcontext()),
                patch.object(native_fixture, "validate_harness"),
                patch.object(native_fixture, "code_hashes", return_value={}),
                patch.object(native_fixture, "ROOT", parent),
                patch.object(native_fixture.subprocess, "Popen", return_value=process),
                patch.object(native_fixture.os, "access", return_value=True),
            ):
                with self.assertRaisesRegex(RuntimeError, "owned failure"):
                    with native_fixture.native_fixture(
                        [], prefix="spookky-cleanup-", binary=parent / "SpookkyHarness"
                    ) as fixture:
                        owned = fixture.root
                        (owned / "checks.json").write_text('{"a": false}')
                        raise RuntimeError("owned failure")
            self.assertTrue(process.terminated)
            self.assertFalse(owned.exists())
            self.assertEqual(unrelated.read_text(), "retain")
            self.assertTrue(list((parent / ".cache").rglob("checks.json")))


class NativeExitStatusTests(unittest.TestCase):
    def test_failed_skipped_and_empty_native_batches_fail(self):
        import importlib.util

        path = Path(__file__).resolve().parents[2] / "scripts/test.py"
        spec = importlib.util.spec_from_file_location("native_test_runner", path)
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        for counts in [
            dict(passed=1, failed=1, skipped=0),
            dict(passed=0, failed=0, skipped=1),
            dict(passed=0, failed=0, skipped=0),
            dict(passed=1, failed=0, skipped=0, infrastructure_failures=1),
        ]:
            with self.assertRaises(RuntimeError):
                runner.validate_native_counts(counts)
        runner.validate_native_counts(dict(passed=1, failed=0, skipped=0))


class NativeSelectionTests(unittest.TestCase):
    def test_simple_and_qualified_cases_have_one_owner(self):
        import importlib.util

        path = Path(__file__).resolve().parents[2] / "scripts/test.py"
        spec = importlib.util.spec_from_file_location("native_selector_runner", path)
        runner = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(runner)
        expected = "-only-testing:SpookkyNativeTests/NativeScenarioTests/testSmoke"
        self.assertEqual(runner.native_selector("testSmoke"), expected)
        self.assertEqual(
            runner.native_selector("NativeScenarioTests/testSmoke"), expected
        )
        self.assertEqual(
            runner.native_selector("RuntimeMonitorTests/testEvents"),
            "-only-testing:SpookkyNativeTests/RuntimeMonitorTests/testEvents",
        )


class HarnessIdentityTests(unittest.TestCase):
    def test_renamed_normal_binary_is_rejected(self):
        from native_fixture import validate_harness
        import plistlib

        with tempfile.TemporaryDirectory() as temporary:
            contents = Path(temporary) / "Contents"
            (contents / "MacOS").mkdir(parents=True)
            (contents / "Info.plist").write_bytes(
                plistlib.dumps(
                    dict(
                        CFBundleExecutable="SpookkyHarness",
                        CFBundleIdentifier="dev.spookky.development.example",
                    )
                )
            )
            binary = contents / "MacOS/SpookkyHarness"
            binary.write_text("fixture")
            binary.chmod(0o700)
            with self.assertRaisesRegex(ValueError, "Build the SpookkyHarness scheme"):
                validate_harness(binary)
            (contents / "Info.plist").write_bytes(
                plistlib.dumps(
                    dict(
                        CFBundleExecutable="SpookkyHarness",
                        CFBundleIdentifier="dev.spookky.harness",
                    )
                )
            )
            validate_harness(binary)


class SerializedReportTests(unittest.TestCase):
    def test_invalid_json_and_non_boolean_values_cannot_pass(self):
        from fixture_results import read_checks

        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "checks.json"
            for raw in ["", "{", "{}", '{"a": 1}', '{"a": null}', '{"b": true}']:
                path.write_text(raw)
                with self.assertRaises((ValueError, json.JSONDecodeError)):
                    read_checks(path, {"a"})

    def test_exiting_owner_releases_operating_system_lock(self):
        import os

        with tempfile.TemporaryDirectory() as temporary:
            lock = Path(temporary) / "lock"
            env = dict(
                os.environ,
                PYTHONPATH=str(Path(__file__).resolve().parents[2] / "scripts"),
            )
            code = 'from gui_lock import gui_lock\nimport sys\nwith gui_lock(path=sys.argv[1]):\n print("locked",flush=True)\n sys.stdin.read()'
            child = subprocess.Popen(
                [sys.executable, "-c", code, str(lock)],
                env=env,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                text=True,
            )
            try:
                self.assertEqual(child.stdout.readline().strip(), "locked")
                child.terminate()
                child.wait(timeout=3)
                with gui_lock(path=lock, timeout=1):
                    pass
            finally:
                if child.poll() is None:
                    child.kill()
                    child.wait()
                child.stdout.close()
                child.stdin.close()


class HarnessPackagingTests(unittest.TestCase):
    def test_packaging_rejects_harness_identity_and_test_bundles(self):
        from verify_bundle import verify
        import plistlib

        with tempfile.TemporaryDirectory() as temporary:
            app = Path(temporary) / "Spookky.app"
            contents = app / "Contents"
            contents.mkdir(parents=True)
            info = contents / "Info.plist"
            info.write_bytes(
                plistlib.dumps(dict(CFBundleIdentifier="dev.spookky.harness.fixture"))
            )
            with self.assertRaisesRegex(ValueError, "Harness and test artifacts"):
                verify(app)
            info.write_bytes(
                plistlib.dumps(
                    dict(CFBundleIdentifier="dev.spookky.development.fixture")
                )
            )
            (contents / "PlugIns/Unexpected.xctest").mkdir(parents=True)
            with self.assertRaisesRegex(ValueError, "Harness and test artifacts"):
                verify(app)


class NativePrerequisiteTests(unittest.TestCase):
    def test_missing_xcode_fails_before_a_native_command_runs(self):
        import native_runner
        from types import SimpleNamespace
        from unittest.mock import patch

        with (
            patch.object(native_runner.shutil, "which", return_value=None),
            patch.object(native_runner, "run") as run,
        ):
            with self.assertRaisesRegex(RuntimeError, "full Xcode"):
                native_runner.native_tests(SimpleNamespace(output="/unused"))
            run.assert_not_called()


class DebugCodeIdentityTests(unittest.TestCase):
    def test_changed_debug_dylib_changes_identity_when_launcher_is_unchanged(self):
        from binary_identity import code_hashes

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            launcher = root / "SpookkyHarness"
            launcher.write_text("unchanged launcher")
            launcher.chmod(0o700)
            dylib = root / "SpookkyHarness.debug.dylib"
            dylib.write_text("before")
            before = code_hashes(launcher)
            dylib.write_text("after")
            after = code_hashes(launcher)
            self.assertEqual(before["SpookkyHarness"], after["SpookkyHarness"])
            self.assertNotEqual(before, after)


class PerformanceConfigurationTests(unittest.TestCase):
    def test_harness_build_and_binary_use_selected_configuration(self):
        import native_runner
        from types import SimpleNamespace
        from unittest.mock import patch

        with tempfile.TemporaryDirectory() as temporary:
            for configuration in ["debug", "release"]:
                with (
                    patch.object(native_runner.shutil, "which", return_value="xcodebuild"),
                    patch.object(native_runner.os, "access", return_value=True),
                    patch.object(Path, "exists", return_value=True),
                    patch.object(native_runner, "run") as run,
                ):
                    command, binary = native_runner.prepare_harness(
                        SimpleNamespace(configuration=configuration, output=temporary),
                        testing=False,
                    )
                self.assertEqual(command[command.index("-configuration") + 1], configuration.title())
                self.assertEqual(binary.parents[3].name, configuration.title())
                self.assertEqual(run.call_args.args[0][-1], "build")
