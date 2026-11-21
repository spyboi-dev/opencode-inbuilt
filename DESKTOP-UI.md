# Desktop UI mode — real OpenCode Linux desktop app in the Kernarium guest

Branch: `kernarium-desktop` (off `kernarium-engine` at bac51d4, includes the
dyld-constructor launch-logging fix). Do NOT merge to main. The LinuxRunner
build on main is untouched.

## Direction (user, 2026-11-21)

Take the real official OpenCode for Linux desktop and run it inside the
Kernarium kernel with its userspace, so all things work like coding, tool
calling, browser and all. Remember: real desktop app.

## What it is

- **CLI stays the engine** (default mode). `opencode serve` on guest port
  4096, native iOS UI on top. This is unchanged.
- **Desktop UI is the second selectable surface.** The real OpenCode Linux
  desktop app runs in the same Debian guest and is shown through the
  Virtio-GPU display path (`~/workspace/kernarium/docs/graphics.md`:
  guest Mesa -> Virtio-GPU / Virgl -> virglrenderer -> Mesa Zink over
  KosmicKrisp -> MTLTexture -> UIKit; desktop OpenGL 4.6, X11 under
  Xwayland; the guest sees a Virgl GPU, OpenGL ES 3.2).
- The desktop app is a **client of the server on localhost:4096 inside the
  guest**. Its coding, tool calling and browser capabilities come through
  that server. It does not replace the server.
- Mode switch: segmented control "CLI / Desktop UI" on the Engine tab,
  persisted as `oc.engineMode`, default CLI. Switching restarts the engine.

## Exact desktop asset (verified 2026-11-21 from the GitHub release API)

- Source: `anomalyco/opencode` release v2.3.0 (same version as the pinned
  server, commit a6b15d33...). An official arm64 Linux build EXISTS.
- Asset: **`opencode-desktop-linux-arm64.deb`**
  - Size: 239,644,012 bytes
  - SHA-256: `d3645cb1402517c00f1979e835ab37b53d16b9812480b3443b08f65394a79db1`
  - URL: https://github.com/anomalyco/opencode/releases/download/v2.3.0/opencode-desktop-linux-arm64.deb
- Also available (not used): `opencode-desktop-linux-arm64.AppImage`
  (312,812,602 bytes), `opencode-desktop-linux-aarch64.rpm`
  (211,433,881 bytes).
- The app is **Electron**. Installed size ~752 MB. Binary:
  `/opt/OpenCode/ai.opencode` (desktop file Exec=`/opt/OpenCode/ai.opencode
  %U`). There is NO `/usr/bin/opencode-desktop`. It carries its own CLI
  copy at `/opt/OpenCode/resources/opencode-cli` and runs, or joins,
  OpenCode 2's background service on port 4096.
- Debian Depends: libgtk-3-0, libnotify4, libnss3, libxss1, libxtst6,
  xdg-utils, libatspi2.0-0, libuuid1, libsecret-1-0.
- Browser capability: built-in Electron browser pane, plus the server's
  `webfetch` tool.
- Companion assets (same release, SHA-verified):
  - CLI `opencode-linux-arm64.tar.gz`, SHA-256
    `3207fb5cdec448d479242c0f1a14f4f7bdfcad3a79209b5eb8f9003725e93711`
  - Node 22.23.5 `node-v22.23.5-linux-arm64.tar.xz`, SHA-256
    `8bd3dc69eee8f3f226315a80d7d1d4faccf217a4c8fae500168ac2e38f3bdba3`
    (note: the download used was the `.tar.gz` variant;
    `node-v22.23.5-linux-arm64.tar.gz`, same SHA)

## Guest image

- Base: TermX Debian trixie arm64
  `~/workspace/kernarium-termux/vendor/termx-debian-trixie-arm64.ext4`
  (1,728,053,248 bytes; .gz 385,788,644 bytes, SHA-256
  `7bc05dcf82a48d7b1f04413c2d3a8c3cafa5ea4450cc2284b82725e7aba79676`).
  It has python3, nodejs (Debian), docker.io, git, build tools — but NO
  Node 22.23.5, NO OpenCode CLI, NO socat, NO Xorg/Mesa/desktop app, and
  only ~395 MB free inside, too small for the ~1.2 GB additions.
- So the image is rebuilt from an extracted directory, not resized in
  place. Extraction is debugfs rdump (this VM has no loop devices, no
  FUSE, no guestfish). rdump drops setuid/setgid/sticky bits and the
  overlayfs home leaves files at 0:65534; `fixup-rdump-modes.py`
  re-applies every entry's exact mode and numeric uid:gid from the
  image's own `ls -l` (final run: "extraction matches the image").
- Additions (`rootfs-build/opencode-guest-additions.sh`, run in an
  arm64 chroot under qemu-aarch64-static):
  - SHA-256 pins for all three downloads; uses pre-downloaded copies
    from `/tmp/guest-dl/` when present (else curl, still verifies).
  - Xorg + xserver-xorg-video-modesetting + Mesa DRI/EGL/GBM
    (libgl1-mesa-dri, libglx-mesa0, libegl-mesa0, libgbm1, libdrm2,
    mesa-utils) + fonts-dejavu-core + openbox + the .deb's Depends +
    extra Electron runtime libs.
  - socat VSOCK-LISTEN support check (fatal if absent).
  - Hard check that `/opt/OpenCode/ai.opencode` exists after install.
  - Session script runs `/opt/OpenCode/ai.opencode --no-sandbox
    --disable-dev-shm-usage`; Xorg with `-ac` (single-user guest,
    `-nolisten tcp`); explicit DISPLAY / XDG_RUNTIME_DIR / HOME.
  - systemd-analyze verify of the new units.
- Build: `rootfs-build/build-opencode-image.sh` (one invocation: binfmt,
  bind mounts, chroot additions run, cleanup, mke2fs -d repack with
  used + 40% headroom, e2fsck, debugfs spot checks, chmod 444,
  gzip -9, SHA256SUMS). Extraction helper:
  `rootfs-build/extract-termx-image.sh`.
- Publish target (already in `src/OCGuestInstall.m`, hashes TODO):
  `https://github.com/spyboi-dev/opencode-inbuilt/releases/download/rootfs-20261120/opencode-debian-trixie-arm64.ext4.gz`
  — needs a `gh release create rootfs-20261120` after the image is
  built, then fill `kOCGuestImageGzSHA256` / `kOCGuestImageSHA256` /
  `kOCGuestImageSize` in `src/OCGuestInstall.m`. Until the hashes are
  filled, setup refuses the image by design.
- Expected image size: ~600-800 MB .gz (est.). The TermX download crash
  at 70-80% (2026-11-21) is a warning sign for the same download path
  (`OCGuestInstall` uses NSURLSessionDownloadTask with progress polling).

## App-side wiring (this branch)

- `src/OCEngine.m` (desktop bootstrap): in Desktop UI mode the CLI
  server starts FIRST — backgrounded
  `nohup opencode serve --port 4096 --hostname 0.0.0.0`, log to
  `/tmp/opencode-serve.log` — then waits via authenticated curl probe
  to `http://127.0.0.1:4096/api/info` (Basic auth, user `opencode`,
  password `OPENCODE_SERVER_PASSWORD`), echoes "server listening" for
  guest.log, then starts the `opencode-desktop` service and polls
  `pgrep -f ai.opencode` + the X socket for DESKTOP READY. (The old
  `pgrep -f opencode-desktop` matched nothing — no such binary exists.)
- `OCDesktopViewController` (already in the code): MTKView full-screen,
  tap/drag as touch slots 0-9, keyboard forwarded as evdev key codes.
  DESKTOP READY handling and the desktop health check
  (`desktopReady && booted`) already exist.
- No clang on this VM to syntax-check the ObjC; the Mac build compiles it.

## Device test steps (when the launch crash is fixed)

1. Fresh install the IPA. Open the app, confirm the startup screen /
   Engine tab appears (no launch crash).
2. Tap Start. Wait for guest boot. Confirm the engine log shows the
   server listening line and the Engine tab shows running.
3. CLI mode (default): open Threads, confirm `/api/info` responds
   (server up), start a chat, confirm a real tool call works.
4. Switch the segmented control to Desktop UI. The engine restarts.
   Report exactly what appears in the Virtio-GPU view: the OpenCode
   desktop window should appear (dark Electron UI).
5. Desktop checkpoint: the desktop window must show the SAME sessions
   as the native iOS UI — proving it joined the 4096 server (not a
   second server).
6. In the desktop app, run a chat with a tool call (e.g. ask it to list
   files / run a shell command). Confirm it works.
7. `docker run hello-world` in the guest (first device test of Docker
   under the Kernarium kernel).
8. Confirm app.py on port 8000 is reachable (guest auto-starts it when
   `/root/Projects/app.py` exists).
9. Report any crash, blank view, or mismatch, with the engine log.

## Honest limits

- The app still crashes at launch in LiveContainer (SIGKILL-class death
  before didFinishLaunching; the dyld-constructor logging fix in
  bac51d4 is the diagnostic for it). The guest desktop cannot be
  device-tested until the launch crash is fixed. This build makes it
  ready for the moment the crash is fixed.
- Desktop UI adds guest RAM/CPU cost (Electron + Xorg + Mesa on top of
  the server). CLI stays the engine; Desktop UI is a second surface and
  adds no capability beyond the desktop app's own UI/browser pane.
- Persistence is NOT solved: sessions, logins and /root/Projects vanish
  every reboot (overlay formatted fresh; no shared folder in the public
  API). The TermX persistent-data-disk work (2026-11-21) is a future
  adoption candidate. Do not merge to main without the user's decision
  on this.
- Websearch still needs a search-provider API key from him (every 2.3.0
  search provider needs its own key).
- GPL-2.0-or-later copyleft applies to the shipped app.

## Build log

See `KERNARIUM-BUILD.md` for the per-run Mac build log (run URLs,
SHAs, verification).
