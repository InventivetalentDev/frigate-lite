#!/bin/sh
# Builds build/FrigateLite.app (release, ad-hoc signed).
set -eu
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/FrigateLite"

APP=build/FrigateLite.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/FrigateLite"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP" >/dev/null

echo "Built $APP"
echo "Run:     open $APP"
echo "Install: cp -R $APP /Applications/"
