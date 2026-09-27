#!/bin/bash
set -euo pipefail
PROTOTYPE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$PROTOTYPE_DIR/build/Cardinal Tauri Baseline.app"
mkdir -p "$APP/Contents/MacOS"
cp "${CARDINAL_TAURI_REPO:-$(dirname "$PROTOTYPE_DIR")/cardinal}/cardinal/src-tauri/target/release/cardinal" "$APP/Contents/MacOS/cardinal"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.cardinal.native-baseline</string>
<key>CFBundleName</key><string>Cardinal Tauri Baseline</string>
<key>CFBundleExecutable</key><string>cardinal</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
