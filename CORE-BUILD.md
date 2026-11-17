# Core build (GitHub Actions, macOS + Xcode 26)

The app ships WITHOUT the guest core linked: `OCEngine.guestCoreLinked`
is NO and the Engine tab reports "core pending link". This pipeline
builds the real core on GitHub Actions and links it in, so Start boots
a Debian guest and runs the OpenCode server inside the app.

## Pinned core

- LinuxRunner 1.1.2, commit `f96a2a6f1327363856b5cd1975f1f6cb279cc884`
  (Release LinuxRunner 1.1.2 (910), 2026-11-15), upstream
  https://github.com/mxhm11cr/LinuxRunner.git
- The workflow clones that commit itself. Nothing of the LinuxRunner
  tree is vendored in this repo; the only vendored files are the ones
  the workflow cannot fetch: the app icons under `resources/icons/`
  (copied from the SPYTube build) and the Debian manifest.
- JITless: the core is built with `-Djit=false`, the interpreter-only
  default. No JIT, no StikJIT/StikDebug needed.

## How it works

1. `.github/workflows/build-core.yml` (runs-on `macos-26`, Xcode 26)
   clones the pinned LinuxRunner commit and inits the `deps/libarchive`
   submodule.
2. It configures the core with LinuxRunner's own `app/xcode-meson.sh`
   (meson cross build for darwin/aarch64, `vdso_required=true` so the
   release IPA gets the real aarch64 vDSO) and builds `libish.a`,
   `libish_emu.a`, `libfakefs.a` with ninja.
3. It builds `libarchive.a` from the submodule's xcodeproj
   (`-target libarchive`, no shared scheme exists in that project).
4. `build-core.sh` compiles the app with `-DOC_CORE_LINKED=1`,
   compiles the glue (`src/CoreGlue.m`) plus the two upstream C files
   the glue needs (`app/LinuxRunner/DebianBootstrap.c`,
   `tools/fakefs.c`), links everything with the core libs and
   `-lsqlite3 -lz -lbz2 -llzma -liconv -lresolv`, adhoc-signs, and
   zips `build/OpenCode-Inbuilt.ipa`.
5. The glue (`src/CoreGlue.h` / `src/CoreGlue.m`) mirrors
   LinuxRunner's `AppDelegate.m` boot sequence (mount_root,
   exchange bind mount, device nodes, /proc + /sys + /dev/pts,
   DNS, console stdio, `/bin/sh /usr/lib/linuxrunner/init.sh` as
   PID 1) and provides an `OCGuestExecutor` that spawns a guest
   process per command through a PTY, with a 1-second spawn
   acknowledgement. `AppDelegate` installs it at launch (guarded by
   `OC_CORE_LINKED`); `OCEngine.startEngine` boots the guest from
   the cached .deb packages on first Start after a relaunch, then
   launches `opencode serve` as before.
6. The workflow verifies the linked binary contains the core symbols
   (`mount_root`, `fakefs_import`) before uploading.

Without the define (`build.sh` on the Linux VM) the app builds
exactly as before: no core, `guestCoreLinked` NO, Engine tab says
core pending link. The shipped IPA in `build/` is the last
known-good no-core build and is never overwritten by this pipeline
(the workflow builds in its own checkout).

## Trigger

- Manually: Actions tab -> "Build core + IPA" -> Run workflow.
- Automatically: a push to `main` that touches `src/**`,
  `build-core.sh`, `resources/**`, or the workflow file itself.

## Artifacts

- `core-libs`: `libish.a`, `libish_emu.a`, `libfakefs.a`,
  `libarchive.a` (all arm64, iOS).
- `OpenCode-Inbuilt-core`: `build/OpenCode-Inbuilt.ipa`, adhoc
  signed, min iOS 15.0. Install it the same way as the no-core IPA
  (SideStore / LiveContainer guest); on first Start it boots the
  guest from the cached Debian packages and the Engine tab should
  move to Running instead of "core pending link".

## Known unverified points

- The workflow assumes `brew install llvm lld` gives the vdso build
  a clang that links `aarch64-linux-gnu` with `ld.lld` (LinuxRunner's
  own `check-cc-arm64.sh` verifies this at configure time and the
  configure step fails loudly if it does not hold).
- `staticdefine.sh` (cpu-offsets.h generation) trims the last 9
  tokens of meson's asbestos.c compile command; that is upstream's
  own mechanism and works with the meson version brew installs, but
  it is fragile to meson changing its command shape.
- The core has never been linked or run yet: the first green workflow
  run is the first proof the link works, and the first run on a
  physical iPhone is the first proof the guest boots.
