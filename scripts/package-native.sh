#!/bin/bash
set -euo pipefail
PROTOTYPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(cat "$PROTOTYPE_DIR/VERSION")"
ARCH="$(uname -m)"
"$PROTOTYPE_DIR/run.sh" --build-only
STAGE_DIR="$(mktemp -d "$PROTOTYPE_DIR/build/dmg.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
cp -R "$PROTOTYPE_DIR/build/EverythingMac.app" "$STAGE_DIR/EverythingMac.app"
ln -s /Applications "$STAGE_DIR/Applications"
hdiutil create -volname "EverythingMac" -srcfolder "$STAGE_DIR" -ov -format UDZO "$PROTOTYPE_DIR/build/EverythingMac-${VERSION}-${ARCH}.dmg"
shasum -a 256 "$PROTOTYPE_DIR/build/EverythingMac-${VERSION}-${ARCH}.dmg"
