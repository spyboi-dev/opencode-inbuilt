#!/bin/bash
# OpenCode Kernarium-engine iOS build, LOCAL (Linux, clang-18 + ld64.lld-18,
# iPhoneOS 26.5 SDK). The fast path: the Mac workflow takes 16-35 min per
# run; this builds the same app on this VM in ~1-2 min.
#
#   ./build-local-kernarium.sh
#
# Produces build-local/OpenCode-iOS.ipa, adhoc signed.
# -Wall -Wextra, zero warnings required (same rule as build.sh).
#
# What it is: the local build.sh compile/link recipe (clang-18 +
# ld64.lld-18, the same path SPYTube native, TermX and CrateTerm ship
# with) PLUS the Kernarium bits from build-kernarium.sh:
# -DOC_KERNARIUM_LINKED=1, -DOC_BUILD_ID, -rpath
# @executable_path/Frameworks, and all four frameworks embedded.
#
# What it is NOT: xtool. xtool 1.22.2 was checked (AppImage at
# ~/workspace/tools/xtool, extracted to ~/workspace/tools/xtool-extract):
# its only build path is `xtool dev build`, which builds SwiftPM
# packages. This repo has no Package.swift and no .xcodeproj — it is a
# raw ObjC file list built by shell scripts — so xtool cannot build it
# without authoring a whole SwiftPM wrapper for zero benefit. The
# user's goal is a fast local build, not xtool for its own sake; the
# clang path below already compiles this exact code clean.
#
# Why local builds historically did NOT link the core: nothing about
# the app code or the linker prevented it. The app never links the
# runtime at all — on Mac AND locally it is dlopen-only (KernGlue
# loads KRuntime_6_18_4K.framework by path at first Start; there are
# zero framework load commands either way). What was missing locally
# was (a) the prebuilt KRuntime framework artifact — it is built on
# the Mac by the workflow's CMake runtime-tree build, and upstream's
# CMake refuses non-Apple hosts, so it cannot be rebuilt here — and
# (b) a local script that defines OC_KERNARIUM_LINKED and embeds the
# frameworks (build.sh explicitly does neither; build-kernarium.sh is
# macOS-only via xcrun). This script fixes (b) by reusing the exact
# Mac-built framework (see KRUNTIME below) and (a) is a non-issue:
# the framework only changes when upstream Kernarium changes (pinned
# commit fbe12ee); the app code is what changes per build.
#
# KRUNTIME source: the framework shipped in the Mac-built d6cb75f IPA
# (mac-ipas/OpenCode-Inbuilt-kernarium-d6cb75f.ipa), extracted once into
# a cache dir OUTSIDE the repo and verified by SHA-256 on every use.
# It is NOT the TermX-vendored copy: that one is a different binary
# (SHA fe794cba… vs the Mac build's 74e97d92…, same 52 MB size) built
# from a different provenance, so the Mac one is used to keep device
# behaviour identical to the shipped Mac builds. The three GPU
# frameworks come from Frameworks/ in this repo (the Mac build copies
# those same files, so they are identical by construction).
#
# Safety: OUT is build-local, NEVER build/ — build/ holds Mac IPA
# leftovers and local .o files, and build.sh's `rm -rf build` would
# delete them. mac-ipas/ is only READ (as the KRuntime source) and
# never written. Do not merge this script's output into mac-ipas/.
set -e
cd "$(dirname "$0")"
SDK="$HOME/workspace/spytube-ios/sdks/iPhoneOS26.5.sdk"
SRC=src
OUT=build-local
APP=$OUT/Payload/OpenCode.app
MIN=15.0

# Termx-Kernel fork framework (fork HEAD 962678f49, upstream 9bda5e831,
# runtime API 46, LocalhostProxy, boot-ramdisk persistent-upper patch).
# The old upstream fbe12ee framework stays cached alongside at
# KRuntime_6_18_4K.framework, so the old build stays reproducible.
KRUNTIME_SHA="18275b14a448ebb59d52af6daeeaa0d93c33c82c828d007effac35706a79e978"
KRUNTIME_CACHE_DIR="$HOME/workspace/opencode-local-frameworks"
KRUNTIME_CACHE="$KRUNTIME_CACHE_DIR/KRuntime_6_18_4K-fork-962678f49.framework"
MAC_IPA="mac-ipas/OpenCode-Inbuilt-kernarium-d6cb75f.ipa"
# NOTE: the fallback IPA below holds the OLD fbe12ee framework (API 43);
# extracting from it yields a framework that fails the SHA check above.
# The fork framework lives at ~/workspace/framework-artifacts/KRuntime_6_18_4K.framework
# (workflow artifact KRuntime_6_18_4K from the Termx-Kernel fork build).
# Override to point at a different prebuilt framework, e.g. a fresh
# Mac-workflow one: KRUNTIME_FRAMEWORK=/path/to/KRuntime_6_18_4K.framework
KRUNTIME_FRAMEWORK="${KRUNTIME_FRAMEWORK:-$KRUNTIME_CACHE}"

START="$(date +%s)"
echo "== local Kernarium build (head $(git rev-parse --short HEAD 2>/dev/null || echo nogit))"

[ -d "$SDK" ] || { echo "missing SDK: $SDK" >&2; exit 1; }
command -v clang-18 >/dev/null || { echo "missing clang-18" >&2; exit 1; }
command -v ld64.lld-18 >/dev/null || { echo "missing ld64.lld-18" >&2; exit 1; }
for f in Frameworks/KosmicKrisp.framework Frameworks/MesaEGL.framework Frameworks/MesaGallium.framework; do
  [ -d "$f" ] || { echo "missing vendored GPU framework: $f" >&2; exit 1; }
done

# KRuntime: extract once from the Mac-built IPA, verify the hash.
if [ ! -d "$KRUNTIME_FRAMEWORK" ]; then
  [ -f "$MAC_IPA" ] || {
    echo "missing KRuntime framework and no Mac IPA to extract it from." >&2
    echo "Get one: download the latest kernarium-engine IPA artifact" >&2
    echo "(or copy Frameworks/KRuntime_6_18_4K.framework out of any" >&2
    echo "Mac-built OpenCode Kernarium IPA) and set KRUNTIME_FRAMEWORK." >&2
    exit 1
  }
  echo "== extracting KRuntime from $MAC_IPA"
  mkdir -p "$KRUNTIME_CACHE_DIR"
  TMPD="$(mktemp -d)"
  unzip -q -o "$MAC_IPA" "Payload/OpenCode.app/Frameworks/KRuntime_6_18_4K.framework/*" -d "$TMPD"
  rm -rf "$KRUNTIME_CACHE"
  mv "$TMPD/Payload/OpenCode.app/Frameworks/KRuntime_6_18_4K.framework" "$KRUNTIME_CACHE"
  rm -rf "$TMPD"
fi
GOT_SHA="$(sha256sum "$KRUNTIME_FRAMEWORK/KRuntime_6_18_4K" | awk '{print $1}')"
[ "$GOT_SHA" = "$KRUNTIME_SHA" ] || {
  echo "KRuntime hash mismatch: got $GOT_SHA, want $KRUNTIME_SHA" >&2
  echo "Refusing to embed an unexpected runtime framework." >&2
  exit 1
}
echo "== KRuntime OK (sha256 $KRUNTIME_SHA)"

rm -rf "$OUT"
mkdir -p "$APP/Frameworks"

BUILD_ID="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
CLANG=clang-18
CFLAGS="-target arm64-apple-ios$MIN -isysroot $SDK -miphoneos-version-min=$MIN -fobjc-arc -O2 -Wall -Wextra -Wno-deprecated-declarations -DOC_KERNARIUM_LINKED=1 -DOC_BUILD_ID=\"${BUILD_ID}\" -I$SRC -F$SDK/System/Library/SubFrameworks -F$SDK/System/Library/PrivateFrameworks"

for f in main AppDelegate OCSceneDelegate OCKeychain OCUtil OCSettings OCServerClient OCEngine OCCrashLog OCSessionsViewController OCChatViewController OCFilesViewController OCEngineViewController OCSettingsViewController OCIntegrationsViewController OCBrowserViewController OCCodeViewController OCStartupViewController OCDesktopViewController KernGlue OCVsockBridge OCLocalhostProxy OCGuestInstall; do
  echo "== $f.m"
  $CLANG $CFLAGS -c "$SRC/$f.m" -o "$OUT/$f.o"
done

echo "== link"
ld64.lld-18 -arch arm64 -platform_version ios $MIN 26.5 \
  -syslibroot "$SDK" \
  -F"$SDK/System/Library/Frameworks" -F"$SDK/System/Library/SubFrameworks" -F"$SDK/System/Library/PrivateFrameworks" \
  -L"$SDK/usr/lib" \
  -adhoc_codesign -ObjC -dead_strip \
  -rpath @executable_path/Frameworks \
  "$OUT"/main.o "$OUT"/AppDelegate.o "$OUT"/OCSceneDelegate.o "$OUT"/OCKeychain.o "$OUT"/OCUtil.o "$OUT"/OCSettings.o "$OUT"/OCServerClient.o "$OUT"/OCEngine.o "$OUT"/OCCrashLog.o "$OUT"/OCSessionsViewController.o "$OUT"/OCChatViewController.o "$OUT"/OCFilesViewController.o "$OUT"/OCEngineViewController.o "$OUT"/OCSettingsViewController.o "$OUT"/OCIntegrationsViewController.o "$OUT"/OCBrowserViewController.o "$OUT"/OCCodeViewController.o "$OUT"/OCStartupViewController.o "$OUT"/OCDesktopViewController.o "$OUT"/KernGlue.o "$OUT"/OCVsockBridge.o "$OUT"/OCLocalhostProxy.o "$OUT"/OCGuestInstall.o \
  -framework UIKit -framework Foundation -framework Security -framework CoreGraphics -framework QuartzCore -framework WebKit -framework Metal -framework MetalKit -framework CoreLocation \
  -lobjc -lSystem -lz \
  -o "$APP/OpenCode"

cp "$SRC/Info.plist" "$APP/Info.plist"
for ic in AppIcon60x60@2x.png AppIcon60x60@3x.png AppIcon76x76@2x.png AppIcon1024.png; do
  cp "resources/icons/$ic" "$APP/$ic"
done
# The startup screen logo: the official OpenCode avatar, same
# artwork as the app icon (resources/OpenCodeLogo.png).
cp "resources/OpenCodeLogo.png" "$APP/OpenCodeLogo.png"
printf 'APPL????' > "$APP/PkgInfo"

# Embed the runtime framework and the GPU frameworks it loads.
# The frameworks are dlopen-only: no -framework / -weak_framework
# flags anywhere (dyld would load them at launch and one unloadable
# framework kills the launch before any app code runs — see
# build-kernarium.sh). Drop any prebuilt code signature: the
# installer re-signs everything anyway.
# The cache directory may carry a suffix (fork build), but the
# framework MUST land in the bundle as KRuntime_6_18_4K.framework:
# loadRuntime resolves it by that exact name.
cp -r "$KRUNTIME_FRAMEWORK" "$APP/Frameworks/KRuntime_6_18_4K.framework"
cp -r Frameworks/KosmicKrisp.framework Frameworks/MesaEGL.framework Frameworks/MesaGallium.framework "$APP/Frameworks/"
find "$APP/Frameworks" -name _CodeSignature -type d -exec rm -rf {} + 2>/dev/null || true

cd "$OUT"
rm -f OpenCode-iOS.ipa
zip -qry OpenCode-iOS.ipa Payload
ls -lh OpenCode-iOS.ipa
sha256sum OpenCode-iOS.ipa
echo "== local build done in $(( $(date +%s) - START ))s (build id $BUILD_ID)"
