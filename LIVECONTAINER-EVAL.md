# LiveContainer evaluation for the inbuilt OpenCode app

Date: 2026-11-17. Question: the user said it is possible to run inside
LiveContainer. Checked, not just agreed.

## Verdict: YES for the app as it stands, NO for the engine — and LiveContainer does not fix the engine link

- **The current IPA will run inside LiveContainer as a guest, almost
  certainly.** It is the exact shape LiveContainer guests need: a plain
  Objective-C UIKit app, standard `UIApplicationMain` entry point, no app
  extensions, no special entitlements, no background modes, no URL
  schemes, no push, only system frameworks. This is the same shape as
  LCShell, which already ran inside LiveContainer on this user's iPhone
  (screenshot, 2026-10-23, see §4).
- **But the engine still will not run in it.** The guest core is not
  linked (`OCEngine.guestCoreLinked` is NO, see
  `~/workspace/opencode-inbuilt/BUILD-NOTE.md`, "Embedding decision").
  LiveContainer does not change that at all: it launches a finished IPA,
  it does not compile anything. The Engine tab will still say "Engine
  core pending link" inside LiveContainer, exactly as it does standalone.
  The UI will work as a client the moment a server is reachable at
  127.0.0.1:4096.
- **LiveContainer does not solve the core-link problem, and it adds one
  new constraint of its own** (see §3): the core must still be built on
  macOS/Xcode (meson + Swift bridge), and it must be statically linked
  into the IPA before import, because a guest is dlopen'd, not installed.
  What LiveContainer *does* help with: once the core is linked, the
  resulting IPA should also run as a guest, because the core is
  in-process threads plus read/write memory, needs no host process
  spawning and no JIT in interpreter mode — and localhost is trivially
  shared, since guest and UI are the same process.

## 1. LiveContainer, current state (checked 2026-11-17)

Source: LiveContainer README, fetched 2026-11-17 from the mirror
(`raw.githubusercontent.com/LiveContainerMirror/LiveContainer/main/README.md`,
HTTP 200; the official raw URL also returned 200 that day, so the
shadowban affects the GitHub web UI, not raw file serving — verified by
curl, see §5).

- What it is: "an app launcher (not emulator or hypervisor) that allows
  you to run iOS apps inside it", one sideload slot, unlimited guests,
  multiple versions and multiple data containers per app.
- How a guest runs (README, "How does it work?"): it patches the guest
  executable — `__PAGEZERO` vmaddr to `0xFFFFC000`, vmsize to `0x4000`,
  `MH_EXECUTE` to `MH_DYLIB`, injects a load command for
  `TweakLoader.dylib` — patches `NSBundle.mainBundle` to the guest
  bundle, then calls `dlopen` on the guest executable, finds the entry
  point and jumps to it. The guest entry point calls
  `UIApplicationMain` and starts like any other iOS app.
- JIT: optional. Below iOS 26, JIT available means codesigning is
  entirely bypassed. Otherwise (JIT-less mode, the default) the app is
  signed with the same certificate used by LiveContainer (ZSign, shipped
  in LiveContainer). Requires SideStore for both modes.
- Keychain: "Multi-Account support & Keychain Semi-Separation — 128
  keychain access groups are created and LiveContainer allocates them
  randomly to each container of the same app."
- Limitations (README, verbatim in substance): guest entitlements are
  not applied to the host; app permissions are globally applied; guest
  containers are not sandboxed — one guest can access another guest's
  data; app extensions are not supported (cannot be registered:
  LiveContainer is sandboxed, SpringBoard does not know the apps, they
  take up App IDs); remote push notifications do not work; querying
  custom URL schemes might not work. The README also warns that
  third-party closed-source builds have full access to guest data,
  including keychain items and login credentials.
- Multitasking: multiple apps at once in in-app windows, iOS 16+.
  Requires "Keep App Extensions" when installing LiveContainer via
  SideStore/AltStore (that is about the *host's* extension, not the
  guest's). JIT for multitasked apps needs a PID-attaching enabler
  (StikDebug).
- iOS 27: 3.8.0 (2026-07-17) added iOS 27 developer-beta support
  (#1394, #1417, #1416). The fork README claims iOS 27 Beta 1 tested
  for standalone and SideStore builds, with reverse-engineering fixes
  for dyld/shared-cache changes. **"Spoof SDK Version is BROKEN on
  iOS 27"** — Apple removed/renamed the `sVersionMap` structures; the
  toggle must stay disabled on iOS 27 until a workaround is found.
  Our IPA is built against SDK 26.5 with minos 15.0, so no spoofing
  should be needed; that is untested on iOS 27 final.
- GitHub status: on 2026-10-04 GitHub hid the LiveContainer
  organisation and the lead developer's account (khanhduytran0). Last
  official build is Nightly 20260918, reported as version 3.8.10,
  mirrored at LiveContainerMirror/LiveContainer. iOS 27 support is
  shaky in the field: issue #1621 (LiveContainer/LiveContainer) reports
  all guest apps crashing immediately on iPhone 18 Pro Max, iOS 27.0,
  with 3.8.10, fixed only by a later nightly (4dbe0f9). So iOS 27
  guest behaviour is device/build dependent, not guaranteed.

## 2. Our app against the LiveContainer guest checklist

Checked file by file on 2026-11-17. IPA:
`~/workspace/opencode-inbuilt/build/OpenCode-Inbuilt.ipa`, 249 KB,
SHA-256 `52e175af5ac386bd8c4adaaa6c16f49ce48f3073de8fa363cd1d679026c9be6e`.

| Check | Result | Evidence |
|---|---|---|
| Entry point | PASS. Standard `UIApplicationMain` | `src/main.m`: `UIApplicationMain(argc, argv, nil, NSStringFromClass([OCAppDelegate class]))` |
| App extensions | PASS. None. IPA has 10 files, no `.appex` | `unzip -l` of the IPA: only `Payload/OpenCode.app/` with the executable, Info.plist, icons, `debian-manifest.json`, PkgInfo |
| Entitlements | PASS. None needed, none embedded | No `.entitlements` file in the project; `build.sh` links with `-adhoc_codesign` only, no entitlements flag; Info.plist has no App Group, no keychain group, no associated domains |
| Info.plist | PASS. Plain app | `src/Info.plist`: `CFBundleIdentifier com.spyboy.opencode`, `CFBundlePackageType APPL`, portrait+landscape, `NSAppTransportSecurity.NSAllowsLocalNetworking = true`. No `UIBackgroundModes`, no `CFBundleURLTypes`, no `UISupportsDocumentBrowser` |
| Frameworks | PASS. System only | `llvm-otool-18 -L`: UIKit, Foundation, CoreFoundation, libobjc, Security, CoreGraphics, QuartzCore, libSystem. No private frameworks, no embedded frameworks |
| `__PAGEZERO` | PASS. Patchable, standard shape | `llvm-otool-18 -l`: `__PAGEZERO` vmaddr `0x0`, vmsize `0x100000000` — exactly what LiveContainer rewrites to `0xFFFFC000` / `0x4000` |
| Binary type | PASS. arm64 Mach-O, adhoc signed | `file`: `Mach-O 64-bit arm64 executable`; `LC_BUILD_VERSION` platform iOS, sdk 26.5, minos 15.0; `LC_CODE_SIGNATURE` present. In JIT-less mode LiveContainer re-signs the guest with its own certificate anyway; in JIT mode codesigning is bypassed |
| Subprocess spawning in the UI layer | PASS. None | No `posix_spawn`, `fork`, `exec`, `NSTask` anywhere in `src/`; the UI only talks HTTP to 127.0.0.1:4096 (`OCServerClient.m`, `NSURLSession`) and downloads Debian packages with `NSURLSessionDownloadTask` (`OCEngine.m:129`) |
| Background modes | PASS. None declared | `AppDelegate.applicationDidEnterBackground` is an empty comment: guest dies with the host, files persist, server restarts on return. Same behaviour standalone and in LiveContainer |
| Resources via bundle | PASS, with one LiveContainer patch in its favour | `OCEngine.m:84` loads `debian-manifest.json` via `[NSBundle mainBundle]` — LiveContainer explicitly patches `NSBundle.mainBundle` to the guest bundle, so this resolves to the guest's file |
| File paths | PASS in shape | `OCEngine.m:26` `engineDirectory` uses `NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, …)` — i.e. the (per-guest) home, not a hardcoded path. Whether LiveContainer maps `NSDocumentDirectory` per guest container was **not verified from source** in this check; the README's "multiple data containers" and the LCShell precedent (§4) both imply per-guest homes, but I did not read the container-patching code |
| Keychain | PASS functionally, WEAKER isolation | `OCKeychain.m` uses `kSecClassGenericPassword` with service + account, no access group. LiveContainer allocates one of 128 keychain access groups per container, so the password should persist per container, but it lives under LiveContainer's signing identity and is readable by the host and, per the README limitations, by other guests. The server password is therefore less isolated in LiveContainer than standalone. Do not treat it as a private vault |
| Network / localhost | PASS, actually easier | UI → server is `NSURLSession` to 127.0.0.1:4096. In LiveContainer guest and (future) core are the same process, so loopback is shared by construction — no cross-app localhost forwarding is needed at all |
| One guest at a time | PASS for this app | Older LiveContainer runs one guest at a time; multitasking is a host feature. Our app needs no second guest running alongside it |

## 3. The LinuxRunner core as a LiveContainer guest

The core is the LinuxRunner 1.1.2 interpreter, cloned at
`~/workspace/opencode-ios-port/linuxrunner/`, commit `f96a2a6f`.

- Guest processes are **not** iOS processes. `kernel/task.c:474`
  `task_start` creates a guest task with `pthread_create` — a host
  thread. Guest `fork`/`clone`/`execve` are emulated syscalls
  (`kernel/fork.c`, `kernel/exec.c`), implemented inside those threads.
  Nothing in the core calls iOS `posix_spawn`/`fork`/`execve` on the
  host. That is exactly the shape LiveContainer's one-process model
  wants: everything happens inside the single dlopen'd process.
- No host executable memory is needed in interpreter mode.
  `kernel/exec.c:205`: "guest permissions only; interpreted code never
  needs host PROT_EXEC." `kernel/ipc.c:1256`: "Guest execute permission
  is interpreter metadata; never PROT_EXEC on host." Guest memory is
  `mmap`'d `PROT_READ|PROT_WRITE`. The only `mprotect(PROT_READ|
  PROT_EXEC)` in the tree is a capability *probe* in
  `app/LinuxRunner/RuntimeBridge.m:619` (`probeJITPermissions`) — it
  tests whether executable memory is permitted and reports
  `backend_available = NO` in the interpreter-only build; it is not
  required for the interpreter to run. `app/hook.c:167` `vm_protect(…
  VM_PROT_READ | VM_PROT_EXECUTE)` is a no-op trick inside
  `find_symbol` to make `proc_regionfilename` return a path for the
  dyld shared cache; it is a symbol-lookup helper, not a JIT backend,
  and it is not part of the minimal boot glue the BUILD-NOTE proposes.
- JIT is optional in LinuxRunner (README: "JIT is not required to use
  LinuxRunner", interpreter is the default; JIT via StikDebug is
  experimental). Our build pins interpreter mode, so no JIT, no
  StikDebug, no `get-task-allow` is needed for the guest to run.
- Storage without an App Group: `app/AppGroup.m` `ContainerURL()` —
  under `LINUXRUNNER` it reads the `LinuxRunnerAppGroup` Info.plist key
  and, if there is no group, falls back to a private
  `Application Support/LinuxRunner` directory. So the core does **not**
  need the App Group entitlement that LiveContainer refuses to apply
  from guests. (The full LinuxRunner app also ships a File Provider
  extension, `app/FileProvider/` — that is part of LinuxRunner, not of
  our app, and must be left out of any guest build; app extensions are
  unsupported in LiveContainer.)
- **Does LiveContainer solve the core-link problem? No.** LiveContainer
  is a launcher, not a builder. It cannot supply meson/ninja, cannot
  build the Swift bridge (`RuntimeBridge.m:19` imports
  `LinuxRunner-Swift.h`; Swift here is Linux x86_64 only), cannot
  conjure a `libish` framework (the boot stack is the whole
  LinuxRunner app), and cannot test the guest on this x86 VM. Those
  four blockers from BUILD-NOTE.md are unchanged by LiveContainer.
  The core must still be built on macOS/Xcode 26 (GitHub Actions),
  with a minimal ObjC boot glue calling `mount_root` / `task_start`
  directly, bypassing RuntimeBridge.
- **What LiveContainer adds:** the guest is dlopen'd with
  `TweakLoader.dylib` injected into every guest. With no tweaks
  installed that loader is inert, but it is an extra in-process dylib
  the standalone install does not have. And in JIT-less mode the whole
  guest bundle — including any future statically linked core — is
  re-signed by LiveContainer with ZSign under its own certificate.
  That is why the core should be **statically linked** into the main
  executable, not shipped as a separate `.framework`/`.dylib`: a
  separate dynamic library would also need to survive LiveContainer's
  patching and re-signing, an extra untested step. This was not tested
  here, because the core is not linked yet.

## 4. Precedent on this exact phone

LCShell was built as a LiveContainer guest in
`~/workspace/livecontainer-shell/` (directory deleted at the user's
direction 2026-10-28; the build is recorded in MEMORY.md): one process
only, dlopen into the host, no real subprocesses, no external binaries,
JIT-less mode, bundle `app.lcshell.ios`. The user's screenshot on
2026-10-23 is the first on-device confirmation that LCShell runs
inside LiveContainer on his iPhone 15 Plus. Our UI layer is the same
shape — Objective-C UIKit, `UIApplicationMain`, no extensions — so the
precedent transfers to the UI. It does **not** transfer to the engine:
LCShell never ran a Linux guest; it was an in-process shell.

## 5. Verdict, and the exact guest version

**Can our app run inside LiveContainer as is? Yes — as a UI/client,
not as an engine.** Import the current IPA into LiveContainer (plus
button, JIT-less setup already done on his phone), launch it, and the
Sessions/Files/Settings tabs will work; the Engine tab will report
"Engine core pending link", and Start will return that error honestly.
If a server is reachable at 127.0.0.1:4096 — for example LinuxRunner
running separately on the same phone, or a server on his network —
the app will work as a client from inside LiveContainer. That has not
been tested on device; no guest run has been done from this VM at all.

**What the working-engine guest version needs, in order:**

1. Link the core first, on macOS/Xcode 26 (GitHub Actions): meson
   build of the C core, minimal ObjC boot glue calling `mount_root` /
   `task_start`, statically linked into the main executable, Swift UI
   replaced by this app's UIKit UI. This step is identical with or
   without LiveContainer; LiveContainer does not help or hinder it,
   except that the result must be one self-contained executable.
2. No changes to the app for LiveContainer itself: no extensions, no
   entitlements, no App Group, no background modes, no URL schemes.
   Keep `NSAllowsLocalNetworking` and the `NSDocumentDirectory`-based
   engine path as they are.
3. Import the resulting IPA into LiveContainer. Keep "Spoof SDK
   Version" disabled on iOS 27. Use the latest nightly (post-20260918)
   if 3.8.10 misbehaves on his iOS 27 build (see issue #1621).
4. First launch inside LiveContainer: Engine tab, first-launch setup
   (37 MB Debian, SHA-256 verified), then Start. Expect the same
   limits as standalone: guest dies if LiveContainer is suspended or
   killed, files persist, server restarts on return; cold start is
   slower under the interpreter; the server password in Keychain is
   shared with the LiveContainer host by design.

**What that version cannot do, even then:** no push notifications,
no app extensions, no separate sandbox per guest (other guests can
read its files), no JIT (interpreter only), no running alongside a
second LiveContainer guest without the host multitasking feature.

## Sources and commands run

- LiveContainer README (mirror, HTTP 200, fetched 2026-11-17):
  `curl https://raw.githubusercontent.com/LiveContainerMirror/LiveContainer/main/README.md`
  — guest model, patching, dlopen, limitations, keychain
  semi-separation, multitasking. Official raw URL also returned 200.
- LiveContainer iOS 27 / nightly status: builds.io "LiveContainer
  2026" (last official Nightly 20260918, v3.8.10; GitHub shadowban
  2026-10-04; LiveContainerMirror); GitHub issue #1621
  (iPhone 18 Pro Max, iOS 27.0, all guests crashing on 3.8.10, fixed
  by nightly 4dbe0f9); fork README iOS 27 notice (Spoof SDK Version
  broken on iOS 27).
- Our app: `unzip -l` + `llvm-otool-18 -L` + `llvm-otool-18 -l` on
  the IPA; `src/Info.plist`, `src/main.m`, `src/AppDelegate.m`,
  `src/OCKeychain.m`, `src/OCEngine.m`, `src/OCServerClient.m`,
  `build.sh`; `grep` for spawn/fork/exec/NSTask/background/URL
  schemes (none found in `src/`).
- Core: `~/workspace/opencode-ios-port/linuxrunner/` —
  `kernel/task.c:474` (`pthread_create`), `kernel/exec.c:205`,
  `kernel/ipc.c:1256`, `app/LinuxRunner/RuntimeBridge.m:619`,
  `app/hook.c:167`, `app/AppGroup.m` (`ContainerURL` fallback),
  `app/LinuxRunner/PrivateContainer.entitlements` (empty dict),
  README JIT section (interpreter default, JIT optional).
- BUILD-NOTE.md (`~/workspace/opencode-inbuilt/BUILD-NOTE.md`) and
  MEMORY.md (LCShell LiveContainer precedent, 2026-10-23 screenshot;
  LiveContainer directory deleted 2026-10-28).

Unverified, stated plainly: whether LiveContainer maps
`NSDocumentDirectory` / `NSApplicationSupportDirectory` per guest
container (implied by "multiple data containers" and the LCShell
precedent, not read in the container-patching code); whether the
3.8.10 / later nightly runs cleanly on this user's iPhone 15 Plus on
his exact iOS 27 build (issue #1621 shows it varies by device); no
guest run of this IPA has been done anywhere yet.
