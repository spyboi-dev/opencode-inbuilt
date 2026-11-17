#!/bin/bash
# OpenCode inbuilt-engine iOS build WITH the LinuxRunner core linked
# (macOS, Xcode 26, iPhoneOS SDK). Used by .github/workflows/build-core.yml;
# also runnable by hand on a Mac with Xcode 26 installed.
#
#   ./build-core.sh [LINUXRUNNER_DIR] [CORE_DIR] [LIBARCHIVE_A]
#
#   LINUXRUNNER_DIR  LinuxRunner 1.1.2 checkout (default: ./linuxrunner)
#   CORE_DIR         dir with libish.a libish_emu.a libfakefs.a from the
#                    meson cross build (default: ./core-build)
#   LIBARCHIVE_A     path to libarchive.a built for iphoneos
#                    (default: ./libarchive-build/libarchive.a)
#
# Produces build/OpenCode-Inbuilt.ipa, adhoc signed. -Wall -Wextra,
# zero warnings required for the app's own ObjC (same rule as build.sh);
# the two upstream C files (DebianBootstrap.c, fakefs.c) are compiled
# with -Wall only, since they are not ours.
#
# This script assumes nothing about this Linux VM: no ~/workspace
# paths, no Linux SDK, no clang-18. Everything comes from xcrun.
set -e
cd "$(dirname "$0")"

LINUXRUNNER_DIR="${1:-./linuxrunner}"
CORE_DIR="${2:-./core-build}"
LIBARCHIVE_A="${3:-./libarchive-build/libarchive.a}"
LIBARCHIVE_SRC="$LINUXRUNNER_DIR/deps/libarchive"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos -f clang)"
MIN=15.0
SRC=src
OUT=build
APP=$OUT/Payload/OpenCode.app

for f in "$CORE_DIR/libish.a" "$CORE_DIR/libish_emu.a" "$CORE_DIR/libfakefs.a" "$LIBARCHIVE_A"; do
  if [ ! -f "$f" ]; then echo "missing input: $f" >&2; exit 1; fi
done
if [ ! -d "$LINUXRUNNER_DIR" ]; then echo "missing LinuxRunner checkout: $LINUXRUNNER_DIR" >&2; exit 1; fi

rm -rf "$OUT"
mkdir -p "$APP"

OCFLAGS="-target arm64-apple-ios$MIN -isysroot $SDK -miphoneos-version-min=$MIN -fobjc-arc -O2 -Wall -Wextra -Wno-deprecated-declarations -DOC_CORE_LINKED=1 -DLINUXRUNNER=1 -DGUEST_ARM64=1 -I$LINUXRUNNER_DIR -I$LIBARCHIVE_SRC/libarchive"
CFLAGS_C="-target arm64-apple-ios$MIN -isysroot $SDK -miphoneos-version-min=$MIN -O2 -Wall -DLINUXRUNNER=1 -DGUEST_ARM64=1 -I$LINUXRUNNER_DIR -I$LIBARCHIVE_SRC/libarchive"

# App sources (same list as build.sh) plus the core glue.
for f in main AppDelegate OCKeychain OCUtil OCSettings OCServerClient OCEngine OCSessionsViewController OCChatViewController OCFilesViewController OCEngineViewController OCSettingsViewController OCIntegrationsViewController OCBrowserViewController CoreGlue; do
  echo "== $f.m"
  $CLANG $OCFLAGS -c "$SRC/$f.m" -o "$OUT/$f.o"
done

# Upstream C files the glue needs: Debian .deb -> guest tar, and
# guest tar -> fakefs import. Both need libarchive headers.
echo "== DebianBootstrap.c"
$CLANG $CFLAGS_C -c "$LINUXRUNNER_DIR/app/LinuxRunner/DebianBootstrap.c" -o "$OUT/DebianBootstrap.o"
echo "== fakefs.c"
$CLANG $CFLAGS_C -c "$LINUXRUNNER_DIR/tools/fakefs.c" -o "$OUT/fakefs.o"

echo "== link"
$CLANG -target arm64-apple-ios$MIN -isysroot "$SDK" -miphoneos-version-min=$MIN \
  -ObjC -Wl,-dead_strip \
  "$OUT"/main.o "$OUT"/AppDelegate.o "$OUT"/OCKeychain.o "$OUT"/OCUtil.o "$OUT"/OCSettings.o "$OUT"/OCServerClient.o "$OUT"/OCEngine.o "$OUT"/OCSessionsViewController.o "$OUT"/OCChatViewController.o "$OUT"/OCFilesViewController.o "$OUT"/OCEngineViewController.o "$OUT"/OCSettingsViewController.o "$OUT"/OCIntegrationsViewController.o "$OUT"/OCBrowserViewController.o "$OUT"/CoreGlue.o "$OUT"/DebianBootstrap.o "$OUT"/fakefs.o \
  "$CORE_DIR/libish.a" "$CORE_DIR/libish_emu.a" "$CORE_DIR/libfakefs.a" "$LIBARCHIVE_A" \
  -framework UIKit -framework Foundation -framework Security -framework CoreGraphics -framework QuartzCore -framework WebKit \
  -lobjc -lSystem -lsqlite3 -lz -lbz2 -llzma -liconv -lresolv -lm \
  -o "$APP/OpenCode"

cp "$SRC/Info.plist" "$APP/Info.plist"
cp resources/debian-manifest.json "$APP/debian-manifest.json"
for ic in AppIcon60x60@2x.png AppIcon60x60@3x.png AppIcon76x76@2x.png AppIcon1024.png; do
  cp "resources/icons/$ic" "$APP/$ic"
done
printf 'APPL????' > "$APP/PkgInfo"

codesign --force --sign - --timestamp=none "$APP/OpenCode"

cd "$OUT"
rm -f OpenCode-Inbuilt.ipa
zip -qry OpenCode-Inbuilt.ipa Payload
ls -lh OpenCode-Inbuilt.ipa
shasum -a 256 OpenCode-Inbuilt.ipa
