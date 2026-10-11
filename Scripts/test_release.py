"""Tests for Scripts/release.py.  python3 -m unittest discover -s Scripts -p 'test_*.py'"""
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import release  # noqa: E402
from release import Commit, next_version  # noqa: E402


def commits(*subjects):
    return [Commit(f"{i:07x}".ljust(40, "f"), s) for i, s in enumerate(subjects)]


class NextVersionTests(unittest.TestCase):
    def test_first_release_is_0_1_0(self):
        self.assertEqual(next_version(None, commits("fix: a", "feat!: b")), (0, 1, 0))

    def test_explicit_bump_with_no_tag_starts_from_zero(self):
        self.assertEqual(next_version(None, [], "patch"), (0, 0, 1))
        self.assertEqual(next_version(None, [], "major"), (1, 0, 0))

    def test_fixes_and_chores_bump_patch(self):
        self.assertEqual(next_version((0, 1, 0), commits("fix: a", "chore: b", "docs: c")), (0, 1, 1))

    def test_unconventional_subject_bumps_patch(self):
        self.assertEqual(next_version((1, 2, 3), commits("Update things")), (1, 2, 4))

    def test_feat_bumps_minor_and_resets_patch(self):
        self.assertEqual(next_version((0, 1, 4), commits("fix: a", "feat(app): b")), (0, 2, 0))

    def test_breaking_before_1_0_bumps_minor(self):
        self.assertEqual(next_version((0, 3, 2), commits("feat(app)!: b")), (0, 4, 0))

    def test_breaking_after_1_0_bumps_major(self):
        self.assertEqual(next_version((1, 3, 2), commits("refactor!: b")), (2, 0, 0))

    def test_breaking_change_footer(self):
        c = [Commit("a" * 40, "fix: a", "Details.\n\nBREAKING CHANGE: settings reset")]
        self.assertTrue(c[0].breaking)
        self.assertEqual(next_version((1, 0, 0), c), (2, 0, 0))

    def test_explicit_bump_overrides_commits(self):
        self.assertEqual(next_version((0, 2, 0), commits("feat: a"), "patch"), (0, 2, 1))
        self.assertEqual(next_version((0, 2, 0), commits("fix: a"), "major"), (1, 0, 0))

    def test_parse_version(self):
        self.assertEqual(release.parse_version("v1.2.3"), (1, 2, 3))
        self.assertEqual(release.parse_version("1.2.3"), (1, 2, 3))
        with self.assertRaises(ValueError):
            release.parse_version("v1.2")


class NotesTests(unittest.TestCase):
    def test_groups_by_type(self):
        text = release.notes((0, 2, 0), (0, 1, 0),
                             commits("feat(app): add a thing", "fix: mend a thing", "docs: write it down"),
                             "OpenCaptions-0.2.0.ipa")
        self.assertIn("since v0.1.0", text)
        features, fixes, other = (text.index(f"## {h}") for h in ("Features", "Fixes", "Other"))
        self.assertLess(features, fixes)
        self.assertLess(fixes, other)
        self.assertIn("- **app:** Add a thing (0000000)", text)
        self.assertIn("- Mend a thing (0000001)", text)
        self.assertIn("## How to install", text)
        self.assertIn("OpenCaptions-0.2.0.ipa", text)

    def test_sentence_case_leaves_mixed_case_words(self):
        text = release.notes((0, 1, 0), None, commits("feat: iOS app shell"), "x.ipa")
        self.assertIn("- iOS app shell", text)
        self.assertIn("in the first release", text)

    def test_empty_groups_are_left_out(self):
        text = release.notes((0, 1, 1), (0, 1, 0), commits("fix: a"), "x.ipa")
        self.assertNotIn("## Features", text)
        self.assertNotIn("## Other", text)

    def test_breaking_is_marked(self):
        text = release.notes((0, 2, 0), (0, 1, 0), commits("feat!: drop the old format"), "x.ipa")
        self.assertIn("**Breaking:** Drop the old format", text)


class GitTests(unittest.TestCase):
    """Runs the script against a throwaway repository."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        self.env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
                    "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com",
                    "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
        self.git("init", "-q")

    def tearDown(self):
        self.tmp.cleanup()

    def git(self, *args):
        subprocess.run(["git", "-C", self.dir, *args], check=True, capture_output=True, env=self.env)

    def commit(self, subject):
        self.git("commit", "-q", "--allow-empty", "-m", subject)

    def run_script(self, *args):
        result = subprocess.run([sys.executable, "-I", str(Path(release.__file__)), *args], cwd=self.dir,
                                capture_output=True, text=True, env=self.env)
        return result.returncode, result.stdout.strip(), result.stderr.strip()

    def test_versions_follow_tags(self):
        self.commit("feat: first")
        self.assertEqual(self.run_script("next-version")[1], "0.1.0")
        self.git("tag", "v0.1.0")
        status, _, err = self.run_script("next-version")
        self.assertNotEqual(status, 0)
        self.assertIn("nothing to release", err)
        self.commit("fix: second")
        self.git("tag", "not-a-release")
        self.assertEqual(self.run_script("next-version")[1], "0.1.1")
        self.commit("feat: third")
        self.assertEqual(self.run_script("next-version")[1], "0.2.0")
        self.assertEqual(self.run_script("next-version", "--bump", "major")[1], "1.0.0")

    def test_notes_cover_only_this_release(self):
        self.commit("feat: old")
        self.git("tag", "v0.1.0")
        self.commit("fix: new")
        self.git("tag", "v0.1.1")  # the tag of the release being written, as on a tag push
        _, text, _ = self.run_script("notes", "0.1.1")
        self.assertIn("since v0.1.0", text)
        self.assertIn("New", text)
        self.assertNotIn("Old", text)


if __name__ == "__main__":
    unittest.main()
