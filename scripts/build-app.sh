#!/bin/bash
# Build "Claude Desktop Swap.app" (menu bar app + cdswap CLI inside) and a
# zip for GitHub releases. Universal (Apple silicon + Intel), ad-hoc signed.
#
#   scripts/build-app.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-0.1.0}"
APP="dist/Claude Desktop Swap.app"
BUNDLE_ID="io.github.abi98213.ClaudeDesktopSwap"

swift build -c release --arch arm64 --arch x86_64
BIN=".build/apple/Products/Release"

rm -rf "$APP" dist/*.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ClaudeSwapApp" "$APP/Contents/MacOS/Claude Desktop Swap"
cp "$BIN/cdswap" "$APP/Contents/MacOS/cdswap"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Claude Desktop Swap</string>
  <key>CFBundleDisplayName</key><string>Claude Desktop Swap</string>
  <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
  <key>CFBundleExecutable</key><string>Claude Desktop Swap</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License. Not affiliated with Anthropic.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
codesign --verify --deep "$APP"

# A version-less name keeps releases/latest/download/ClaudeDesktopSwap.zip stable.
(cd dist && ditto -c -k --keepParent "Claude Desktop Swap.app" "ClaudeDesktopSwap.zip")
echo "Built $APP and dist/ClaudeDesktopSwap.zip"
