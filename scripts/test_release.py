import unittest
from unittest.mock import patch

import release


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
