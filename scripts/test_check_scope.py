from pathlib import Path
import subprocess
import tempfile
import unittest

from check_scope import changed_paths, classify
from check import commands


class CheckScopeTests(unittest.TestCase):
    def test_docs_and_agent_instructions_need_no_native_or_browser_build(self):
        scope = classify(["AGENTS.md", "docs/lifecycle.md", ".agents/skills/ship/SKILL.md", ".claude/skills/ship"])
        self.assertFalse(any(scope.values()))
        self.assertEqual(len(commands(scope)), 2)

    def test_native_fixture_documents_still_run_native_checks(self):
        self.assertTrue(classify(["Tests/fixtures/input.md"])["native"])
        self.assertTrue(classify(["Sources/SpookkyCore/AppPaths.swift"])["local_native"])
        self.assertFalse(classify(["Sources/SpookkyCore/AppPaths.swift"])["website"])

    def test_unknown_paths_or_missing_base_run_every_check(self):
        for scope in [classify(["new-build-system.toml"]), classify([], unknown_base=True)]:
            self.assertTrue(all(scope.values()))

    def test_ci_changes_exercise_ci_jobs_without_rebuilding_unchanged_local_app(self):
        for path in [".github/workflows/ci.yml", "scripts/check_scope.py"]:
            scope = classify([path])
            self.assertTrue(scope["native"] and scope["website"])
            self.assertFalse(scope["local_native"])

    def test_packaging_and_website_changes_select_their_checks(self):
        self.assertTrue(classify(["scripts/build_native.sh"])["packaging"])
        scope = classify(["website/index.html"])
        self.assertTrue(scope["website"])
        self.assertFalse(scope["native"])

    def test_rename_out_of_native_tree_cannot_hide_deleted_native_source(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            def git(*args):
                return subprocess.check_output(["git", *args], cwd=root, stderr=subprocess.DEVNULL).decode().strip()
            git("init")
            (root / "Sources").mkdir()
            (root / "Sources/fixture.md").write_text("fixture")
            git("add", "Sources/fixture.md")
            git("-c", "user.name=Fixture", "-c", "user.email=fixture@example.com", "commit", "-m", "fixture")
            base = git("rev-parse", "HEAD")
            git("mv", "Sources/fixture.md", "README.md")
            paths, unknown = changed_paths(base, root=root)
            self.assertFalse(unknown)
            self.assertIn("Sources/fixture.md", paths)
            self.assertTrue(classify(paths)["native"])


if __name__ == "__main__":
    unittest.main()
