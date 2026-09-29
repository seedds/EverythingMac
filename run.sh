#!/bin/bash
set -euo pipefail
PROTOTYPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$PROTOTYPE_DIR"
VERSION="$(cat "$REPO_DIR/VERSION")"
export PATH="$HOME/.cargo/bin:$PATH"
export RUSTC="$HOME/.cargo/bin/rustc"
export CARGO_PROFILE_RELEASE_STRIP=none
export MACOSX_DEPLOYMENT_TARGET=14.0
cd "$REPO_DIR"
cargo build --locked --release -p everything-mac-native-prototype
cd "$PROTOTYPE_DIR"
# Keep compiler products outside Documents: dsymutil inspects ancestor bundles,
# which can block on macOS folder-access prompts unrelated to this repository.
BUILD_KEY="$(printf '%s' "$PROTOTYPE_DIR" | shasum | cut -c1-12)"
SWIFT_BUILD_DIR="${EVERYTHING_MAC_SWIFT_BUILD_DIR:-/private/tmp/everything-mac-native-${UID}-${BUILD_KEY}}"
export CLANG_MODULE_CACHE_PATH="$SWIFT_BUILD_DIR/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$SWIFT_BUILD_DIR/swift-module-cache"
swift build -c release --disable-sandbox --scratch-path "$SWIFT_BUILD_DIR" --cache-path "$SWIFT_BUILD_DIR/cache" -Xlinker -L -Xlinker "$REPO_DIR/target/release"
mkdir -p "$PROTOTYPE_DIR/build"
# Icon Services can retain the first launch icon for an in-place bundle, even
# after its resources and registration change. Assemble a fresh bundle identity.
APP_STAGE="$(mktemp -d "$PROTOTYPE_DIR/build/app.XXXXXX")"
trap 'rm -rf "$APP_STAGE"' EXIT
APP="$APP_STAGE/EverythingMac.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SWIFT_BUILD_DIR/release/EverythingMac" "$APP/Contents/MacOS/EverythingMac"
cp "$REPO_DIR/Resources/icon.icns" "$APP/Contents/Resources/icon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.everything.mac</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string></array>
<key>CFBundleName</key><string>EverythingMac</string>
<key>CFBundleDisplayName</key><string>EverythingMac</string>
<key>CFBundleExecutable</key><string>EverythingMac</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>${VERSION}</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleIconFile</key><string>icon.icns</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
rm -rf "$PROTOTYPE_DIR/build/EverythingMac.app"
mv "$APP" "$PROTOTYPE_DIR/build/EverythingMac.app"
rmdir "$APP_STAGE"
trap - EXIT
APP="$PROTOTYPE_DIR/build/EverythingMac.app"
if [[ "${1:-}" == "--build-only" ]]; then
  echo "$APP"
elif [[ "$#" -eq 0 ]]; then
  # Let Launch Services initialize the Dock icon for interactive launches.
  # Direct executable launches can show the unstyled square artwork.
  exec open -n -W "$APP"
else
  # Diagnostics need the executable's stdout and exit status.
  exec "$APP/Contents/MacOS/EverythingMac" "$@"
fi
