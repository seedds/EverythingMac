#!/bin/bash
set -euo pipefail
PROTOTYPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(cat "$PROTOTYPE_DIR/VERSION")"
ARCH="$(uname -m)"
"$PROTOTYPE_DIR/run.sh" --build-only
STAGE_DIR="$(mktemp -d "$PROTOTYPE_DIR/build/dmg.XXXXXX")"
trap 'rm -rf "$STAGE_DIR"' EXIT
cp -R "$PROTOTYPE_DIR/build/Cardinal Native.app" "$STAGE_DIR/Cardinal Native.app"
ln -s /Applications "$STAGE_DIR/Applications"
hdiutil create -volname "Cardinal Native" -srcfolder "$STAGE_DIR" -ov -format UDZO "$PROTOTYPE_DIR/build/Cardinal-Native-${VERSION}-${ARCH}.dmg"
shasum -a 256 "$PROTOTYPE_DIR/build/Cardinal-Native-${VERSION}-${ARCH}.dmg"
