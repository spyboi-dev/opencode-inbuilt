# Desktop UI mode — real OpenCode Linux desktop app in the Kernarium guest

Branch: `kernarium-desktop` (off `kernarium-engine` at c556d84, includes the af64d5b logging fix: buffer-over-read fix, same-file dedup, Calling UIApplicationMain marker). Do NOT merge to main. The LinuxRunner build on main is untouched.

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
- Published: release `rootfs-20261120` (ID 453414533), public
  (draft=false), with the image in 12 verified parts — see "Chunked
  delivery" below. The app downloads the parts, verifies each
  SHA-256, reassembles the `.gz` and verifies the whole archive hash
  (`kOCGuestImageGzSHA256` / `kOCGuestImageSHA256` /
  `kOCGuestImageSize` in `src/OCGuestInstall.m`). Until the hashes
  are filled, setup refuses the image by design.
- Expected image size: ~600-800 MB .gz (est.). The TermX download crash
  at 70-80% (2026-11-21) is a warning sign for the same download path
  (`OCGuestInstall` uses NSURLSessionDownloadTask with progress polling).

## Chunked delivery — the image is published (2026-11-21)

- The single 1.16 GB upload failed five times on the VM egress proxy
  (HTTP/2 stream CANCEL, connection resets; the longest ran 20 min).
  A sixth check then proved the asset had NOT landed after all
  (release asset list empty, `gh release download` said "no assets
  to download"), so the chunked plan ran instead of another single
  upload.
- Split: `split -b 100M` (100 MiB parts) in
  `rootfs-build/` → 12 chunks,
  `opencode-debian-trixie-arm64.ext4.gz.part00`–`.part11`
  (part00–10: 104,857,600 bytes each; part11: 5,716,714 bytes).
  Recorded in `rootfs-build/CHUNKS-SHA256SUMS`; reassembly verified
  locally (`cat part* | sha256sum` = `b1018c93…`).
- Upload: `rootfs-build/upload-chunks.sh` — one chunk at a time,
  `gh release upload --clobber`, each verified by API size check
  right after, up to 3 retries per chunk. All 12 landed first try,
  ~1–2 min each. Final asset list verified name + size for all 12,
  then the release was published
  (`gh release edit --draft=false`).
- Chunk SHAs (SHA-256):
  - part00 `fcb2337ab43d5e4158295d69a355388c31bfdb06e6bfdad9e008c962ce95ba53`
  - part01 `35a25e8b2ede174bd02ab20bf36d8e7b5cf121f7358f3b4b102d2a0737308fe3`
  - part02 `0eabfe831216767a07b89909d42e4707a33d9789018566f3f2abb64113158ef9`
  - part03 `a56f58349f8906932ba294c64e94faf3ea62a28a824ee886f4c1ea58316170cd`
  - part04 `aac03682fac715e776623e9a4ca0a2a0b19b3b671bc6c3a0a9551f016110c98b`
  - part05 `a957c690982dbd46f8ae56841e38d523af0f063b4e9b98bbaec8d7223164b14f`
  - part06 `7fb8d922db43f2baaa3d36f511c9dbc0e31ebb3babdb2bb83e6c8a3aaa768fd8`
  - part07 `00a262fc27ab876063b5f200d6f607482a645bcba5a3b3b0b1c84695e9d2bea7`
  - part08 `e53e8d09f2dd0ee5410f1056aa74d05f8492fc3a16163332fe51027ddf25e601`
  - part09 `9dad6dc9cf7df436bd1a12348bbe63da54303231862e13a316c40274c7c62360`
  - part10 `ffba913c707fe29c94a7a2f109b479794843da7ca6ab22bfa1d46f11442d7297`
  - part11 `77d42a1fcf088a4cd917b0cb48cb648969263fbbad5593ae77ce662569013db5`

## Chunked download + TermX resume guards (commit 9ccab19)

- `src/OCGuestInstall.m` rewritten for the chunked delivery: it
  downloads the 12 parts in order from
  `.../releases/download/rootfs-20261120/<part name>`, verifies each
  part's size + SHA-256, reassembles the `.gz` (streaming 1 MB at a
  time), verifies the whole archive hash `b1018c93…`, then gunzips
  and verifies the `.ext4` hash `c7511200…` as before. A part that
  fails verification is deleted and re-downloaded (3 attempts);
  verified parts are kept on disk, so a killed Install resumes at
  the first missing part instead of restarting from zero.
- TermX resume fix (termx commit 8c76d48) applied by review:
  **no NSURLSession resume data is used anywhere**, by design —
  `downloadTaskWithResumeData:` throws NSInvalidArgumentException on
  a stale blob instead of returning nil, which made every TermX
  Install tap crash in under a second. Per-part resume gives the
  same benefit with no blob that can go stale. Task creation is
  still wrapped in `@try/@catch`; the install runs on a background
  queue (the installed check SHA-256s a 4.46 GB image, never on the
  main thread); a background-task assertion covers the whole
  pipeline, ended in the single finish funnel; a re-entrant Install
  is refused cleanly ("install already in progress").
- `gunzipFile` heap buffer (256 KiB): the old 1 MiB stack buffer was
  the TermX SIGBUS class (termx commit d2b4f2e) on a 512 KiB GCD
  worker stack. This path had never run on device yet.
- Checked and NOT a problem here: the TermX poll-hash loop (startup
  screen's 0.5s timer calling `guestInstalledAt`, which SHA-256s the
  whole image each tick) does not exist in this app — the startup
  poll reads the cached engine state, and `guestInstalledAt` runs
  only once per boot/setup. KernGlue's framework lookup already
  falls back to the executable-relative `Frameworks/` directory, so
  the TermX `pathForResource` bug (commit 72bb2bf) does not apply.
- Workflow verify now also requires the release tag, both image
  hashes, `part00`/`part11` and the `Launch step` markers in the
  binary. One check artifact: the progress step strings contain the
  `…` ellipsis, so clang stores them UTF-16LE and plain `strings`
  does not show them — they are present in the binary, verified by
  byte search.

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

## Build log (kernarium-desktop)

- **Validation build — commit a669084, run 44858037412, success in
  35m18s.** IPA 25,306,558 bytes, SHA-256
  `c74b918acdeff10f5dc234a2b5b687b0e16023977153e22634db021717834dda`.
  Backed up as `mac-ipas/OpenCode-Inbuilt-kernarium-a669084.ipa`.
  Verified: arm64, MinOS 15.0.0, SDK 27.0.0, zero Kernarium load
  commands, all four frameworks embedded, zero BUILD-NOTE strings,
  7 launch markers, KRuntime exports `_kernarium_runtime_get_api_v28`.
  This build has the desktop code but the image hashes were still TODO
  placeholders, so setup would refuse the image.
- **Final build — commit ea38dd1, run 44862885782, success in 24m48s.**
  IPA 25,306,937 bytes, SHA-256
  `630abbfb14e1ce21b7256f58aeb980444957af3c4c0d15191f7e0a15c7008d14`.
  Backed up as `mac-ipas/OpenCode-Inbuilt-kernarium-ea38dd1.ipa` and
  `build/OpenCode-Inbuilt-kernarium.ipa`. Verified the same as above,
  plus the image hashes ARE baked into the binary (`.gz` SHA
  `b1018c93…`, `.ext4` SHA `c7511200…`, release tag `rootfs-20261120`
  all found in the app binary). This is the deliverable IPA.
  Run: https://github.com/spyboi-dev/opencode-inbuilt/actions/runs/44862885782
- **Guest image — built 2026-11-21 03:34:15Z** by
  `rootfs-build/build-opencode-image.sh` (extraction via debugfs rdump
  + mode/uid fixup, chroot additions under qemu-aarch64-static,
  mke2fs -d repack, e2fsck clean, gzip -9). Rootfs 3.0 GiB used;
  image 4,462,739,456 bytes (4,256 MiB ext4); `.gz` 1,159,150,314
  bytes. SHA-256 (`.ext4`)
  `c7511200d3e23e21bcd68e63904e489b4724e24c263464e92c8dd72963a83e1f`;
  SHA-256 (`.gz`)
  `b1018c9357236ea2355bff488eda32171cc25c450997cccd7052b15992d3a8fa`.
  Inside the image, verified: Node v22.23.5, opencode v2.3.0, bun
  1.4.5, git 2.47.3, Python 3.13.5, jq 1.7, ripgrep 14.1.1, socat
  (VSOCK-LISTEN), Openbox 3.6.1, `/opt/OpenCode/ai.opencode`
  (220,925,320 bytes) + bundled CLI, vsock-proxy and
  opencode-desktop systemd units. Two build failures on the way, both
  fixed: npm `SELF_SIGNED_CERT_IN_CHAIN` (the egress CA bundle was not
  visible in the chroot — first the bind-mount silently failed because
  the target file did not exist; fixed by touching the target file
  first and verifying inside the chroot, plus `SSL_CERT_FILE`).
  One non-fatal warning: `unshare: unshare failed: Invalid argument`
  during the desktop .deb postinst (chrome-sandbox setup under qemu);
  the app runs with `--no-sandbox`, so it does not matter.
- **Release upload — `rootfs-20261120`, PUBLISHED 2026-11-21.**
  The single 1.16 GB upload failed five times on the VM egress
  proxy; a sixth check proved no asset had landed. Delivered
  chunked instead: 12 parts, all uploaded first try and verified
  name + size, release published (draft=false). See "Chunked
  delivery" above for the part list and SHAs.
- **Chunked + rebase build — commit 9ccab19, run 44869304088, success in 23m16s.** IPA 25,310,216 bytes,
  SHA-256
  `70233f26857c30be848e3dcc26d4e64f1565b7027236c1be06c840f872167d14`.
  Backed up as `mac-ipas/OpenCode-Inbuilt-kernarium-9ccab19.ipa`
  and `build/OpenCode-Inbuilt-kernarium.ipa`. Verified
  independently of the workflow: arm64, MinOS 15.0.0, SDK 27.0.0,
  LC_MAIN 0x4000, code signature valid (124/124 page hashes),
  zero Kernarium load commands, all four frameworks embedded,
  KRuntime exports `_kernarium_runtime_get_api_v28`, DYLD OK,
  BOOT.txt, Calling UIApplicationMain, all 7 launch markers,
  release tag + both image hashes + part00/part11 + first/last
  chunk SHAs in the binary, zero BUILD-NOTE strings, zero `.html`.
  This is the deliverable IPA.
  Run: https://github.com/spyboi-dev/opencode-inbuilt/actions/runs/44869304088

Note: `KERNARIUM-BUILD.md` is now on this branch too (it came in
with the rebase onto kernarium-engine at c556d84); the desktop
entries are appended at the end of that file. This branch now
includes the af64d5b logging fix (buffer-over-read fix, same-file
dedup, Calling UIApplicationMain marker).
