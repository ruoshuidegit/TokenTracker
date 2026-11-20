#!/bin/bash
set -euo pipefail

LITE_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="$LITE_DIR/dist/TokenTracker Lite.app"
TOOLS_DIR="$LITE_DIR/.build/dmg-tools"
BACKGROUND="$LITE_DIR/../TokenTrackerBar/scripts/dmg-background.png"

if [[ ! -d "$APP_PATH" ]]; then
  bash "$LITE_DIR/build.sh"
fi
codesign --verify --deep --strict "$APP_PATH"
python3 "$LITE_DIR/verify-bundle.py"

if [[ ! -x "$TOOLS_DIR/bin/python" ]]; then
  python3 -m venv "$TOOLS_DIR"
fi
if ! "$TOOLS_DIR/bin/python" -c 'import dmgbuild' 2>/dev/null; then
  "$TOOLS_DIR/bin/python" -m pip install --disable-pip-version-check \
    dmgbuild==1.6.7 ds_store==1.3.3 mac_alias==2.2.3
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
ARCHITECTURE="$(lipo -archs "$APP_PATH/Contents/MacOS/TokenTrackerLite")"
DMG_PATH="$LITE_DIR/dist/TokenTracker-Lite-$VERSION-macOS-$ARCHITECTURE.dmg"

"$TOOLS_DIR/bin/dmgbuild" -s "$LITE_DIR/dmg-settings.py" \
  -D "app=$APP_PATH" -D "background=$BACKGROUND" \
  "TokenTracker Lite" "$DMG_PATH"

codesign --force --sign - "$DMG_PATH"
codesign --verify --strict "$DMG_PATH"
hdiutil verify -quiet "$DMG_PATH"
"$TOOLS_DIR/bin/python" "$LITE_DIR/verify-dmg.py" "$DMG_PATH"
echo "安装包已生成：$DMG_PATH"
