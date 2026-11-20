#!/bin/bash
# OpenCode inbuilt-engine iOS build (Linux, clang-18 + ld64.lld-18, iPhoneOS 26.5 SDK).
# Same workflow as SPYTube iOS (~/workspace/spytube-ios/native/build26.sh).
# -Wall -Wextra, zero warnings required (see BUILD-NOTE.md bug pass).
set -e
cd "$(dirname "$0")"
SDK="$HOME/workspace/spytube-ios/sdks/iPhoneOS26.5.sdk"
SRC=src
OUT=build
APP=$OUT/Payload/OpenCode.app
MIN=15.0

rm -rf "$OUT"
mkdir -p "$APP"

CLANG=clang-18
CFLAGS="-target arm64-apple-ios$MIN -isysroot $SDK -miphoneos-version-min=$MIN -fobjc-arc -O2 -Wall -Wextra -Wno-deprecated-declarations -F$SDK/System/Library/SubFrameworks -F$SDK/System/Library/PrivateFrameworks"

for f in main AppDelegate OCKeychain OCUtil OCSettings OCServerClient OCEngine OCSessionsViewController OCChatViewController OCFilesViewController OCEngineViewController OCSettingsViewController OCIntegrationsViewController OCBrowserViewController OCCodeViewController OCStartupViewController; do
  echo "== $f.m"
  $CLANG $CFLAGS -c "$SRC/$f.m" -o "$OUT/$f.o"
done

echo "== link"
ld64.lld-18 -arch arm64 -platform_version ios $MIN 26.5 \
  -syslibroot "$SDK" \
  -F"$SDK/System/Library/Frameworks" -F"$SDK/System/Library/SubFrameworks" -F"$SDK/System/Library/PrivateFrameworks" \
  -L"$SDK/usr/lib" \
  -adhoc_codesign -ObjC -dead_strip \
  "$OUT"/main.o "$OUT"/AppDelegate.o "$OUT"/OCKeychain.o "$OUT"/OCUtil.o "$OUT"/OCSettings.o "$OUT"/OCServerClient.o "$OUT"/OCEngine.o "$OUT"/OCSessionsViewController.o "$OUT"/OCChatViewController.o "$OUT"/OCFilesViewController.o "$OUT"/OCEngineViewController.o "$OUT"/OCSettingsViewController.o "$OUT"/OCIntegrationsViewController.o "$OUT"/OCBrowserViewController.o "$OUT"/OCCodeViewController.o "$OUT"/OCStartupViewController.o \
  -framework UIKit -framework Foundation -framework Security -framework CoreGraphics -framework QuartzCore -framework WebKit \
  -lobjc -lSystem \
  -o "$APP/OpenCode"

cp "$SRC/Info.plist" "$APP/Info.plist"
cp resources/debian-manifest.json "$APP/debian-manifest.json"
OLD="$HOME/workspace/spytube-ios/native/build/Payload/SPYTube.app"
ICONS_DIR="resources/icons"
[ -f "$ICONS_DIR/AppIcon1024.png" ] || ICONS_DIR="$OLD"
for ic in AppIcon60x60@2x.png AppIcon60x60@3x.png AppIcon76x76@2x.png AppIcon1024.png; do
  cp "$ICONS_DIR/$ic" "$APP/$ic"
done
printf 'APPL????' > "$APP/PkgInfo"

cd "$OUT"
rm -f OpenCode-Inbuilt.ipa
zip -qry OpenCode-Inbuilt.ipa Payload
ls -lh OpenCode-Inbuilt.ipa
sha256sum OpenCode-Inbuilt.ipa
