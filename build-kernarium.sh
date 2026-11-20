#!/bin/bash
# OpenCode Kernarium-engine iOS build WITH the Kernarium runtime
# (macOS, Xcode 27, iPhoneOS SDK). Used by
# .github/workflows/build-kernarium.yml; also runnable by hand on a Mac
# with Xcode 27 installed.
#
#   ./build-kernarium.sh [KERNARIUM_DIR] [FRAMEWORKS_DIR]
#
#   KERNARIUM_DIR   Kernarium checkout at pinned commit fbe12ee
#                   (default: ./kernarium). Used only to locate the
#                   packaged frameworks; the runtime itself is NOT
#                   compiled here.
#   FRAMEWORKS_DIR  dir holding KRuntime_6_18_4K.framework, built on
#                   the Mac by the Kernarium runtime-tree CMake build
#                   (cmake --preset kernarium-ios-device in the
#                   kernarium-engine workflow; see
#                   .github/workflows/build-kernarium.yml). The
#                   upstream packaging script
#                   (Kernarium/scripts/package-ios-frameworks.sh) is
#                   deliberately NOT used: it demands the Android
#                   runtime too and only verifies prebuilt artifacts.
#                   The three GPU frameworks (KosmicKrisp, MesaEGL,
#                   MesaGallium) come from Frameworks/ in this repo,
#                   vendored from the Andarium release IPA (as in
#                   TermX); the Linux runtime loads the same three.
#
# Produces build/OpenCode-Inbuilt.ipa, adhoc signed. -Wall -Wextra,
# zero warnings required for the app's own ObjC (same rule as
# build.sh). MinOS is 27.0: the embedded Kernarium frameworks
# declare MinimumOSVersion 27.0.
#
# This script assumes nothing about this Linux VM: no ~/workspace
# paths, no Linux SDK, no clang-18. Everything comes from xcrun.
set -e
cd "$(dirname "$0")"

KERNARIUM_DIR="${1:-./kernarium}"
FRAMEWORKS_DIR="${2:-./kernarium-frameworks}"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CLANG="$(xcrun --sdk iphoneos -f clang)"
MIN=27.0
SRC=src
OUT=build
APP=$OUT/Payload/OpenCode.app

# The framework the runtime-tree CMake build writes. The build's
# output dir is .build/kernarium-runtime-ios-device under the
# checkout; KRuntime_6_18_4K.framework sits directly in
# Kernarium/Runtime/ (that is exactly the slice the upstream
# packaging script consumes as its input). The two xcframework
# candidates below are kept for a hand-built framework dir.
KRUNTIME=""
for cand in \
  "$FRAMEWORKS_DIR/KRuntime_6_18_4K.framework" \
  "$KERNARIUM_DIR/.build/kernarium-xcframeworks/KRuntime_6_18_4K.xcframework/ios-arm64/KRuntime_6_18_4K.framework" \
  "$KERNARIUM_DIR/.build/kernarium-xcframeworks/KRuntime_6_18_4K.framework"; do
  if [ -d "$cand" ]; then KRUNTIME="$cand"; break; fi
done
if [ -z "$KRUNTIME" ]; then
  echo "missing KRuntime_6_18_4K.framework" >&2
  echo "Build it on this Mac first (see .github/workflows/build-kernarium.yml):" >&2
  echo "  cd $KERNARIUM_DIR" >&2
  echo "  cmake --preset kernarium-ios-device && cmake --build --preset kernarium-ios-device" >&2
  echo "then re-run with the runtime dir as the 2nd argument." >&2
  exit 1
fi
for f in Frameworks/KosmicKrisp.framework Frameworks/MesaEGL.framework Frameworks/MesaGallium.framework; do
  if [ ! -d "$f" ]; then echo "missing vendored GPU framework: $f" >&2; exit 1; fi
done

rm -rf "$OUT"
mkdir -p "$APP/Frameworks"

OCFLAGS="-target arm64-apple-ios$MIN -isysroot $SDK -miphoneos-version-min=$MIN -fobjc-arc -O2 -Wall -Wextra -Wno-deprecated-declarations -DOC_KERNARIUM_LINKED=1 -I$SRC -F$SDK/System/Library/SubFrameworks -F$SDK/System/Library/PrivateFrameworks"

# App sources (same list as build.sh) plus the Kernarium glue.
for f in main AppDelegate OCKeychain OCUtil OCSettings OCServerClient OCEngine OCCrashLog OCSessionsViewController OCChatViewController OCFilesViewController OCEngineViewController OCSettingsViewController OCIntegrationsViewController OCBrowserViewController OCCodeViewController OCStartupViewController OCDesktopViewController KernGlue OCVsockBridge OCGuestInstall; do
  echo "== $f.m"
  $CLANG $OCFLAGS -c "$SRC/$f.m" -o "$OUT/$f.o"
done

echo "== link"
# The four Kernarium frameworks are NOT linked at all — no -framework
# and no -weak_framework flags. Weak linking was tried first (4ee90bc)
# and still crashed at launch in LiveContainer: dyld loads weak
# frameworks at launch too, and one unloadable framework kills the
# launch before any app code runs, with no log at all. The old
# working build had no dyld-loaded frameworks (core statically
# linked). KernGlue loads KRuntime by path with dlopen + dlsym on
# first Start (src/KernGlue.m loadRuntime), and the app references
# no framework symbol directly, so dropping the flags changes
# nothing in the standalone path. The frameworks are still copied
# into Payload/Frameworks below.
KRUNTIME_DIR="$(dirname "$KRUNTIME")"
$CLANG -target arm64-apple-ios$MIN -isysroot "$SDK" -miphoneos-version-min=$MIN \
  -ObjC -Wl,-dead_strip \
  -F"$KRUNTIME_DIR" -F"Frameworks" \
  -rpath @executable_path/Frameworks \
  "$OUT"/main.o "$OUT"/AppDelegate.o "$OUT"/OCKeychain.o "$OUT"/OCUtil.o "$OUT"/OCSettings.o "$OUT"/OCServerClient.o "$OUT"/OCEngine.o "$OUT"/OCCrashLog.o "$OUT"/OCSessionsViewController.o "$OUT"/OCChatViewController.o "$OUT"/OCFilesViewController.o "$OUT"/OCEngineViewController.o "$OUT"/OCSettingsViewController.o "$OUT"/OCIntegrationsViewController.o "$OUT"/OCBrowserViewController.o "$OUT"/OCCodeViewController.o "$OUT"/OCStartupViewController.o "$OUT"/OCDesktopViewController.o "$OUT"/KernGlue.o "$OUT"/OCVsockBridge.o "$OUT"/OCGuestInstall.o \
  -framework UIKit -framework Foundation -framework Security -framework CoreGraphics -framework QuartzCore -framework WebKit -framework Metal -framework MetalKit -framework CoreLocation \
  -lobjc -lSystem -lz \
  -o "$APP/OpenCode"

cp "$SRC/Info.plist" "$APP/Info.plist"
for ic in AppIcon60x60@2x.png AppIcon60x60@3x.png AppIcon76x76@2x.png AppIcon1024.png; do
  cp "resources/icons/$ic" "$APP/$ic"
done
printf 'APPL????' > "$APP/PkgInfo"

# Embed the runtime framework and the GPU frameworks it loads.
cp -r "$KRUNTIME" "$APP/Frameworks/"
cp -r Frameworks/KosmicKrisp.framework Frameworks/MesaEGL.framework Frameworks/MesaGallium.framework "$APP/Frameworks/"
# Drop any prebuilt code signature: the installer re-signs everything anyway.
find "$APP/Frameworks" -name _CodeSignature -type d -exec rm -rf {} + 2>/dev/null || true

codesign --force --sign - --timestamp=none "$APP/OpenCode"

cd "$OUT"
rm -f OpenCode-Inbuilt.ipa
zip -qry OpenCode-Inbuilt.ipa Payload
ls -lh OpenCode-Inbuilt.ipa
shasum -a 256 OpenCode-Inbuilt.ipa
