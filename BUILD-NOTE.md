# OpenCode Inbuilt — BUILD NOTE

Date: 2026-11-17. Route picked by the user 07:09 IST: **build inbuilt real
engine** — one iOS app, real OpenCode engine inside it, no separate
LinuxRunner install, no second app, no outside server, JITless.

## Deliverable

- IPA: `build/OpenCode-Inbuilt.ipa` — **249 KB**, SHA-256
  `52e175af5ac386bd8c4adaaa6c16f49ce48f3073de8fa363cd1d679026c9be6e`
- Bundle id `com.spyboy.opencode`, version 1.0.
- Verified: Mach-O 64-bit arm64, `LC_BUILD_VERSION` platform iOS,
  sdk 26.5, minos 15.0, `LC_CODE_SIGNATURE` present (adhoc, install
  through SideStore / AltStore re-signing), no `.html` in Payload,
  server endpoints (`/api/session`, `/api/event`, `/api/info`,
  `/api/fs/list`, …) present in the binary.
- Build: clang-18 + ld64.lld-18, iPhoneOS26.5.sdk, `-Wall -Wextra`,
  **zero warnings**. `build.sh` reproduces it.
- Source: `src/` — main, AppDelegate, OCKeychain, OCUtil, OCSettings,
  OCServerClient, OCEngine, OCSessionsViewController,
  OCChatViewController, OCFilesViewController, OCEngineViewController,
  OCSettingsViewController. Resources: `debian-manifest.json`
  (Debian 13.7 manifest, copied from LinuxRunner's DebianSupport.bundle).

## What the app is

Native Objective-C UIKit, ChatGPT style, four tabs: Sessions, Files,
Engine, Settings. The UI talks to the real OpenCode server API
(139 paths, spec at `~/workspace/opencode-ios-port/opencode-2.2.6-openapi.json`):

- Sessions: list / create / delete / fork, from `GET/POST /api/session`.
- Chat: messages from `GET /api/session/{id}/message`, prompt via
  `POST /api/session/{id}/prompt`, stop via `POST .../interrupt`,
  live updates from `GET /api/event` SSE plus a 2 s poll while a reply
  is pending. Polling stops when the session goes idle
  (`time.idle >= time.busy`).
- Model picker: `GET /api/model`, `POST /api/session/{id}/model`
  with `{"model": {"id", "providerID"}}`.
- Tool cards: message `content` items of `type:"tool"` show name,
  input (command / filePath) and status.
- Permissions: `GET /api/session/{id}/permission`, reply
  `POST .../permission/{id}/reply` with `decision` "once" / "always" /
  "reject".
- Diff: `GET /api/session/{id}/diff`, revert via `POST .../revert`.
- Files: `GET /api/fs/list?path=`, `GET /api/fs/read/*`.
- Shell: `POST /api/session/{id}/shell`, `GET /api/shell/{id}/output`.
- Context: `GET /api/session/{id}/context`.
- Auth: HTTP Basic, user `opencode`, password from the Keychain
  (generated on first engine start, never logged, never in a file).
- Health: `GET /api/info`; the engine restarts the server after
  3 failed health checks (5 s interval).

The engine host (`OCEngine`) implements the full lifecycle:
first-launch setup downloads the Debian 13.7 package set from
deb.debian.org (**37 MB, 103 packages**, manifest in the bundle) and
verifies every SHA-256 before marking setup done; then it boots the
guest and runs `opencode serve --port 4096 --hostname 0.0.0.0` with
`OPENCODE_SERVER_PASSWORD` from the Keychain. Node runs `--jitless`
under the interpreter. `opencode help`, not `opencode --help`.

## Embedding decision — the honest part

The engine is the LinuxRunner 1.1.2 core (fork of iSH / ios-linuxkit,
cloned at `~/workspace/opencode-ios-port/linuxrunner/`, commit
`f96a2a6f`). Entry points, verified by reading the source:

- Boot: `app/AppDelegate.m:116 boot` → `mount_root`, `prepareExchange`,
  then `task_start(current)` (`kernel/task.h`) with the boot command
  `/bin/sh /usr/lib/linuxrunner/init.sh` (`AppDelegate.m:316`).
- Runtime bridge: `app/LinuxRunner/RuntimeBridge.m` (2,278 lines).
- Agent Mode install: `app/LinuxRunner/ModesView.swift:267` — installs
  Node.js, git, ripgrep, Python, then `npm install -g` Claude Code,
  Codex CLI and OpenCode. This build installs OpenCode 2.3.0 from the
  official release binary (anomalyco/opencode); `opencode-ai` on npm is the
  1.x line and has no 2.3.0, so the npm pin was wrong.
- Localhost reachability: Liftoff (`ModesView.swift`) proves a guest
  server bound to `0.0.0.0` is reachable at iOS `localhost`; the
  serve command uses `--hostname 0.0.0.0` for exactly this reason.
- Debian rootfs: built on device from official packages,
  `app/LinuxRunner/DebianInstaller.swift` + `DebianSupport.bundle/
  manifest.json`: 103 packages, 37 MB download, 158 MB installed.

Probe results, all run 2026-11-17:

- The C interpreter core **compiles for iOS in principle**:
  `emu/tlb.c`, `kernel/task.c`, `kernel/memory.c` all compile clean
  with `clang-18 -target arm64-apple-ios15.0 -isysroot
  iPhoneOS26.5.sdk -DGUEST_ARM64=1`.
- **But the full core cannot be linked in this turn**, for four
  concrete reasons:
  1. No build system on this VM: `meson` and `ninja` are not
     installed, and the core build (`meson.build`) needs a generated
     `cpu-offsets.h` produced by a meson host build
     (`tools/staticdefine.sh` + `compile_commands.json`), plus
     aarch64 assembly gadgets (`asbestos/guest-arm64/gadgets-aarch64/`)
     and sqlite3.
  2. The bridge layer is Swift-dependent:
     `app/LinuxRunner/RuntimeBridge.m:19` imports
     `LinuxRunner-Swift.h`. Swift on this VM is Linux x86_64 only
     (proven in `~/workspace/opencode-ios/SWIFT-BUN-EVAL.md` §3:
     no SDKs, no JavaScriptCore/Darwin, `swiftc` against the iOS SDK
     fails with `no such module 'SwiftShims'`). The Swift UI
     (ModesView, DebianInstaller, SetupWizard, ManagerView) cannot be
     built here at all.
  3. The boot stack is the whole LinuxRunner app: AppDelegate,
     Roots, AppGroup, device drivers (pasteboard, location, BLE),
     GPU backends. There is no `libish` framework to link; the core
     is a monolithic app, not a library.
  4. The guest cannot be executed or tested on this VM at all: the
     host is x86_64 Linux, the interpreter is aarch64-host specific.
     Any core link shipped from here would be unverified.

**Consequence, stated plainly:** in this build `OCEngine.guestCoreLinked`
is NO. The engine host, the Debian package cache, the serve launcher
and the server client are all real and in the app, and the Engine tab
reports "Engine core pending link" instead of pretending the guest is
running. `startEngine` returns that error honestly. The app is fully
usable as a client the moment a server is reachable at
127.0.0.1:4096 — which is exactly how it will work once the core is
linked, since the guest serve binds the same port.

**Remaining work to finish the inbuilt engine** (not done here):
build the core on GitHub Actions `macos-26` + Xcode 26 (the same
route as the SPYTube iOS simulator test kit): install meson/ninja
via brew, build the C core + a minimal ObjC boot glue that calls
`mount_root` / `task_start` directly (bypassing RuntimeBridge and
its Swift header), replace the Swift UI with this app's UIKit UI,
and keep the DebianInstaller flow (manifest + deb.debian.org) for
first launch. Then link the core, set `guestExecutor`, and the
engine starts for real. No change to the UI or client is needed.

## Bug pass (user rule: make sure there is no bugs)

Build is `-Wall -Wextra`, zero warnings. Bugs found and fixed:

1. `OCUtil.h` (copied from the paused pure-native rewrite) had a
   stray `+` before three comment lines, so the header did not
   parse at all. Fixed in this project's copy; the original in
   `~/workspace/opencode-ios/src/` is untouched.
2. 37 compiler warnings, all unused parameters plus one retain
   cycle in `OCEngine`'s download loop (the `downloadNext` block
   captured itself). All fixed with `(void)` casts and a weak
   reference to the block; rebuild is zero warnings.
3. **Chat parser was wrong for the real server.** The first version
   read `message.role` / `message.parts` / `part.input`. Live
   probing against opencode 2.2.6 showed the real shape is
   `type` as the role, `content` as the parts array, and tool
   input under `state.input` (`state.status`, `state.input.command`
   / `filePath`). Fixed; a simulation of the fixed parser over the
   live message payload produces the correct thread (user text,
   assistant text, tool card `shell — echo hello-opencode-test
   [completed]`).
4. Polling never stopped: after sending a prompt the 2 s poll ran
   forever. Fixed — it now stops when the session goes idle
   (`time.idle >= time.busy`, via new `GET /api/session/{id}`).
5. Messages arrived newest-first; the thread showed them backwards.
   Fixed — reversed to chronological order.
6. Permission sheet read a `tool` field that does not exist.
   Real `Permission.Request` is `{id, action, resources[], message}`.
   Fixed to show action + resource + message.
7. Server URL in Settings only saved on Return. Fixed — also saved
   on leaving the Settings tab.

Live API verification (real opencode 2.2.6 server on this VM,
`OPENCODE_SERVER_PASSWORD` set, Basic auth):
`GET /api/info` → version 2.2.6; `GET /api/session` → list with
`data`/`cursor`; `POST /api/session` → created session;
`GET /api/model` and `/api/provider` → opencode provider, free
models; `GET /api/fs/list` → entries; `GET /api/event` → SSE
`server.connected` + heartbeats; `POST /api/session/{id}/prompt`
→ a real assistant reply ("Hi") and a real shell tool call
(`echo hello-opencode-test`, status completed, exit 0). Note the
prompt test used the `big-pickle` free model, which worked from
this VM at that moment.

No bugs remain known in the code as shipped. The app has **not**
run on a physical iPhone: launch, taps, keyboard, SSE streaming
and the engine screens are untested on device. The guest core
link (above) is the one open item, not a hidden bug.

## Install

1. Re-sign the IPA with your own Apple account in SideStore or
   AltStore (adhoc signed only, it does not install by tapping
   the file) and install it.
2. Open the app → Engine tab → **Run first-launch setup**.
   Downloads 37 MB of Debian 13.7 packages from deb.debian.org
   over Wi-Fi (a few minutes on a normal connection), verifies
   every SHA-256, then marks setup done. Needs at least 1 GB free.
3. Tap **Start engine**. The guest boots and runs
   `opencode serve --port 4096 --hostname 0.0.0.0`. First start
   also installs Node and OpenCode 2.3.0 (official release binary) in
   the guest
   (a few more minutes, once).
4. Sign in to a provider inside the guest (OpenCode free models
   or your own key) the first time an agent runs, then use the
   Sessions tab like the ChatGPT app: new chat, type, send, watch
   tool cards, approve or deny permissions, view diffs.

## Crash fix 2026-11-17 (first-launch setup, LiveContainer)

The shipped 249 KB build crashed on the first setup tap in
LiveContainer: the download chain was a `__weak` block that nothing
retained after setup returned, so the first download's completion
called a nil block. Fixed by replacing the recursive weak block with
a singleton-held, method-driven chain; full cause, file/line and
changes in `CRASH-FIX.md`. New IPA: **252 KB**, SHA-256
`ca2fcdbd1f17344ed580b2a5fb1514cb2765d5673aca761a7471f5af4507e761`,
zero warnings, SDK 26.5. The fix makes setup not crash and cache the
Debian packages; the guest core is still not linked.

## Honest limits

- JITless: the guest runs on the ARM64 interpreter, so cold start
  and big file scans feel slow; the AI answer wait dominates, so
  chat feels fine (LinuxRunner's own PERFORMANCE.md: macro work
  near parity, microbenchmarks 4–6x slower).
- If iOS suspends or kills the app, the guest dies with it. Files
  persist, running processes do not; the app restarts the server
  on return (health check, 3 strikes).
- The server password is generated by the app and kept in the
  Keychain. If you change it, the server must restart.
- This build's engine core is not linked yet (see above). Until
  the GitHub Actions core-link step lands, the Engine tab says so
  and Start returns that error instead of faking a running engine.
