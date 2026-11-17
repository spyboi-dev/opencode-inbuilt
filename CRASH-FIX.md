# Crash fix — "Run first-launch setup" crashes in LiveContainer

Date: 2026-11-17. Reported by the user 07:45 IST: running the
OpenCode-Inbuilt IPA inside LiveContainer on iOS 27, iPhone 15 Plus.
The app launches, the Engine tab opens, but it crashes when he taps
"Run first-launch setup". Fixed in this build; new IPA below.

## The crash — exact cause

`src/OCEngine.m`, `runFirstLaunchSetupWithProgress`, old code (lines
~100–102 in the shipped build):

```objc
__block void (^downloadNext)(void);
__weak void (^weakDownloadNext)(void);
downloadNext = ^{ … weakDownloadNext(); … };
weakDownloadNext = downloadNext;
downloadNext();
```

`downloadNext` is a **local `__block` variable** and `weakDownloadNext`
is a **weak reference to the same block**. Nothing else retains the
block: the `NSURLSessionDownloadTask` completion handler captures only
`weakDownloadNext` (weak) and `weakSelf` (weak), so it does not keep
the block alive. As soon as `runFirstLaunchSetupWithProgress` returns,
the local `__block` variable goes out of scope, the block is
deallocated, and `weakDownloadNext` becomes `nil`.

On first launch no Debian packages are cached, so the first package
always takes the async download path: the task is created, the method
returns, the block dies, and seconds later, when the download
completes, the completion handler runs `weakDownloadNext();` — **calling
a nil block**. Unlike messaging a nil object, invoking a nil block is
a crash (`EXC_BAD_ACCESS`). That is exactly what the user hit: tap
setup, first .deb downloads, crash on its completion.

The earlier bug pass (BUILD-NOTE.md §Bug pass, item 2) created this:
the original code had a retain cycle because the block captured
itself, and the "fix" was a weak reference to the block. That removed
the cycle but also removed the only strong reference, so the block
died the moment setup returned. The cached-file path never crashed,
because it calls `weakDownloadNext()` synchronously while the method
is still on the stack — which is why the bug survived host review:
no download ever completed on this VM, so the async path never ran.

Contributing defects in the same path, all fixed here:

1. **No double-tap guard.** `setupTapped` never hid or disabled the
   button during install, so a second tap started a second download
   chain over the same files, with the completion block able to fire
   twice.
2. **UI updates off the main thread.** The manifest-missing and
   directory-error paths in `OCEngine` called `completion` directly,
   not on the main queue, so the view controller's UI updates in
   `setupTapped`'s completion block could run off-main. The two
   early `startEngine` error paths had the same problem.
3. **Nil error passed to completion.** The download handler called
   `completion(NO, error)` when `error` was nil but `location` was
   also nil, so the view controller formatted a nil
   `localizedDescription`.
4. **Unguarded manifest values.** A package entry with no `Filename`
   or no `SHA256` would have passed nil into
   `stringByAppendingPathComponent:` / `stringByAppendingString:`,
   which raise, and `actualSHA` could be nil in the SHA comparison.
5. **Manifest lookup only tried `NSBundle.mainBundle`.** LiveContainer
   patches `mainBundle` to the guest bundle (see
   LIVECONTAINER-EVAL.md §2), so this normally works, but there was
   no fallback if it did not.

## What changed

`src/OCEngine.m` — setup chain rewritten, no recursive block at all:

- The chain state is now held **strongly by the `OCEngine` singleton**
  (which lives for the life of the app): `setupActive`,
  `setupPackages`, `setupCacheDir`, `setupRepository`, `setupIndex`,
  `setupProgress`, `setupCompletion`, `setupSession`. It is driven by
  the `-setupDownloadNext` **instance method**. The download task's
  completion handler captures `weakSelf`, promotes it to a strong
  reference, and calls `[strongSelf setupDownloadNext]`. There is no
  `weakDownloadNext` anywhere in the code any more (grep: 0 hits).
- Cached files are skipped in an iterative `while` loop, not by
  recursion, so 103 cached files cannot grow the stack.
- `-setupFinishWithSuccess:error:` finishes exactly once: it clears
  the retained chain first, always dispatches completion to the main
  queue, and always supplies a non-nil error when `done == NO`
  (code 9, "Setup failed with no error reported", if a caller passes
  nil). It also invalidates the download session.
- `runFirstLaunchSetupWithProgress` now refuses a second chain while
  one is running (error code 7, "Setup is already running", on the
  main queue) and validates every manifest entry before use
  (codes 5/6/8 for a bad entry, bad URL, missing Documents dir).
- Manifest lookup tries `[NSBundle mainBundle]` first, then
  `[NSBundle bundleForClass:[OCEngine class]]`.
- Setup uses a dedicated `NSURLSession` (default configuration)
  instead of `sharedSession`, so the guest does not depend on the
  host process's shared session inside LiveContainer.
- Setup never touches the guest core: `guestExecutor` is nil in this
  build and is never called on the setup path. Setup does only the
  Debian cache download, then stops cleanly.
- `startEngine`'s two early error paths now also dispatch completion
  to the main queue.

`src/OCEngineViewController.m` — `setupTapped` / `startTapped`:

- `setupTapped` returns immediately if the state is already
  `Installing`, disables the setup button for the duration of setup,
  and re-enables it in completion.
- Progress and completion bodies dispatch to the main queue
  defensively, even though `OCEngine` now guarantees the main queue.
- Failure text uses `error.localizedDescription ?: @"Unknown error"`.
- When the core is not linked (this build), the label says so before
  setup starts, and on success it says "Setup done. Debian packages
  cached and verified. Engine core is still pending link, so Start is
  not available yet.", plus an alert explaining that the engine
  cannot start until the core is linked. Setup still caches the
  packages; it just does not pretend the engine is ready.

## New IPA (verified on host)

- Path: `build/OpenCode-Inbuilt.ipa`
- Size: **252 KB** (was 249 KB)
- SHA-256: `ca2fcdbd1f17344ed580b2a5fb1514cb2765d5673aca761a7471f5af4507e761`
- Verified: Mach-O 64-bit arm64, `LC_BUILD_VERSION` platform iOS,
  sdk 26.5, minos 15.0, `LC_CODE_SIGNATURE` present (adhoc — install
  via SideStore / AltStore re-sign, or import into LiveContainer),
  server endpoints (`/api/session`, `/api/event`, `/api/info`, …)
  present in the binary, 0 `.html` files in Payload, bundled
  `debian-manifest.json` still 103 packages.
- Build: clang-18 + ld64.lld-18, iPhoneOS26.5.sdk, `-Wall -Wextra`,
  **zero warnings** (`./build.sh` reproduces it).

## What is still untested

- **On a real iPhone and in LiveContainer.** The iOS binary cannot
  run on this x86_64 Linux VM, so the fix is verified at the source
  and binary level only: the nil-block call site is gone, the chain
  is retained by the singleton, and every completion path is
  main-queue with a non-nil error. The user still needs to tap
  "Run first-launch setup" inside LiveContainer and confirm it no
  longer crashes and the progress bar advances through the 103
  packages.
- **The engine core is still not linked** (`guestCoreLinked` is NO).
  This fix makes setup not crash and cache the Debian packages; it
  does not make the engine run. After setup succeeds, Start will
  still return "Guest engine core is not linked in this build."
  That step still needs the GitHub Actions macOS + Xcode 26 core
  build (see BUILD-NOTE.md).

## How to test on device

1. Import the new IPA into LiveContainer (JIT-less setup already done
   on the phone) and launch it.
2. Engine tab → **Run first-launch setup**. It should not crash.
   The progress bar should advance package by package (103 total,
   37 MB, Wi-Fi, a few minutes).
3. On success it should say the Debian packages are cached and that
   the engine core is still pending link, with an alert saying the
   same. Tapping setup again after success should do nothing visible
   harmful (button is hidden once installed; on failure it stays
   visible and can be retried).
4. If it still crashes, the LiveContainer crash log (Settings →
   crash logs, or the guest's log) with the faulting address and
   the thread's backtrace is what I need next — the crash in this
   file was deterministic on the first download completion, so a
   crash now would be a different bug.
