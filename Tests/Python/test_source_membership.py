from pathlib import Path
import hashlib
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


def identifier(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


class NativeSourceMembershipTests(unittest.TestCase):
    def test_production_source_phase_excludes_all_harness_and_test_files(self):
        project = (ROOT / "Spookky.xcodeproj/project.pbxproj").read_text()
        line = next(
            line
            for line in project.splitlines()
            if identifier("sources") + " = " in line
        )
        actual = set(re.findall(r"\b[A-F0-9]{24}\b", line)) - {identifier("sources")}
        expected = {
            identifier("build" + str(path.relative_to(ROOT)))
            for path in (ROOT / "App").rglob("*.swift")
        }
        self.assertEqual(actual, expected)
        for path in (ROOT / "Tests").rglob("*.swift"):
            self.assertNotIn(identifier("build" + str(path.relative_to(ROOT))), actual)

    def test_distribution_never_defines_harness_compilation(self):
        project = (ROOT / "Spookky.xcodeproj/project.pbxproj").read_text()
        config = next(
            line
            for line in project.splitlines()
            if identifier("config-Distribution") + " = " in line
        )
        self.assertNotIn("SPOOKKY_HARNESS", config)
        self.assertIn("SPOOKKY_DISTRIBUTION", config)


class NativeScenarioInventoryTests(unittest.TestCase):
    def test_original_native_assertion_templates_remain_present(self):
        import json

        baseline = json.loads(
            (ROOT / "Tests/Inventory/native-baseline-assertions.json").read_text()
        )["assertion_templates"]
        texts = [
            path.read_text() for path in (ROOT / "Tests/NativeHarness").glob("*.swift")
        ]
        actual = set(
            name
            for text in texts
            for name in re.findall(r'checks\["([^"\n]+)"\]', text)
        )
        self.assertFalse(
            set(baseline) - actual, "An original native assertion disappeared"
        )
