import unittest
from unittest.mock import patch

import release


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.cask = ('cask "cardinal" do\n  version "0.1.34"\n'
                     f'  sha256 "{"a" * 64}"\n'
                     f'  url "{release.DOWNLOAD_ROOT}/v#{{version}}/Cardinal-Native-#{{version}}-arm64.dmg"\n'
                     '  name "Cardinal Native"\n  app "Cardinal Native.app"\nend\n')

    def test_update_preserves_app_and_url(self):
        result = release.update_cask(self.cask, "0.1.35", "b" * 64)
        self.assertEqual(result, self.cask.replace('"0.1.34"', '"0.1.35"').replace("a" * 64, "b" * 64))

    def test_rename_migrates_existing_cask_and_preserves_token(self):
        old = self.cask.replace('"0.1.34"', '"0.1.42"')
        result = release.update_cask(old, "0.1.43", "b" * 64)
        self.assertIn('cask "cardinal" do', result)
        self.assertIn('name "EverythingMac"', result)
        self.assertIn('app "EverythingMac.app"', result)
        self.assertIn('/EverythingMac-#{version}-arm64.dmg', result)
        self.assertNotIn('Cardinal Native', result)
        self.assertEqual(release.update_cask(result, "0.1.43", "b" * 64), result)
        self.assertIn('version "0.1.44"', release.update_cask(result, "0.1.44", "c" * 64))

    def test_release_asset_names_before_and_after_rename(self):
        self.assertEqual(release.asset_name("0.1.42"), "Cardinal-Native-0.1.42-arm64.dmg")
        self.assertEqual(release.asset_name("0.1.43"), "EverythingMac-0.1.43-arm64.dmg")

    def test_wrong_app_cannot_be_silently_migrated(self):
        with self.assertRaises(ValueError):
            release.update_cask(self.cask.replace('app "Cardinal Native.app"', 'app "Other.app"'),
                                "0.1.43", "b" * 64)

    def test_retry_is_idempotent(self):
        result = release.update_cask(self.cask, "0.1.35", "b" * 64)
        self.assertEqual(release.update_cask(result, "0.1.35", "b" * 64), result)

    def test_rejects_downgrade(self):
        with self.assertRaises(ValueError):
            release.update_cask(self.cask, "0.1.33", "b" * 64)

    def test_numeric_version_order(self):
        self.assertGreater(release.version_tuple("0.1.100"), release.version_tuple("0.1.99"))

    def test_rejects_bad_versions(self):
        for value in ["v0.1.35", "01.1.35", "0.1", "0.1.35\nextra", "0.1.35-beta"]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                release.version_tuple(value)

    def test_rejects_invalid_checksum(self):
        with self.assertRaises(ValueError):
            release.update_cask(self.cask, "0.1.35", "invalid")

    def test_rejects_wrong_repo_and_duplicate_fields(self):
        for source in [self.cask.replace("cardinal_native", "cardinal"), self.cask + '  version "0.1.34"\n']:
            with self.assertRaises(ValueError):
                release.update_cask(source, "0.1.35", "b" * 64)

    @patch("release.release_metadata", return_value={"tag_name": "v0.1.36"})
    def test_old_workflow_cannot_replace_latest(self, _metadata):
        with self.assertRaises(ValueError):
            release.check_latest("0.1.35")


if __name__ == "__main__":
    unittest.main()
