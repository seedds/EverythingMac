import unittest
from pathlib import Path
import tempfile
from unittest.mock import Mock, patch

import release


class ReleaseNotesTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.notes_dir = Path(directory.name)
        self.version = Path("VERSION").read_text().strip()
        self.notes = self.notes_dir / f"{self.version}.md"
        self.body = "## Changes\n\n- Show progress during indexing.\n"
        self.notes.write_text(self.body, encoding="utf-8")
        patcher = patch.object(release, "RELEASE_NOTES", self.notes_dir)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_accepts_written_changes(self):
        self.assertEqual(release.release_notes_path(self.version), self.notes)

    def test_rejects_missing_empty_and_link_notes(self):
        for body in ["", "  \n", "## Changes\n", "**Full Changelog**: https://github.com/a/b/compare/v1...v2",
                     self.body + "[Details](changes.md)", self.body + "[Details]: changes.md"]:
            with self.subTest(body=body):
                self.notes.write_text(body, encoding="utf-8")
                with self.assertRaises(ValueError):
                    release.release_notes_path(self.version)
        self.notes.unlink()
        with self.assertRaises(ValueError):
            release.release_notes_path(self.version)

    def test_new_release_and_draft_retry_publish_written_notes(self):
        for metadata in [None, {"draft": True}]:
            with self.subTest(metadata=metadata), \
                 patch("sys.argv", ["release.py", "publish"]), \
                 patch.object(release, "check_latest"), \
                 patch.object(release, "release_metadata", return_value=metadata), \
                 patch.object(release, "published_checksum", return_value="a" * 64), \
                 patch.object(release.subprocess, "run", return_value=Mock(returncode=1)), \
                 patch.object(release.subprocess, "check_output", return_value="head\n"), \
                 patch.object(release, "gh") as gh:
                release.main()
                calls = [call.args for call in gh.call_args_list]
                self.assertEqual(calls[0][:2], ("release", "create" if metadata is None else "edit"))
                self.assertEqual(calls[0][-2:], ("--notes-file", str(self.notes)))
                self.assertFalse(any("--generate-notes" in call for call in calls))
                self.assertIn("--draft=false", calls[-1])
                self.assertEqual(self.notes.read_text(encoding="utf-8"), self.body)

    def test_missing_notes_stop_prepare_and_publish_before_mutation(self):
        self.notes.unlink()
        for mode in ["prepare", "publish"]:
            with self.subTest(mode=mode), \
                 patch("sys.argv", ["release.py", mode]), \
                 patch.object(release, "check_latest"), \
                 patch.object(release, "release_metadata", return_value=None), \
                 patch.object(release, "gh") as gh:
                with self.assertRaises(ValueError):
                    release.main()
                gh.assert_not_called()


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.cask = ('cask "everything" do\n  version "0.1.48"\n'
                     f'  sha256 "{"a" * 64}"\n'
                     f'  url "{release.DOWNLOAD_ROOT}/v#{{version}}/EverythingMac-#{{version}}-arm64.dmg"\n'
                     f'  homepage "https://github.com/{release.REPOSITORY}"\n'
                     '  name "EverythingMac"\n  app "EverythingMac.app"\nend\n')

    def test_update_preserves_app_and_url(self):
        result = release.update_cask(self.cask, "0.1.49", "b" * 64)
        self.assertEqual(result, self.cask.replace('"0.1.48"', '"0.1.49"').replace("a" * 64, "b" * 64))

    def test_current_release_names(self):
        self.assertEqual(release.asset_name("0.1.49"), "EverythingMac-0.1.49-arm64.dmg")
        result = release.update_cask(self.cask, "0.1.49", "b" * 64)
        self.assertIn('cask "everything" do', result)
        self.assertIn('app "EverythingMac.app"', result)

    def test_rejects_old_app_and_repository(self):
        for source in [self.cask.replace('EverythingMac.app', 'Other.app'),
                       self.cask.replace(release.REPOSITORY, 'seedds/everything_mac_native')]:
            with self.assertRaises(ValueError):
                release.update_cask(source, "0.1.49", "b" * 64)

    def test_retry_is_idempotent(self):
        result = release.update_cask(self.cask, "0.1.49", "b" * 64)
        self.assertEqual(release.update_cask(result, "0.1.49", "b" * 64), result)

    def test_rejects_downgrade(self):
        with self.assertRaises(ValueError):
            release.update_cask(self.cask, "0.1.47", "b" * 64)

    def test_numeric_version_order(self):
        self.assertGreater(release.version_tuple("0.1.100"), release.version_tuple("0.1.99"))

    def test_rejects_bad_versions(self):
        for value in ["v0.1.49", "01.1.35", "0.1", "0.1.49\nextra", "0.1.49-beta"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                release.version_tuple(value)

    def test_rejects_invalid_checksum(self):
        with self.assertRaises(ValueError):
            release.update_cask(self.cask, "0.1.49", "invalid")

    def test_rejects_wrong_repo_and_duplicate_fields(self):
        for source in [self.cask.replace(release.REPOSITORY, "seedds/unrelated"), self.cask + '  version "0.1.48"\n']:
            with self.assertRaises(ValueError):
                release.update_cask(source, "0.1.49", "b" * 64)

    @patch("release.release_metadata", return_value={"tag_name": "v0.1.50"})
    def test_old_workflow_cannot_replace_latest(self, _metadata):
        with self.assertRaises(ValueError):
            release.check_latest("0.1.49")


if __name__ == "__main__":
    unittest.main()
