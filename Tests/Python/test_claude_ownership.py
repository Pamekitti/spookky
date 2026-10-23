import tempfile
import unittest
from pathlib import Path

from check_claude_ownership import owned_background_ids


class ClaudeOwnershipFixtureTests(unittest.TestCase):
    def test_native_attach_requires_exact_session_and_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            checkout = Path(directory) / "checkout"
            checkout.mkdir()
            alias = Path(directory) / "alias"
            alias.symlink_to(checkout)
            owner = {"kind": "background", "sessionId": "exact-session", "cwd": str(checkout), "id": "owned-id"}
            rows = [owner, dict(owner, sessionId="another-session", id="other-session"),
                    dict(owner, cwd=directory, id="other-folder"), dict(owner, kind="interactive", id="foreground"),
                    dict(owner, cwd=None, id="missing-folder"), dict(owner, id="--unsafe"),
                    dict(owner, cwd=str(alias), id="owned-alias"), {"id": "unrelated"}]
            self.assertEqual(owned_background_ids(rows, "exact-session", checkout), {"owned-id", "owned-alias"})

    def test_cleanup_includes_a_new_copy_only_in_the_fixture_checkout(self):
        with tempfile.TemporaryDirectory() as directory:
            checkout = Path(directory) / "checkout"
            checkout.mkdir()
            owner = {"kind": "background", "sessionId": "expected-session", "cwd": str(checkout), "id": "existing"}
            baseline = owned_background_ids([owner], None, checkout)
            copied = dict(owner, sessionId="copied-session", id="new-copy")
            unrelated = dict(copied, cwd=directory, id="unrelated")
            rows = [owner, copied, unrelated]
            self.assertEqual(owned_background_ids(rows, "expected-session", checkout) - baseline, set())
            self.assertEqual(owned_background_ids(rows, None, checkout) - baseline, {"new-copy"})


if __name__ == "__main__":
    unittest.main()
