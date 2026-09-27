#!/bin/bash
set -euo pipefail
PROTOTYPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$PROTOTYPE_DIR"
VERSION="$(cat "$REPO_DIR/VERSION")"
export PATH="$HOME/.cargo/bin:$PATH"
export RUSTC="$HOME/.cargo/bin/rustc"
export CARGO_PROFILE_RELEASE_STRIP=none
export MACOSX_DEPLOYMENT_TARGET=12.0
cd "$REPO_DIR"
cargo build --locked --release -p cardinal-native-prototype
cd "$PROTOTYPE_DIR"
# Keep compiler products outside Documents: dsymutil inspects ancestor bundles,
# which can block on macOS folder-access prompts unrelated to this repository.
BUILD_KEY="$(printf '%s' "$PROTOTYPE_DIR" | shasum | cut -c1-12)"
SWIFT_BUILD_DIR="${CARDINAL_SWIFT_BUILD_DIR:-/private/tmp/cardinal-native-${UID}-${BUILD_KEY}}"
export CLANG_MODULE_CACHE_PATH="$SWIFT_BUILD_DIR/clang-module-cache"
export SWIFT_MODULECACHE_PATH="$SWIFT_BUILD_DIR/swift-module-cache"
swift build -c release --disable-sandbox --scratch-path "$SWIFT_BUILD_DIR" --cache-path "$SWIFT_BUILD_DIR/cache" -Xlinker -L -Xlinker "$REPO_DIR/target/release"
APP="$PROTOTYPE_DIR/build/Cardinal Native.app"
# Recreate generated resources so removed assets cannot survive an incremental build.
rm -rf "$APP/Contents/Resources"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$SWIFT_BUILD_DIR/release/CardinalNativePrototype" "$APP/Contents/MacOS/CardinalNativePrototype"
cp "$REPO_DIR/Resources/icon.icns" "$APP/Contents/Resources/icon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.cardinal.native-prototype</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string></array>
<key>CFBundleName</key><string>Cardinal Native</string>
<key>CFBundleExecutable</key><string>CardinalNativePrototype</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>${VERSION}</string>
<key>CFBundleShortVersionString</key><string>${VERSION}</string>
<key>CFBundleIconFile</key><string>icon.icns</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
if [[ "${1:-}" == "--build-only" ]]; then
  echo "$APP"
else
  exec "$APP/Contents/MacOS/CardinalNativePrototype" "$@"
fi
