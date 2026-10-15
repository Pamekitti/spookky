import unittest

from check_public import has_note_refs


class PublicRefTests(unittest.TestCase):
    def test_notes_cannot_pass_by_being_copied_into_an_audit_namespace(self):
        for ref in ["refs/notes/ai", "refs/audit/origin/notes/ai", "refs/remotes/origin/notes/ai"]:
            self.assertTrue(has_note_refs(["refs/heads/main", ref]))

    def test_normal_branches_and_tags_remain_publishable(self):
        self.assertFalse(has_note_refs(["refs/heads/main", "refs/heads/notes/topic", "refs/tags/v1", "refs/audit/origin/heads/main"]))


if __name__ == "__main__":
    unittest.main()
