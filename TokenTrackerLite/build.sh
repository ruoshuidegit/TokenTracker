#!/bin/bash
set -euo pipefail

LITE_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="$LITE_DIR/dist/TokenTracker Lite.app"
RESOURCES="$APP_PATH/Contents/Resources"
NODE_BINARY="$(python3 "$LITE_DIR/prepare-node.py")"

"$NODE_BINARY" --no-warnings -e '
  if (!require("node:sqlite").DatabaseSync) process.exit(1);
  if (Number(process.versions.node.split(".")[0]) < 22) process.exit(1);
'

mkdir -p "$APP_PATH/Contents/MacOS" "$RESOURCES/TokenTrackerLite" "$LITE_DIR/.build"
swiftc -O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$LITE_DIR/.build/module-cache" \
  -framework AppKit -framework Security "$LITE_DIR/TokenTrackerLite.swift" "$LITE_DIR/TopAPI.swift" "$LITE_DIR/TopAPICycle.swift" \
  -o "$APP_PATH/Contents/MacOS/TokenTrackerLite"

install -m 755 "$NODE_BINARY" "$RESOURCES/node"
cp "$LITE_DIR/queue-store.cjs" "$RESOURCES/TokenTrackerLite/queue-store.cjs"
cp "$LITE_DIR/local-collect.cjs" "$RESOURCES/TokenTrackerLite/local-collect.cjs"
cp "$LITE_DIR/antigravity-attribution.cjs" "$RESOURCES/TokenTrackerLite/antigravity-attribution.cjs"
cp "$LITE_DIR/antigravity-read-view.cjs" "$RESOURCES/TokenTrackerLite/antigravity-read-view.cjs"
cp "$LITE_DIR/lite-pricing.cjs" "$LITE_DIR/lite-pricing.json" "$RESOURCES/TokenTrackerLite/"
cp "$LITE_DIR/../TokenTrackerBar/TokenTrackerBar/AppIcon.icns" "$RESOURCES/AppIcon.icns"
"$NODE_BINARY" "$LITE_DIR/bundle-runtime.cjs" "$RESOURCES"

NODE_LICENSE=""
for CANDIDATE in "$(dirname "$NODE_BINARY")/../LICENSE"; do
  if [[ -f "$CANDIDATE" ]]; then
    NODE_LICENSE="$CANDIDATE"
    break
  fi
done
if [[ -z "$NODE_LICENSE" ]]; then
  echo "缺少 Node.js 许可证，请重新获取官方运行时。" >&2
  exit 1
fi
cp "$NODE_LICENSE" "$RESOURCES/NODE_LICENSE"

cat > "$APP_PATH/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.tokentracker.lite</string>
  <key>CFBundleName</key><string>TokenTracker Lite</string>
  <key>CFBundleDisplayName</key><string>TokenTracker Lite</string>
  <key>CFBundleExecutable</key><string>TokenTrackerLite</string>
  <key>CFBundleIconFile</key><string>AppIcon.icns</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.2.0</string>
  <key>CFBundleVersion</key><string>21</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Based on TokenTracker © 2026 xiufengsun, MIT License</string>
</dict></plist>
PLIST

codesign --force --sign - "$RESOURCES/node"
codesign --force --sign - "$APP_PATH"
codesign --verify --strict "$APP_PATH"
python3 "$LITE_DIR/verify-bundle.py"
echo "构建完成：$APP_PATH"
