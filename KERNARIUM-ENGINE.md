# Kernarium engine rebuild — design note (2026-11-20)

Design only. No code written, nothing built. UI stays exactly as it is;
only the engine layer (`OCEngine` / `CoreGlue` / guest bootstrap / Mac
build) changes. Branch for the rebuild: `kernarium-engine` (main keeps
shipping the working LinuxRunner build until this one is proven on device).

## Build status, 2026-11-20 (kernarium-engine branch)

Implemented on the branch (see the commit history there); nothing
below has run on a device yet.

- `src/KernGlue.h/.m` replaces `CoreGlue.h/.m` (deleted): dlopen
  loads `KRuntime_6_18_4K.framework` at run time, boots the Debian
  guest (overlay recreated each boot, `use_jit = 0`), feeds the
  console to `OCEngine`, types the bootstrap at the autologin shell,
  and owns the vsock bridges. The boot struct lives in an ivar, not
  on the stack: `run()` outlives the call that starts it.
- `src/OCVsockBridge.h/.m`: host loopback listener
  (`127.0.0.1:4096` -> guest vsock 4096, `127.0.0.1:8000` -> guest
  vsock 8000), byte pump both ways with half-close handling.
- `src/OCGuestInstall.h/.m`: first-launch setup is now the prebuilt
  guest image download (SHA-256 of archive + image, skip-if-present).
  The image is NOT published and the hashes are TODO placeholders,
  so setup refuses the image until the image build finishes.
- `OCEngine` rewritten on the same public shape: `.deb` setup chain
  gone, progress now fed by the console callback, `guest.log`
  replaces `serve.log`/`boot.log` in the Log view, app.py auto-start
  wired into the console bootstrap, password typed with echo off and
  redacted from the console transcript.
- Frameworks: `KRuntime_6_18_4K` does NOT exist on this VM and must
  still be Mac-built (`package-ios-frameworks.sh --sdk device` in
  the new workflow). The three GPU frameworks ARE vendored in this
  repo now (`Frameworks/`, copied from the Andarium release IPA via
  TermX), so the Mac build only has to produce the one Linux
  framework.
- New Mac build: `build-kernarium.sh` + `.github/workflows/
  build-kernarium.yml` (MinOS 27.0, `OC_KERNARIUM_LINKED`). The
  LinuxRunner workflow and `build-core.sh` are untouched. The local
  `./build.sh` compiles the new glue (the runtime is dlopen'd, so
  the Linux build links without the framework) and reports the
  engine honestly as not ready yet.
- Engine: Desktop UI only since 2026-11-25 (CLI mode removed;
  see "Engine modes" below). Install has no mode choice; the
  engine always boots the desktop app (server on 4096 + window).
- Background location mode (see "Background" below): Always
  location + `UIBackgroundModes` location, plain-words prompt copy.
- Guest image additions: `rootfs-build/
  opencode-guest-additions.sh` (Node 22.23.5, OpenCode CLI 2.3.0,
  `gh jq ripgrep socat bun`, Xorg + openbox + OpenCode desktop app,
  vsock proxy units, desktop service). Not run yet: the TermX image
  build is unfinished.
- Persistence: NOT solved. See "PERSISTENCE-TODO" below. Sessions,
  provider logins and `/root/Projects` vanish on every reboot until
  that work lands. Do not merge without that decision.

## 1. What the current engine seam is

### App start (`src/AppDelegate.m`, `didFinishLaunchingWithOptions`)

1. `[[OCEngine shared] refreshState]`
2. `#ifdef OC_CORE_LINKED`: `[[OCCoreGlue shared] installGuestExecutor]`
   — registers the guest executor on `OCEngine`, which makes
   `OCEngine.guestCoreLinked` YES (`guestCoreLinked` is just
   `guestExecutor != nil`).
3. `[[OCEngine shared] maybeAutoStartEngine]` — once per launch, never
   after an explicit Stop in the same session, nothing without the core,
   nothing before first-launch setup is done.
4. `OCStartupViewController` presented fullscreen over the tabs; it only
   observes, it starts nothing.

### Guest boot, LinuxRunner (`src/CoreGlue.m`, `src/OCEngine.m`)

- First launch: `OCEngine.runFirstLaunchSetupWithProgress` downloads the
  Debian 13.7 package set from deb.debian.org (37 MB, 103 packages) into
  `Documents/Engine/debian-cache/`, SHA-256-verified against the bundled
  `debian-manifest.json`.
- First boot only: `OCCoreGlue.bootWithPackagePaths` turns the cached
  `.deb`s into a fakefs guest root with `lr_debian_bootstrap()` then
  `fakefs_import()` (`Documents/Engine/root/`, `meta.db` + `data/`).
  Later boots just mount. Boot order (SIGSEGV fix, commit 18a8899):
  `mount_root()` → `become_first_process()` → `prepare_guest_runtime_dirs()`
  → exchange bind mount (`Documents/Engine/exchange/` ↔
  `/home/mobile/Downloads`) → `/dev` nodes, `/proc`, `/sys`, `/dev/pts`
  → DNS from host resolver → console stdio → `do_execve("/bin/sh
  /usr/lib/linuxrunner/init.sh")` → `task_start(current)`. Init idles as
  PID 1 after `dpkg --configure -a`.
- Executor: `OCCoreGlue.runCommand:workingDirectory:completion:` spawns
  `/bin/sh -c <command>` in a fresh guest process on a PTY
  (`become_new_init_child` + `pty_open_fake` + `create_stdio` +
  `do_execve` + `task_start`). Completion fires with the real exit code
  if the process dies within 1 s, else with 0 as a spawn acknowledgement
  (long-lived serve depends on this). All on one serial queue, because
  `current` is thread-local.
- `OCEngine.startEngineWithCompletion`: boots on demand if needed, then
  `startServeWithCompletion`. `stopEngine` bumps `serveGeneration` so a
  late executor completion cannot resurrect a stopped engine. Health:
  `GET /api/info` every 5 s, 3 strikes → stop + restart; 5-minute grace
  on first start while Node/OpenCode install.

### Node + OpenCode + serve (`OCEngine.m`, `startServeWithCompletion`)

One bootstrap string run via the executor in `$HOME/Projects`, logging
to the exchange dir's `serve.log` (`SLOG=/home/mobile/Downloads/serve.log`):

- `PROGRESS 5 Checking Node...`; if no `node`, download Node 22 LTS
  arm64 v22.23.5 tarball (25 MB) from nodejs.org, `tar -xzf` to
  `/usr/local` (`.tar.gz` deliberate: guest has gzip but no `xz`).
  `PROGRESS 55 Node ready`.
- If no `opencode`, download OpenCode 2.3.0 release binary
  `opencode-linux-arm64.tar.gz` (114 MB) from
  `github.com/anomalyco/opencode/releases/download/v2.3.0/`, extract to
  `/usr/local/bin`, `chmod +x`. `PROGRESS 85 OpenCode ready`. (NOT npm:
  `opencode-ai` is the 1.x line, no 2.3.0.)
- If any of git/python3/pip3/gh/jq/rg missing: `DEBIAN_FRONTEND=
  noninteractive dpkg --configure -a; apt-get update; apt-get install -y
  git python3 python3-pip gh jq ripgrep` (`PROGRESS 88 Tools ready`).
  Non-interactive is required: tzdata otherwise hangs at the debconf
  prompt (seen 2026-11-17). Then `npm install -g bun` if missing
  (`PROGRESS 89`).
- `pkill -x opencode; sleep 1` (leftover server holds port 4096).
- `OPENCODE_SERVER_PASSWORD=<keychain> opencode serve --port 4096
  --hostname 0.0.0.0 >> "$SLOG" 2>&1`. `--hostname 0.0.0.0` is what
  makes the guest server reachable at iOS localhost in the LinuxRunner
  build (BUILD-NOTE.md, Liftoff precedent).

### Server contract (unchanged by this rebuild — see §4 for the catch)

- `OCServerClient.m`: `NSURLSession` to `OCSettings.serverURL`, default
  `http://127.0.0.1:4096`. Basic auth `opencode:<password>` (password
  from Keychain via `OCSettings.ensureServerPassword`). Health is
  `GET /api/info`; sessions/messages/files/shell over `/api/*`; live
  events are SSE via `GET /api/event` (long-lived task, auto-reconnect
  after 2 s).
- Progress: guest writes `PROGRESS <pct> <message>` lines (and `ERROR
  ...`) to `serve.log`; `OCEngine.pollServeLog` (1 s timer while
  starting) applies the latest line, monotonic only. The definitive
  start signal is the literal string `server listening` in serve.log —
  it completes progress at 1.0 and flips state to Running even before
  the HTTP health check confirms it.
- `OCEngine.fullLogText` concatenates `engine.log` + guest `boot.log` +
  guest `serve.log` (with a "previous run" warning when stopped).
  `OCStartupViewController` polls `OCEngine` every 0.5 s.

### app.py auto-start (`OCEngine.m` bootstrap, `AUTO-START.md`)

Inside the bootstrap, before the old server is killed and OpenCode
starts:

```sh
if [ -f /root/Projects/app.py ]; then
  (cd /root/Projects && nohup python3 app.py > server.log 2>&1 &)
  echo "app.py started" >> "$SLOG"
fi
```

Guarded on the file existing, detached with `nohup … &` so it survives
the bootstrap shell exiting, always exits 0 so it never blocks the
engine start, and never kills an older app.py holding port 8000. It
exists because the guest agent refuses to start app.py itself (calls
its shell read-only) and the server was confirmed never up (2026-11-20:
curl to 127.0.0.1:8000 fails, server.log 0 bytes).

### Mac build (`build-core.sh`, `.github/workflows/build-core.yml`)

Runs on `macos-26`, Xcode 26, `IPHONEOS_DEPLOYMENT_TARGET=15.0`:
clone LinuxRunner 1.1.2 at pinned commit `f96a2a6f`, run its
`app/xcode-meson.sh` (meson cross build, `jit=false`,
`vdso_required=true`), `ninja libish.a libish_emu.a libfakefs.a`,
build `libarchive.a` from the submodule xcodeproj, then
`./build-core.sh` compiles the app with `-DOC_CORE_LINKED=1` and links
the three static libs + libarchive. Verify step greps the binary for
`_mount_root` and `_fakefs_import`.

## 2. What TermX already built (reuse it, do not redo it)

Source: `~/workspace/kernarium-termux/` — `PORT-NOTE.md` (architecture),
`BUILD-NOTE.md` (status), `termx/src/`, `rootfs-build/`,
`kernel-config-android-6.18.60.txt`. Upstream clone:
`~/workspace/kernarium/` at commit `fbe12ee`
(imxieyi/Kernarium, GPL-2.0-or-later).

### The runtime pieces

- **Frameworks** (extracted from the Andarium 1.0-15 release IPA in
  `kernarium-termux/vendor/andarium-extract/`): `KRuntime_Android_6_18_4K`
  (Android flavour only — **cannot boot a Linux guest**: the run
  implementation is compile-time branched on
  `KERNARIUM_RUNTIME_ANDROID_GUEST`, requires `android_data_disk_path` +
  `android_release_path`, and its `send_console_input` answers
  `-ENOTSUP`), plus the three GPU frameworks `KosmicKrisp`,
  `MesaEGL`, `MesaGallium` (reused as-is by the Linux runtime).
- **The Linux framework `KRuntime_6_18_4K` does not exist anywhere on
  this VM.** Not in any Kernarium release, not in the Andarium IPA.
  Upstream CMake refuses non-Apple hosts (`CMakeLists.txt:46-48`,
  FATAL_ERROR) and needs Xcode + Metal + Swift/SPM + codesigning.
  Build it on a Mac with `Kernarium/scripts/package-ios-frameworks.sh
  --sdk device` (writes `.build/kernarium-xcframeworks/`), copy the
  device slice into the app's `Frameworks/` — exactly the preflight
  `termx/build.sh` enforces (exits 1 without it). This is the
  single blocker, same shape as the LinuxRunner Mac build.
- **Public C API**: `termx/src/KernariumRuntime.h` (copied verbatim from
  upstream, API version 43, entry `kernarium_runtime_get_api_v28()`).
  The app resolves only that getter after loading exactly one framework.
  Key functions: `run(view, boot)`, `request_stop()`, `set_console_output_callback(cb, ctx)`,
  `send_console_input(bytes, len)`, `plan_gpu_budget(...)`,
  `set_gpu_hold(held)`, `connect_vsock(port, timeout_ms)`.
  `run()` **blocks until the guest stops** — call it on a background
  thread. It returns 0 on clean power-off/stop, a negated
  `uml_emulator` error on failure, or
  `KERNARIUM_RUNTIME_RESULT_RESTART_LOOP` (-100).
- **Boot struct** `kernarium_runtime_boot` (fill `struct_size` first):
  `width/height/dots_per_inch` (guest framebuffer size — `run()` refuses
  a null `MTKView`, so keep a hidden full-screen MTKView behind the UI
  even though this app never shows the framebuffer),
  `guest_memory_mib`, `guest_processor_count`, `rootfs_path`,
  `overlay_path`, `session_record_path`, `use_jit = 0` (gadget /
  interpreter engine: no JIT, no StikDebug, no debugger needed).

### How TermX boots a guest (`termx/src/KernEngine.m`, 244 lines)

- `KernEngine` states Idle / Downloading / Ready / Booting / Running /
  Stopped / Failed; `guest_memory_mib = 1024`, `guest_processor_count = 2`,
  overlay 4 GiB sparse file in `NSTemporaryDirectory()`, recreated every
  boot (`createOverlayWithError` — `ftruncate` to size; path must contain
  no spaces/quotes/commas/colons, it goes on the kernel command line).
- `bootOnView:(MTKView *)view`: `plan_gpu_budget(1024, 2, …)` first
  (warns when `short_of_floor` but boots anyway), `set_console_output_callback`
  (watches console text for `UML_BOOT_ERROR:` → Failed, and `login: ` →
  Running), fills the boot struct, dispatches `api->run(view, &boot)` on
  a background queue.
- Console is the shell I/O: the runtime mirrors the guest's ttyS0 to the
  host via the console callback, and `send_console_input` writes to it.
  **There is no guest executor in Kernarium.** There is no equivalent of
  `OCCoreGlue.runCommand` — no way to run one command in the guest and
  get its exit code. The only host→guest channels are the serial console
  (type a command at the autologin shell) and vsock (host-initiated
  byte streams, see §4).
- Boot contract (from upstream source, `PORT-NOTE.md`): the runtime
  embeds the base initramfs (`uml-boot-base-aarch64.cpio.gz`,
  starter-20260928-boot-base-r1); `/boot.env` is fixed:
  `UML_BOOT_ROOT=/dev/ubda`, `UML_BOOT_ROOT_TYPE=erofs|ext4`,
  `UML_BOOT_UPPER=ext4`, `UML_BOOT_UPPER_DEVICE=/dev/ubdb`,
  `UML_BOOT_ENTRY=/sbin/init`. Entry is always `/sbin/init` (systemd);
  the image's default target must be `multi-user.target`. Kernel
  cmdline has `console=tty0` + `console=ttyS0`, so systemd spawns
  `serial-getty@ttyS0`. `/init` prints `UML_BOOT_SWITCH_ROOT:/sbin/init`
  on success, `UML_BOOT_ERROR:<reason>` on failure. A Linux guest has
  **no `boot_completed` signal — "up" is the `login: ` prompt** on the
  console. Rootfs may be erofs or ext4; a `*.ext4` image must carry NO
  write permission bits (chmod 444).
- **Overlay is stateless: `/init` formats ubd1 fresh on every boot.
  Guest writes do not persist across boots.** Apt installs live for one
  session only. Bake tools into the image. (See §6 — this is the
  biggest behavioural change vs LinuxRunner, whose fakefs root persists.)

### The Debian guest image (`rootfs-build/`, `termx/src/GuestInstall.m`)

- Built with `debootstrap --foreign --arch=arm64 --variant=minbase
  trixie`, second stage under qemu-aarch64-static, then configured in
  chroot (`configure-rootfs.sh`): systemd, `multi-user.target`,
  `serial-getty@ttyS0` with autologin as user `termux` + passwordless
  sudo, systemd-networkd DHCP on eth0, hostname `termx`,
  `TERM=xterm-256color`, and baked-in
  `systemd systemd-sysv udev dbus bash coreutils … python3 python3-pip
  git curl vim nodejs build-essential docker.io iptables`
  (plus `ca-certificates`, `tzdata`, `locales`, `openssh-client`).
  Packed with `mke2fs -t ext4 -d`, `e2fsck` + `debugfs` checks, chmod
  444, `gzip -9` + SHA-256.
- `GuestInstall`: downloads `termx-debian-trixie-arm64.ext4.gz` from the
  (not yet published) `spyboi-dev/termx` release, streaming gunzip via
  zlib, verifies SHA-256 of the archive AND of the extracted image,
  chmod 0444, skip-if-present.
- **Status 2026-11-20: the image is NOT finished.** The build runs in
  ephemeral `/opt/termx-rootfs-build/` (wiped by a VM restart), the
  configure step's apt fetches keep failing through the VM proxy, and
  `kRootfsGzSHA256` / `kRootfsSHA256` / `kRootfsSize` in `GuestInstall.m`
  are still TODO placeholders. No image in `vendor/` yet. The OpenCode
  rebuild inherits this dependency — it needs the same image (plus
  OpenCode baked in, §3) before anything boots.

## 3. How the Kernarium guest replaces the LinuxRunner guest, step by step

New glue file: `src/KernGlue.h/.m` (replaces `CoreGlue.h/.m`; keep the
file names parallel so the diff is reviewable). `OCEngine` keeps its
public shape — `guestExecutor`, `guestCoreLinked`, `serveProgress`,
`serveStatus`, `startEngineWithCompletion`, `stopEngine`,
`checkHealthWithCompletion`, `maybeAutoStartEngine` — but what fills
them changes. `OC_CORE_LINKED` becomes `OC_KERNARIUM_LINKED` (or keep
the same define name and swap what it guards; do not have both cores
linked at once — the runtime loads exactly one guest flavour per
process lifetime, and the two cores would fight over the process).

| Step | Today (LinuxRunner) | Kernarium rebuild |
| --- | --- | --- |
| 1. First-launch setup | `OCEngine` downloads 103 Debian `.deb`s (37 MB), SHA-256 vs manifest | **Delete.** No `.deb` cache, no `debian-manifest.json`, no `lr_debian_bootstrap` / `fakefs_import`. Setup becomes: download the prebuilt Debian ext4 image (GuestInstall pattern, SHA-256 of archive + image, skip-if-present) into `Documents/Engine/guest/`. State flags `oc.engineInstalled` / `oc.debianCached` become one `oc.guestImageInstalled`. |
| 2. Guest root | fakefs root built on device, persists | Read-only ext4 image (chmod 444) + 4 GiB sparse overlay in `NSTemporaryDirectory()`, recreated each boot. Rootfs path: `Documents/Engine/guest/termx-debian-trixie-arm64.ext4` (reuse TermX's image name, or rename to `opencode-debian-…`; pick one and keep it). |
| 3. Boot | `OCCoreGlue.bootWithPackagePaths` → `mount_root`, `become_first_process`, mounts, `do_execve(init.sh)`, `task_start` | `KernGlue.bootWithCompletion`: `plan_gpu_budget(1024, 2, …)` → `set_console_output_callback` → fill `kernarium_runtime_boot` (`rootfs_path`, `overlay_path`, `session_record_path`, `use_jit=0`) → `api->run(hiddenMTKView, &boot)` on a background queue. The hidden MTKView is mandatory (`run()` errors on null); keep one full-screen MTKView behind the tab bar, never shown. `booted` = console saw `UML_BOOT_SWITCH_ROOT:/sbin/init` and then `login: `. Boot failure = `UML_BOOT_ERROR:<reason>` on the console, or `run()` returning non-zero / -100. |
| 4. Running commands in the guest | `guestExecutor` → fresh guest process on a PTY, exit code back | **No executor exists.** The bootstrap must be delivered over the serial console instead: after the `login: ` prompt, `send_console_input` types the bootstrap into the autologin shell (user `termux`, passwordless sudo — so run privileged steps with `sudo`, or autologin as root in the OpenCode image variant; decide in implementation, TermX uses `termux`). Console input is a byte stream with no exit code and no per-command output capture: the bootstrap must report itself by writing `PROGRESS` / `ERROR` lines to a log the app can read — see §5. `guestExecutor` as a type stays (other callers expect it) but its implementation becomes "send text to the console + wait for a marker", and `startServeWithCompletion` must not depend on the 1-second spawn-ack semantics — a console-typed serve command never "exits". |
| 5. Node + OpenCode install | Downloaded on first Start into the persistent guest root (Node 25 MB, OpenCode 114 MB) | **Must be baked into the image.** The overlay is wiped every boot, so a first-Start download would repeat on every launch. Add to `rootfs-build/configure-rootfs.sh`: Node 22 LTS arm64 tarball extracted to `/usr/local` (same v22.23.5, same `.tar.gz` — no xz in the guest) and the OpenCode 2.3.0 release binary to `/usr/local/bin/opencode` (same `anomalyco/opencode` asset). Also bake `git python3 python3-pip gh jq ripgrep bun` (TermX image already has git/python3/nodejs; add gh/jq/ripgrep/bun). The bootstrap then only *checks* (`command -v node`, `command -v opencode`) and skips — the PROGRESS lines jump straight past those thresholds, exactly as the startup screen already handles. |
| 6. Tools / apt | `apt-get install` on first Start, non-interactive | Same rule, inverted: never apt-install at runtime for anything the server needs (it vanishes on reboot). Runtime apt is only for the user's own ad-hoc installs inside a session. |
| 7. Serve launch | Executor runs the bootstrap string; `pkill -x opencode` first | Same serve command, typed at the console: `OPENCODE_SERVER_PASSWORD=<pw> opencode serve --port 4096 --hostname 0.0.0.0`. Password via console typing is visible in the console transcript — pipe it instead: write the password to a file only the guest can read before launching, or `export` it from a file the bootstrap sources. Do NOT echo the password into console input that the app logs. `pkill -x opencode` is unnecessary (fresh guest, nothing survives a reboot) — drop it. |
| 8. Stop | `stopEngine` (generation bump, health timer off) | `api->request_stop()` + stop the bridge (§4) + invalidate the health timer. Note the run() contract: a host stop returns an error from `run()`, not 0 — treat "stopped by host" as a clean stop, not a failure. |
| 9. Mac build | `build-core.yml`: meson LinuxRunner core + libarchive, `build-core.sh` | New workflow (copy `build-core.yml`, do not edit it in place): clone Kernarium at `fbe12ee`, run `scripts/package-ios-frameworks.sh --sdk device`, take `KRuntime_6_18_4K.framework` from `.build/kernarium-xcframeworks/`, copy the three GPU frameworks from the Andarium release IPA (or from the same script's output if it emits them), then link with `-F Frameworks -framework KRuntime_6_18_4K -framework KosmicKrisp -framework MesaEGL -framework MesaGallium -rpath @executable_path/Frameworks`, `-miphoneos-version-min=27.0` (the frameworks declare MinimumOSVersion 27.0 — the app's 15.0 floor must rise to 27.0), embed the four frameworks in `Payload/OpenCode.app/Frameworks/`, strip `_CodeSignature` dirs (installer re-signs). Verify step: `nm`/`otool` for `kernarium_runtime_get_api_v28` in the binary + framework presence in the IPA. Entitlements: SideStore install with a development profile for Increased Memory Limit + Extended Virtual Addressing (adhoc cannot grant them; same requirement as TermX). |

## 4. How the app talks to the server — the correction to the brief

**The brief's "same 127.0.0.1:4096, UI and server client do not change"
is the goal, not a given. It does NOT work by default, and the
implementer must build the bridge below. Do not ship assuming
loopback reaches the guest.**

Why: the LinuxRunner guest shares the host's loopback (that is why
`--hostname 0.0.0.0` + `127.0.0.1:4096` works there). The Kernarium
guest does not. Its network is libslirp user-mode NAT
(`darwin/device/network/slirp/provider.hpp`): network `10.0.2.0/24`,
guest DHCP lease `10.0.2.15`, host alias `10.0.2.2`, nameserver
`10.0.2.3`. The guest's `127.0.0.1` is its own loopback, unreachable
from the host, and the host cannot open a TCP connection to
`10.0.2.15` — slirp only forwards outbound guest traffic. The slirp
provider has a host-forward mechanism (`HostForward`, `add_forward` —
host `127.0.0.1:HOSTPORT` → guest `10.0.2.15:GUESTPORT`, the same idea
as QEMU `-hostfwd`), **but it is not in the public C API**:
`kernarium_runtime_api` (v28, `KernariumRuntime.h`) exposes no
add-forward function and `kernarium_runtime_boot` has no forward field.
The macOS launchers' `--vsock-forward` is test tooling, not an iOS API.

The design that keeps `OCServerClient` and the whole UI untouched:

1. **Guest side (bake into the image): a vsock→TCP proxy.** The guest
   listens on a vsock port (e.g. 4096) and forwards each connection to
   `127.0.0.1:4096` where OpenCode listens. `socat` in Debian trixie
   supports `VSOCK-LISTEN` — add `socat` to `configure-rootfs.sh` and
   run it from a systemd unit (or from the console bootstrap, before
   the serve launch): `socat VSOCK-LISTEN:4096,fork TCP:127.0.0.1:4096`.
   Verify on the bench that trixie's socat actually has vsock support;
   if not, a ~100-line C proxy using the guest's vsock socket API is
   the fallback. This is the single most uncertain piece — see §6.
2. **Host side (new, small, in `KernGlue` or a new `OCVsockBridge`):
   a loopback TCP listener on `127.0.0.1:4096`.** For each accepted
   connection, call `api->connect_vsock(4096, timeout_ms)` (blocking —
   call off the main thread; returns a connected `SOCK_STREAM` fd the
   caller owns, max 32 connections, `-ECONNREFUSED` if nothing listens
   yet) and pump bytes both ways until either side closes (guest
   half-close arrives as `shutdown(SHUT_WR)` — poll/kqueue, do not rely
   on a blocking read returning 0; see `docs/architecture.md`, "Local
   stream sockets"). This is the exact pattern Andarium/KTerm already
   use for ADB: host `connect_vsock(5555)` → adbd in the guest
   (`darwin/device/vsock/README.md`: guest CID 3, host CID 2, stream
   sockets only, guest-initiated connections are RST).
3. **Then, and only then, the contract holds:** `OCServerClient`
   keeps talking `NSURLSession` to `http://127.0.0.1:4096` with Basic
   auth `opencode:<password>`, SSE via `GET /api/event`, health via
   `GET /api/info`. No change to `OCServerClient.m`, `OCSettings.m`,
   any view controller, or the startup screen. The bridge is
   transparent to them — including the health timer's 5 s / 3-strike
   restart and the SSE auto-reconnect (each reconnect is a new
   loopback connection → a new vsock stream; vsock handles that).
4. **Ordering:** start the bridge listener before the guest boots (so
   `127.0.0.1:4096` is claimed early and health checks fail fast with
   connection-refused rather than hanging), and only mark the server
   "listening" when the guest-side proxy answers — the `server
   listening` marker (§5) must come from the guest, not from the
   bridge accepting a socket.

Alternative considered and rejected: point `OCSettings.serverURL` at
`10.0.2.15:4096` — does not work (host cannot initiate to the guest
through slirp). Alternative if the vsock proxy proves unworkable:
rewrite `OCServerClient` onto raw sockets over a vsock fd — a much
bigger change that touches every API call and the SSE parser; only if
the bridge fails on device.

## 5. Startup screen mapping (five rows, `OCStartupViewController.m`)

The screen needs **no code change** if the guest keeps emitting the
same `PROGRESS` lines with the same thresholds — but the lines can no
longer come from the exchange bind mount (there is no bind mount in
Kernarium; no host-shared directory was found in the public API).
They must come over the console instead: the console callback in
`KernGlue` watches guest output and feeds `OCEngine`'s existing
`setServeProgress:status:` / `appendEngineLog:` paths. Concretely, the
console bootstrap (typed at the autologin shell, §3 step 4) echoes
the same lines the old bootstrap wrote to serve.log, and the console
callback parses `PROGRESS <pct> <message>` / `ERROR ...` /
`server listening` out of the stream. `OCEngine.pollServeLog` (file
polling) is replaced by this callback feed; its monotonic rule and the
`server listening` = definitive-start rule stay verbatim.
`fullLogText`'s three sections become engine.log + guest boot.log (now
the console transcript the app captures) + serve.log (same transcript,
or drop the split and keep one guest log — implementer's call, keep
the Log screen working either way).

| Row | Done when (unchanged thresholds) | New source of the signal |
| --- | --- | --- |
| Engine core | `guestCoreLinked` | Kernarium framework loaded + `kernarium_runtime_get_api_v28()` non-null. Detail: "Linked, ready to boot". |
| Guest boot | progress > 0.05, or Running | Console saw `UML_BOOT_SWITCH_ROOT:/sbin/init`, then `login: `. Bootstrap writes `PROGRESS 5 Guest up` at that point. Detail: "Debian 13 guest" (image is trixie = Debian 13 — keep the label). |
| Node | progress ≥ 0.55, or Running | `command -v node` check in the console bootstrap → `PROGRESS 55 Node ready`. Node is baked in (§3 step 5), so this is a check, not a download. |
| OpenCode | progress ≥ 0.85, or Running | `command -v opencode` check → `PROGRESS 85 OpenCode ready`. OpenCode is baked in. Tools check (git/python3/gh/jq/rg/bun) → `PROGRESS 88/89` as today, but as checks only — no apt at boot. |
| Server | state Running | Guest prints `server listening` (OpenCode's own line, forwarded through the console callback) AND the vsock proxy answers. Detail stays "Listening on 127.0.0.1:4096" — true from the app's side through the bridge (§4). Dismiss 0.7 s after Running, as today. |

Failure rows stay as today: core not linked → red outline "Not ready
in this build"; setup not done → "Setup needed"; Error → "Engine
error". The "setup" the screen waits on is now the image download
(§3 step 1), not the `.deb` cache.

## 6. app.py auto-start equivalent

Same idea, new delivery. In the console bootstrap, after the Node /
OpenCode checks and before the serve launch:

```sh
if [ -f /root/Projects/app.py ]; then
  (cd /root/Projects && nohup python3 app.py > server.log 2>&1 &)
  echo "app.py started"
fi
```

Same guards: file must exist, detached with `nohup … &`, never fails
the engine start, never kills an older app.py. **But the file itself
is the problem: `/root/Projects` does not persist** (§7). On the first
Kernarium build there is no `/root/Projects/app.py` to find unless the
user's project is baked into the image or restored at boot — so the
auto-start is a no-op until persistence is solved. Do not claim it
works on day one; wire the command, log "app.py started" or "no
app.py in guest" to the console, and treat the restore step as part
of the persistence work below. Test the same way as today: in a guest
shell, `curl -s http://127.0.0.1:8000 | grep -o 'Hello from Python'`
— noting that "in a guest shell" now means typed at the console, and
port 8000 is guest-local unless a second vsock forward is added
(same bridge pattern, guest vsock port 8000 → `127.0.0.1:8000`).

## 7. Open risks

- **Persistence — the biggest product risk, unsolved.** The overlay is
  formatted fresh every boot, the rootfs is read-only, and no
  host-shared folder / 9p / virtio-fs mechanism was found in the public
  runtime API or the TermX work. That means, as designed here:
  OpenCode sessions and chat history, provider logins/keys stored in
  the guest, and `/root/Projects` (including app.py) **vanish on every
  app relaunch**. The LinuxRunner build persists all of it in fakefs.
  Option A (recommended to prototype first): sync state out over vsock
  before stop and back in at boot — a small guest-side agent + host
  transfer, new code on both sides, fragile around kills (iOS jetsam
  gives no chance to sync). Option B: accept ephemeral sessions
  (provider login every launch, no history) — honest but a real
  downgrade; do not ship this silently. Option C: verify whether the
  runtime offers a persistent disk the public header does not show
  (check `darwin/` sources for a second writable disk on Linux guests;
  the Android flavour has `android_data_disk_path`, Linux has only
  `rootfs_path` + `overlay_path`). **Do not merge the rebuild until
  persistence has an answer.**
- **The vsock bridge is unproven.** No guest has run a vsock→TCP proxy
  in this runtime yet; trixie socat's vsock support is assumed, not
  verified; the 32-connection cap, half-close behaviour, and SSE
  long-lived streams over vsock are all untested. If it fails, the
  fallback is rewriting `OCServerClient` onto raw vsock fds (§4).
  Prototype the bridge standalone (guest proxy + host listener) before
  touching the app.
- **Boot time: no number exists.** Nothing in the TermX work or
  upstream docs gives a measured boot time for a Debian guest; systemd
  + 1024 MiB + interpreted userspace will be slower than the
  LinuxRunner guest, and the first boot also formats the overlay and
  starts systemd-networkd. Expect the startup screen to sit on "Guest
  boot" noticeably longer; measure on device and only then set any
  timeout (do not invent one now). Node/OpenCode being baked in removes
  the old 139 MB first-Start download from the boot path, which helps.
- **Node under the interpreter will be slow.** The kernel runs natively
  (real 6.18), but Node/OpenCode/dockerd run in the iSH-style threaded
  gadget interpreter (`use_jit=0`). Upstream's own measurements put
  JIT-less gadget execution well below native for CPU-bound work
  (their optimization history notes gadget runs 2–10× slower than JIT
  on some workloads). OpenCode is mostly I/O + model waiting, so it
  should be usable, but prompt/tool latency will be worse than the
  LinuxRunner build, which is the same interpreter class — expect
  parity, not an improvement. Do not claim a speed win.
- **Docker: possible, not proven — verdict YES with limits.**
  Evidence from the shipped kernel config
  (`kernarium-termux/kernel-config-android-6.18.60.txt`, Linux 6.18.60,
  extracted via IKCONFIG from `KRuntime_Android_6_18_4K`; the Linux
  kernel is the same shared fragment
  `kernel/common/config/darwin-uml.fragment` + the Linux overlay
  `kernel/mainline-6.18/config/mainline.fragment` instead of the
  Android overlay):
  namespaces all `y` (`CONFIG_NAMESPACES`, `USER_NS`, `PID_NS`,
  `NET_NS`, `IPC_NS`, `UTS_NS`, `TIME_NS`); cgroups all `y`
  (`CONFIG_CGROUPS`, `CGROUP_SCHED`, `FAIR_GROUP_SCHED`,
  `CFS_BANDWIDTH`, `MEMCG`, `BLK_CGROUP`, `CGROUP_PIDS`,
  `CGROUP_FREEZER`, `CGROUP_DEVICE`, `CGROUP_CPUACCT`, `CGROUP_PERF`,
  `CGROUP_MISC`, `CGROUP_BPF`, `CGROUP_NET_PRIO`, `CGROUP_NET_CLASSID`,
  `CPUSETS`); storage `CONFIG_OVERLAY_FS=y`, `EXT4_FS_POSIX_ACL=y`,
  `EXT4_FS_SECURITY=y`, `BLK_DEV_LOOP=y`, `BLK_DEV_DM=y`,
  `DM_THIN_PROVISIONING=y`, `FUSE_FS=y` (plus `XFS_FS`/`BTRFS_FS` `y`
  in the Linux overlay); networking `VETH=y`, `BRIDGE=y`,
  `BRIDGE_NETFILTER=y`, `MACVLAN=y`, `TUN=y`, `IPV6=y`;
  netfilter/NAT `NF_CONNTRACK=y`, `NF_NAT=y`, `NF_TABLES=y`,
  `NETFILTER_XTABLES=y`, `IP_NF_IPTABLES/FILTER/NAT=y`,
  `IP_NF_TARGET_MASQUERADE=y` (plus `IP6_NF_NAT=y` in the Linux
  overlay); `SECCOMP=y`, `SECCOMP_FILTER=y`, `BPF_SYSCALL=y`,
  `CHECKPOINT_RESTORE=y` (Linux overlay). The base fragment's own
  comment says this path is there for Docker. So a plain
  `docker run` on the default bridge should work in principle.
  Limits, also from the config: `# CONFIG_IP_VS is not set`,
  `# CONFIG_VXLAN is not set`, `# CONFIG_IPVLAN is not set`,
  `# CONFIG_MACVTAP is not set`, `# CONFIG_VLAN_8021Q is not set`
  (no Swarm ingress/overlay, no ipvlan/macvtap/VLAN drivers —
  macvlan works); `# CONFIG_RT_GROUP_SCHED is not set`,
  `# CONFIG_BLK_DEV_THROTTLING is not set`, `CGROUP_HUGETLB` absent
  (no `--cpu-rt-runtime`, no blkio throttling, no hugetlb limits);
  IPv6 NAT degraded (`IP6_NF_TARGET_MASQUERADE` likely `n`).
  Practical limits on top: 1024 MiB guest RAM (hello-world/alpine
  fine, large images will OOM — raise the guest RAM only if the
  memory entitlements allow it); dockerd/containerd/runc all run
  interpreted, so they will be slow; pulled images live in the
  overlay and **vanish on reboot** (`docker.io` itself is baked into
  the image, images are not). And the honest caveat: **no guest has
  run dockerd in this runtime yet** — the README's "capable of running
  Docker" is a claim, not a device result. First device test must be
  `sudo docker run hello-world`.
- **LiveContainer: NO for a second run in the same process — verdict.**
  Upstream `docs/architecture.md`, "Runtime ownership": "A process
  runs one guest at a time. After a kernel has claimed guest RAM, a
  later run is refused until the guest has been handed back…
  A failed or host-stopped guest cannot be released and requires a
  fresh process." The public header says the same for `run()`: for
  Android, 0 means the guest powered off cleanly and "another run may
  start in this process"; a host stop or unreported shutdown returns
  an error (no clean hand-back). LiveContainer dlopen's the guest into
  its own process, so: a **first** run inside a fresh LiveContainer
  launch should work in principle (one guest, one process, same as
  standalone), but after any stop, crash, jetsam kill, or failed boot
  the engine **cannot be started again without killing LiveContainer
  and relaunching it**. The Engine tab's Stop → Start cycle, and the
  health timer's auto-restart after 3 failed checks, both break under
  LiveContainer in exactly this way. Extra LiveContainer hazards:
  the guest bundle is patched (`__PAGEZERO`, `MH_EXECUTE`→`MH_DYLIB`,
  `TweakLoader.dylib` injected) and re-signed — four embedded
  frameworks must survive that untouched (untested); guest
  entitlements are not applied, so the Increased Memory Limit +
  Extended Virtual Addressing the 1024 MiB guest wants may not be
  there; MinOS rises to 27.0. **Do not present LiveContainer as a
  supported path for this engine; standalone sideload is the target,
  LiveContainer is a one-shot demo at best.**
- **GPL-2.0-or-later copyleft.** Upstream is GPL-2.0-or-later
  (`~/workspace/kernarium/LICENSE`, `LICENSES/`); the runtime is
  linked into the app, so the shipped app is a GPL derivative: its
  source must travel with any distribution of the IPA (TermX already
  carries `LICENSE-GPL-2.0` + SPDX headers for this reason). The
  OpenCode app is currently a private repo (`spyboi-dev/opencode-ios`);
  distributing the Kernarium IPA without the corresponding source
  (app + the framework build inputs) would breach the licence. The
  NewTerm-modelled UI is Apache-2.0, not an issue here. Decide before
  release whether the repo goes public or distribution stays private.
- **Dependencies the rebuild inherits from TermX (all still open).**
  The Linux framework must be Mac-built (§2); the Debian image build
  is unfinished with TODO hashes (§2); the image URL/release does not
  exist yet; nothing has booted or run on a device. The Kernarium
  rebuild is therefore gated on TermX's two blockers, not just its own
  code.
- **iOS lifecycle unchanged:** the guest dies when iOS suspends/kills
  the app; files persist only where the persistence work (§7) puts
  them; the server restarts on return — except under LiveContainer it
  cannot restart in the same process (see above). Background GPU hold
  (`set_gpu_hold`) is TermX's pattern for backgrounding; the OpenCode
  app has no visible guest, so hold on background / release on
  foreground is still worth wiring in `KernGlue`.

## 8. Implementer checklist (in order)

1. Mac-build `KRuntime_6_18_4K.framework` (`package-ios-frameworks.sh
   --sdk device`); confirm the three GPU frameworks come with it or
   from the Andarium IPA. (Blocked until a Mac is available.)
2. Finish the TermX Debian image; add Node 22.23.5, OpenCode 2.3.0,
   `gh jq ripgrep bun socat` to `configure-rootfs.sh`; publish the
   `.ext4.gz` + SHA256SUMS; fill in the hashes.
3. Prototype the vsock bridge standalone: guest `socat
   VSOCK-LISTEN:4096,fork TCP:127.0.0.1:4096` + host loopback listener
   → `connect_vsock(4096, …)` byte pump; prove `curl
   http://127.0.0.1:4096/api/info` answers through it, and an SSE
   stream survives.
4. Solve persistence (§7) or record the accepted downgrade explicitly.
   Do not merge without this decision.
5. Write `src/KernGlue.h/.m` (boot, console callback → PROGRESS feed,
   console-typed bootstrap, vsock bridge, `request_stop`); rewire
   `OCEngine` to it behind the new define; delete the `.deb` setup
   path and `CoreGlue`; update `AppDelegate.m` (register KernGlue,
   same auto-start call); keep `OCStartupViewController`,
   `OCServerClient`, and every other view controller untouched.
6. New Mac workflow (copy of `build-core.yml`): Kernarium clone at
   `fbe12ee` → framework packaging → link + embed four frameworks →
   verify `kernarium_runtime_get_api_v28` in the binary → IPA.
   MinOS 27.0; SideStore dev-profile install (memory entitlements).
7. Device tests, in order: guest boots to `login: `; Node/OpenCode
   checks pass; `opencode serve` answers via the bridge;
   `GET /api/info` + one chat prompt + SSE; app.py auto-start (once
   persistence lands); `sudo docker run hello-world`; Stop → Start
   (standalone); kill app → relaunch → auto-start. LiveContainer:
   first-run only, expect no restart-in-place.
8. Desktop + background tests: boot straight into the desktop
   (`DESKTOP READY` completes the startup screen, Show desktop
   opens the window, a tap clicks, typed text lands); background
   the app with Always location granted (engine keeps running,
   location arrow shows, return to foreground resumes); deny
   location (engine stops with the app, as before). (No mode
   switching any more — CLI mode was removed 2026-11-25.)

## PERSISTENCE-TODO (the biggest product risk, unsolved)

Status 2026-11-20: sessions, provider logins/keys stored in the
guest, and `/root/Projects` (including `app.py`) VANISH on every
app relaunch on this branch. The overlay is formatted fresh every
boot, the rootfs is read-only, and no host-shared folder / 9p /
virtio-fs mechanism exists in the public runtime API. The
LinuxRunner build persists all of it in fakefs; this one does not.
Nothing in this branch fakes persistence: the app.py auto-start
command is wired, but on the first build there is no `/root/Projects/
app.py` to find, so it logs "no app.py in guest" and carries on.

The design note's Option A (recommended to prototype first) is still
the plan: sync state out over vsock before stop and back in at
boot — a small guest-side agent (a daemon in the image listening on
its own vsock port, e.g. 4097) plus a host transfer in `KernGlue`.
What it must carry, at minimum: OpenCode's session store, provider
auth (the files under the guest's OpenCode config dir), and
`/root/Projects`. The runtime's own `sync()` (wired in `KernGlue`
as `syncGuestWithCompletion:`, and called best-effort on stop) does
NOT solve this: it only flushes the overlay file to the host disk,
and the next boot formats that overlay fresh anyway.

Why it is not in this branch yet: the guest-side agent has to be
baked into the image (which does not exist yet), the transfer
protocol has to be written on both sides, and it is fragile around
kills — iOS jetsam gives no chance to sync before dying, so a kill
mid-session still loses the tail. A complete answer also needs a
periodic sync while the engine runs, not just one at stop. None of
that is verifiable without a booting guest, so it is recorded here
instead of half-built.

Do not merge the rebuild until persistence has an answer (Option A
prototype, or an explicit accepted downgrade to ephemeral sessions
with provider login every launch — honest, but a real downgrade,
and never shipped silently).

## Background (location keep-alive)

The app asks for Always location so iOS keeps it running in the
background instead of suspending it, and with it the in-process
guest engine. Implemented on the branch: `UIBackgroundModes`
`location` in `Info.plist`, a `CLLocationManager` in `AppDelegate`
(requests Always authorisation on launch, starts updates only once
granted), plain-words prompt copy
(`NSLocationAlwaysAndWhenInUseUsageDescription` /
`NSLocationWhenInUseUsageDescription`: the engine stays up while
the app is in the background; location is never stored or sent).
Fixes are never used for anything: the delegate drops them. The
guest's GPU requests are held on entering the background
(`set_gpu_hold(1)`) and released on return, the TermX pattern —
the host GPU is revoked within seconds of backgrounding.

Honest caveats, all still true:

- iOS can still terminate the app under memory pressure. Location
  keep-alive is not a guarantee; it is a strong hint that iOS
  honours while memory allows. A jetsam kill still kills the guest,
  and (see §7) the guest then cannot be restarted in the same
  process — the user relaunches the app and auto-start boots it
  again.
- The location arrow shows in the status bar while updates run.
  That is the visible price of the keep-alive, and the prompt copy
  says what it is for.
- Battery cost: continuous location updates with
  `kCLLocationAccuracyThreeKilometers` and no automatic pausing
  cost more than a suspended app. Coarse accuracy keeps it small,
  but it is not free.
- LiveContainer fit is unverified: the guest bundle is patched and
  re-signed, entitlements are not applied, and background modes in
  a LiveContainer guest are untested. Standalone sideload is the
  target; treat LiveContainer background behaviour as unknown.
- If permission is denied (or only When-in-use), the app still
  works; the engine just stops with the app, as before. Nothing
  nags the user again.

## Engine modes: CLI vs Desktop UI (both in the app, user picks)

UPDATE 2026-11-25: the user removed the CLI mode. Desktop UI
only now: the engine always boots the desktop app (its server on
4096 plus the window), Install has no mode choice, and
`oc.engineMode` is deleted. The CLI-mode description below is
history, kept for reference.

The user asked for both, not one. The Engine tab has a segmented
control, "CLI" / "Desktop UI". The choice is persisted in
`OCSettings` (`oc.engineMode`), default CLI. Switching modes while
the engine is running or starting restarts the engine in the new
mode; otherwise it takes effect on the next start. Both modes keep
auto-start on launch, the startup screen's five rows, the Log button
and the Engine tab's live log, and the app.py auto-start in the
console bootstrap.

### CLI mode (default, the engine)

The guest runs `opencode serve` and the native iOS UI talks to its
HTTP API at `127.0.0.1:4096` through the vsock bridge (§4). This is
the behaviour the whole app was built around: Threads, chat, Files,
health checks, SSE events. The CLI itself needs no key, and models
can run through free logins (Nous Portal OAuth, OpenRouter free
models) without a paid key — but be precise about "no APIs": the
model still needs internet to its provider, and OpenCode 2.3.0's
websearch providers still need their own API key each. Do not claim
zero keys anywhere.

### Desktop UI mode (the real OpenCode desktop app, with its window)

The real OpenCode Linux desktop app (official, Linux ARM64 `.deb` /
AppImage, OpenCode 2 line) runs in the guest and its window shows
on the phone through the guest display path. An earlier note in
this design said a desktop GUI has no display on iOS; that was
wrong, and the user was right to correct it. Verified from the
repo itself (`~/workspace/kernarium`):

- `README.md:24`: the runtime is "capable of running advanced
  workloads including Docker containers, Linux desktops, Wine/Proton
  and a full Android system at decent speed on modern iOS devices".
- `docs/graphics.md`: the full display path is guest Mesa ->
  Virtio-GPU/Virgl -> virglrenderer -> Mesa Zink over KosmicKrisp
  -> `MTLTexture` -> UIKit, a desktop OpenGL 4.6 core context, with
  X11 under Xwayland. The guest sees a Virgl GPU (OpenGL ES 3.2).
- `Kernarium/README.md` ("Guest storage", "Guest boot"): the
  default Linux guest image is a KDE desktop
  (`kde-20260929-r2.erofs`), booting to `graphical.target` with
  SDDM autologin into Plasma; `tools/rootfs/desktop/` derives the
  KDE / Phosh / postmarketOS desktop images. A Linux desktop in
  this guest is a supported, first-class configuration, not a hack.
- The desktop app itself is an Electron window that runs OpenCode's
  server on a loopback port and talks to it — the same agent as the
  CLI, with a window instead of a terminal.

How its window surfaces in our app: `run()` already takes the
MTKView the guest renders into. In Desktop UI mode that view is no
longer hidden behind the tab bar: the Engine tab's "Show desktop"
button (visible once the desktop is up) pushes
`OCDesktopViewController`, which moves the same view into its own
full-screen layout and parks it behind the tab bar again on
leaving. Input is tap/drag as touch (`send_touch`, slots 0..9,
coordinates 0..32767) plus the iOS keyboard forwarded as Linux key
codes (first version: printable ASCII, Enter, Backspace). There is
no mouse cursor yet: a tap is a click where the finger lands.

What it needs in the guest (baked into the image by
`rootfs-build/opencode-guest-additions.sh`): Xorg + openbox, the
OpenCode desktop `.deb`, and `opencode-desktop.service` (disabled
by default). The console bootstrap starts the service in Desktop
UI mode, waits for the app process + the X socket, and prints
`DESKTOP READY` — the desktop mode's equivalent of `server
listening`, completing the startup screen at 1.0 and flipping the
state to Running. In CLI mode the bootstrap stops the service, so
a mode switch does not leave a desktop holding the display.

### Verdict: CLI stays the engine; Desktop UI is a second surface

The desktop app CAN run with its UI in the guest, and the display
path to show it is real and documented. But it is not the better
engine for this app, and the CLI stays the engine (and the fallback
for any desktop experiment):

1. Our native iOS UI already talks to `opencode serve`'s API. The
   desktop app is a second UI over the same agent (its Electron
   window talks to its own loopback server), so it adds no
   capability the native UI lacks — it duplicates the surface.
2. It costs more guest resources for the same agent: an Electron
   window + X + a compositor inside a 1024 MiB interpreted guest,
   on top of the server it already runs.
3. It needs input plumbing the CLI mode does not: touch, keyboard,
   and eventually a real pointer, all of it new and unproven on
   device (the first version is tap-to-click + typed characters).
4. It needs a graphical guest (X + window manager + the desktop
   `.deb` in the image), where the CLI mode is happy with the text
   `multi-user.target` image.

So: build the CLI engine first, keep Desktop UI as the selectable
second surface for users who want the real desktop window (and for
desktop-only features if any appear), and do not present the
desktop app as the engine. First device test for Desktop UI mode:
the desktop window appears, a tap clicks, typed text lands, and
`DESKTOP READY` completes the startup screen.

REVERSED 2026-11-25 by the user: CLI mode is removed, Desktop UI
only. The desktop app is now the engine's surface (server + window
together); the native Threads/Integrations tabs stay and talk to
the same server.

### Restart-in-place is unproven (affects mode switching too)

Switching modes restarts the engine, and the health timer
auto-restarts a dead engine the same way. Upstream's own docs
(§7) say a host-stopped guest cannot be released and a later run
in the same process is refused until the guest has been handed
back — which a host stop never does. So Stop -> Start, and a mode
switch, may fail on device until the app is relaunched. The code
attempts the restart and surfaces the error honestly; the device
test decides whether a relaunch is required. Do not claim
restart-in-place works until that test passes.
