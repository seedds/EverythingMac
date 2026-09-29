"""Publish a versioned DMG, then derive the tap checksum from the public asset."""

import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
from urllib.request import urlopen

REPOSITORY = "seedds/EverythingMac"
DOWNLOAD_ROOT = f"https://github.com/{REPOSITORY}/releases/download"
RELEASE_NOTES = Path(__file__).resolve().parents[1] / "docs" / "releases"


def version_tuple(version):
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError(f"Invalid release version: {version!r}")
    return tuple(map(int, version.split(".")))


def gh(*args):
    return subprocess.check_output(["gh", *args], text=True).strip()


def release_notes_path(version):
    version_tuple(version)
    path = RELEASE_NOTES / f"{version}.md"
    if not path.is_file():
        raise ValueError(f"Write release notes in {path} before publishing")
    notes = path.read_text(encoding="utf-8").strip()
    if not any(line.strip() and not line.lstrip().startswith("#") for line in notes.splitlines()):
        raise ValueError("Release notes must describe the changes")
    if re.search(r"https?://|\[[^\]]+\]\s*\(|\[[^\]]+\]:", notes, re.IGNORECASE):
        raise ValueError("Release notes must contain the changes as text, without links")
    return path


def release_metadata(tag):
    result = subprocess.run(
        ["gh", "api", f"repos/{REPOSITORY}/releases/{tag}"],
        capture_output=True, text=True,
    )
    if result.returncode:
        if "(HTTP 404)" in result.stderr:
            return None
        raise RuntimeError(result.stderr)
    return json.loads(result.stdout)


def check_latest(version):
    latest = release_metadata("latest")
    if latest and version_tuple(latest["tag_name"].removeprefix("v")) > version_tuple(version):
        raise ValueError("Refusing to release or sync a version older than the latest release")


def app_name(version):
    return "EverythingMac"


def asset_name(version):
    return f"{app_name(version).replace(' ', '-')}-{version}-arm64.dmg"


def cask_url(version):
    prefix = app_name(version).replace(" ", "-")
    return f"https://github.com/{REPOSITORY}/releases/download/v#{{version}}/{prefix}-#{{version}}-arm64.dmg"


def published_checksum(version):
    metadata = release_metadata(f"tags/v{version}")
    if not metadata or metadata["draft"] or metadata["prerelease"]:
        raise ValueError("Expected a published stable release before updating Homebrew")
    name = asset_name(version)
    asset = next((asset for asset in metadata["assets"] if asset["name"] == name), None)
    url = f"{DOWNLOAD_ROOT}/v{version}/{name}"
    if not asset or asset["browser_download_url"] != url:
        raise ValueError("Release is missing the expected DMG asset")
    digest = hashlib.sha256()
    size = 0
    with urlopen(url, timeout=120) as response:
        while chunk := response.read(1024 * 1024):
            digest.update(chunk)
            size += len(chunk)
    checksum = digest.hexdigest()
    if size == 0 or size != asset["size"]:
        raise ValueError("Downloaded DMG size does not match the release asset")
    if asset.get("digest") and asset["digest"] != f"sha256:{checksum}":
        raise ValueError("Downloaded DMG checksum does not match GitHub's asset digest")
    return checksum


def update_cask(source, version, checksum):
    version_tuple(version)
    if not re.fullmatch(r"[0-9a-f]{64}", checksum):
        raise ValueError("Invalid SHA256 checksum")
    versions = re.findall(r'^  version "([^"]+)"$', source, re.MULTILINE)
    hashes = re.findall(r'^  sha256 "([^"]+)"$', source, re.MULTILINE)
    if len(versions) != 1 or len(hashes) != 1:
        raise ValueError("Expected exactly one cask version and checksum")
    if version_tuple(versions[0]) > version_tuple(version):
        raise ValueError("Refusing to downgrade the Homebrew cask")
    old_name = app_name(versions[0])
    fields = {
        "url": [cask_url(versions[0])],
        "homepage": [f"https://github.com/{REPOSITORY}"],
        "name": [old_name], "app": [f"{old_name}.app"],
    }
    for field, expected in fields.items():
        values = re.findall(rf'^  {field} "([^\"]+)"$', source, re.MULTILINE)
        if len(values) != 1 or values[0] not in expected:
            raise ValueError(f"Cask {field} does not match this repository's release")
    replacements = {
        "version": version, "sha256": checksum, "url": cask_url(version),
        "name": app_name(version), "app": f"{app_name(version)}.app",
        "homepage": f"https://github.com/{REPOSITORY}",
    }
    for field, value in replacements.items():
        source = re.sub(rf'^  {field} "[^\"]+"$', f'  {field} "{value}"', source, flags=re.MULTILINE)
    return source


def main():
    mode = sys.argv[1]
    version = Path("VERSION").read_text().strip()
    version_tuple(version)
    check_latest(version)
    tag = f"v{version}"
    metadata = release_metadata(f"tags/{tag}")
    published = metadata is not None and not metadata["draft"]
    if mode == "prepare":
        if not published:
            release_notes_path(version)
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write(f"version={version}\npublished={str(published).lower()}\n")
    elif mode == "publish":
        if not published:
            notes = str(release_notes_path(version))
            # A draft can be retried, but its tag must still represent these sources.
            existing_tag = subprocess.run(["git", "rev-parse", f"refs/tags/{tag}^{{commit}}"], capture_output=True, text=True)
            head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
            if existing_tag.returncode == 0 and existing_tag.stdout.strip() != head:
                raise ValueError("Existing tag does not point to the checked-out source")
            if not metadata:
                gh("release", "create", tag, "--repo", REPOSITORY, "--draft", "--target", head,
                   "--title", f"{app_name(version)} {version}", "--notes-file", notes)
            else:
                gh("release", "edit", tag, "--repo", REPOSITORY, "--notes-file", notes)
            gh("release", "upload", tag, f"build/{asset_name(version)}", "--repo", REPOSITORY, "--clobber")
            gh("release", "edit", tag, "--repo", REPOSITORY, "--draft=false", "--latest")
        checksum = published_checksum(version)
        print(f"Published {tag}: SHA256 {checksum}")
    elif mode == "sync-tap":
        if os.environ["RELEASE_VERSION"] != version:
            raise ValueError("Build and tap update versions differ")
        checksum = published_checksum(version)
        path = Path(sys.argv[2])
        path.write_text(update_cask(path.read_text(), version, checksum))
        print(f"Homebrew {version}: SHA256 {checksum}")
    else:
        raise ValueError(f"Unknown release operation: {mode}")


if __name__ == "__main__":
    main()
