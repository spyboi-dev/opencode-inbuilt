# UI fix pass — OpenCode iOS app (2026-11-19)

Fix pass on the current source in `~/workspace/opencode-inbuilt/src/`, not a
redesign. Same look, same dark tokens (OpenCode base #242424, layer-01
#2e2e2e, layer-02 #3a3a3a, text #f2f2f2, muted #aeaeae, faint #808080,
accent #a2bcff dark / #3b5cf6 light). No engine behaviour changed, no
server URL / tabs / bundle id changed. OCEngine setup and start logic
untouched except user-facing strings.

Evidence: the user's three screenshots from 2026-11-17 08:05 IST
(`~/workspace/user/files/6AA02413…`, `28AFDDE0…`, `3E47B472…`):
Files tab reading "/" with a black screen and a "Files unavailable" modal;
Engine tab with long developer copy, "BUILD-NOTE.md" references, and a
Start button that looked tappable but popped an "Engine did not start"
alert.

## 1. Files — `src/OCFilesViewController.m` (rewritten, was 89 lines)

Before:
- `reload` set `self.title = self.path`, so the tab and nav title read
  "/" (screenshot 1). The list showed nothing and a modal alert
  "Files unavailable / Could not connect to the server." blocked the
  screen every time the tab opened.
- Opening a file that failed to read pushed a code view whose
  "content" was just the error text.

After:
- Line 30: title is always @"Files". Lines 38–44: the current folder
  shows as a small muted line at the top of the list
  (`tableHeaderView` with `pathLabel`, updated in `reload`).
- Lines 49–88, 101–110: an inline empty state in the view itself
  (title + detail + Retry button). Server down:
  "No files to show / Could not reach the engine server at
  127.0.0.1:4096. Start the engine, then try again." Empty folder:
  "This folder is empty / There are no files here yet." (no Retry
  there). No alert is presented anywhere in this file any more.
- Lines 145–155: a file that cannot be read shows the inline state
  ("Could not open <name>" + reason + Retry) instead of pushing a
  view with the error as its content.

## 2. Engine — `src/OCEngineViewController.m`

Before:
- Detail label (was line 209): "Guest core is not linked in this
  build. The engine host, the Debian package cache and the server
  client are ready; the core link is the remaining step (see
  BUILD-NOTE.md). The app will start the guest as soon as the core
  is linked."
- Setup done popped a modal "Engine core pending link" alert quoting
  BUILD-NOTE.md (screenshot 3).
- Start looked fully tappable and popped a modal "Engine did not
  start" alert (screenshot 2).

After:
- Line 209: "Engine not ready yet. Setup already saved the Debian
  packages. The engine cannot start in this build." No file
  references anywhere in the user-facing copy.
- Lines 216–218 (`refresh`): while the engine cannot start,
  `startButton.enabled = NO` and `alpha = 0.4`, so it looks clearly
  unavailable. The reason is already on screen, inline.
- Line 234 (setup label): "Setup only saves the Debian packages
  (37 MB). The engine cannot start yet."
- Setup completion: the alert is deleted; the progress label says
  "Setup done. Debian packages saved. The engine cannot start yet."
- `startTapped` (lines 270–273): a tap while not ready sets the
  progress label inline ("Engine cannot start yet. Setup is done,
  but the engine is not ready in this build.") and returns. A real
  start failure (core linked) sets the progress label inline
  (line 287: "Engine did not start: <reason>") and hides the bar.
  No alert in either path.

## 3. Settings — `src/OCSettingsViewController.m`

Before:
- Limits row: "Guest dies if the app is killed; files persist, the
  server restarts. See BUILD-NOTE.md."
- Tapping Model with the server down did nothing at all: the fetch
  failed silently and no picker appeared.

After:
- Line 114: "If the app is closed, the engine stops. Your files stay
  saved, and the engine restarts next time."
- Lines 11, 94, 133, 137: new `modelNote` property. A failed or
  empty model list sets the Model row's detail inline to "Could not
  reach the server. Start the engine first." and reloads the table;
  it clears when models load. No alert.

## 4. Engine strings — `src/OCEngine.m`

Before:
- `stateDescription` for CorePending: "Engine core pending link".
- Start error (was line 514): "Guest engine core is not linked in
  this build. Link the LinuxRunner core (see BUILD-NOTE.md) and
  rebuild."

After:
- Line 74: state is "Not ready yet". This is the text the Engine
  state label, the Threads status line and the Integrations engine
  row all show.
- Line 514: "The engine is not ready yet in this build, so it
  cannot start."
- Logic untouched. The only remaining "BUILD-NOTE.md" mentions in
  the source are code comments (`OCEngine.m:511`, `OCEngine.h`,
  `OCServerClient.h`); none of them reach the screen, and a strings
  check on the built binary finds zero occurrences.

## 5. Threads — `src/OCSessionsViewController.m`

Before:
- List fetch failure wrote the raw system error into the status
  line ("Engine: … · Could not connect to the server.").
- Tapping + with the engine down popped a modal "Error / Could not
  create a session. Is the engine running?"

After:
- Line 100: fetch failure now reads "Engine: <state> · Could not
  load chats. Start the engine, then pull to retry."
- Line 114: a failed new chat writes "Could not start a chat.
  Start the engine first." into the status line instead of an
  alert. The `showError:` modal method is deleted.
- Unchanged, already good: empty list shows "No sessions yet. Tap +
  to start one." in the status line; pull to refresh retries.

## 6. Integrations — `src/OCIntegrationsViewController.m`

Before:
- The "Start engine" row was blue and tappable while the engine
  could not start; tapping it silently did nothing (the start error
  was swallowed in the completion block).

After:
- Lines 82–89: while the core is not linked the row reads "Start
  engine" in grey with the detail "Not ready yet".
- Lines 119–123: tapping it does nothing (the row already states
  the reason). No alert. The engine row above it shows the state
  ("Not ready yet"). Providers empty state unchanged, already
  inline: "No providers reported / Start the engine to list
  providers".

## 7. Chat — `src/OCChatViewController.m`

Before:
- `showError:` popped a modal "Error" alert for a failed send,
  model pick, diff, revert or permission reply — all normal states
  when the engine is down.
- A new session with no messages showed a bare black thread with no
  explanation, and a failed message fetch failed silently.

After:
- Lines 123–129, 463–483, 984–1002: `showError:` now shows a short
  inline banner at the top of the thread (layer-01 rounded label,
  same tokens) that hides itself after 4 seconds; a token guards
  against a stale hide dismissing a newer message. All call sites
  unchanged. The permission Allow/Deny alert and the Revert
  confirmation are real decisions, so they stay as alerts, as do
  the plus-menu and model-picker action sheets.
- Lines 129, 825–870: `loadError` flag plus `updateEmptyState`.
  Empty thread with no error: "No messages yet. / Type below to
  start." Empty thread after a failed fetch: "Could not load this
  chat. / Start the engine and try again." Shown as the table's
  background view, so it never fights the message list.
- Composer and keyboard unchanged (already correct): the composer
  grows to 180px then scrolls, the keyboard lifts it via
  `composerBottomConstraint`, placeholder "Follow up...", send
  becomes Stop while a reply is in flight.
- Also fixed 4 pre-existing warnings in this file so the build is
  zero-warning: unused `action` params in `plusTapped` (lines
  560, 563) now `(void)action;`, and sign-compare in
  `foldButtonTapped` / `copyButtonTapped` (lines 1258, 1325) now
  compare against `(NSInteger)self.displayItems.count`.

## 8. Browser — `src/OCBrowserViewController.m`

Before: no title (blank nav bar) and a page that failed to load left
a blank screen with no explanation.

After: line 15 sets the title to "Browser". Lines 89–111 add
`didFailProvisionalNavigation` / `didFailNavigation` handlers that
load a small inline error page ("Could not open this page." +
reason + "Check the address and try again.").

## 9. Code view — `src/OCCodeViewController.m`

Before: an empty file showed a blank screen.

After: lines 24–39 show a centered "This file is empty." label
when the content is empty; the line-numbered view is unchanged
otherwise.

## Known limitation found, not changed

`OCEngine.shared.stateDidChange` is a single callback property, and
both `OCIntegrationsViewController` and `OCEngineViewController`
assign it in `viewDidLoad`, so the last one loaded wins and the
Integrations engine row can go stale while the Engine screen is
open. Not fixed here: fixing it properly means a multicast observer
in `OCEngine`, which is engine behaviour, out of scope for this fix
pass. In practice the visible paths are covered: Integrations
reloads its table in `viewWillAppear` and after every Start/Stop
tap, and the Engine screen refreshes on every state change.

## Build and verification

- Rebuilt with `build.sh` (clang-18 / ld64.lld-18,
  iPhoneOS26.5.sdk, `-Wall -Wextra`): **zero warnings**.
- IPA: `~/workspace/opencode-inbuilt/build/OpenCode-Inbuilt.ipa`
  — **314,110 bytes**, SHA-256
  `5253dc1bd4b3b7520a6ffcaeee29ba691a9ae79c6e6a26f633869be3faca7ad3`
  (previous build was 257,347 bytes, SHA-256
  `ca2fcdbd1f17344ed580b2a5fb1514cb2765d5673aca761a7471f5af4507e761`).
- Verified on host: Mach-O 64-bit arm64, `LC_BUILD_VERSION`
  platform iOS, SDK 26.5, minos 15.0, `LC_CODE_SIGNATURE` present
  (adhoc). Endpoints present in the binary: `/api/event`,
  `/api/fs/list`, `/api/fs/read/`, `/api/info`, `/api/model`,
  `/api/provider`, `/api/session`, `/api/shell/`. 0 `.html` files
  in Payload. 0 occurrences of "BUILD-NOTE" in the binary strings.
- Grep check: the only remaining `UIAlertController` uses are the
  intentional ones (plus menu, model picker, agent-mode picker,
  Revert confirmation, permission Allow/Deny). No error modals
  remain.

## Still untested — say plainly

- **On a real iPhone and in LiveContainer.** This x86_64 Linux VM
  cannot run the iOS binary, so the fixes are verified at source
  and binary level only. The user still needs to open the app in
  LiveContainer and check: Files tab reads "Files" with the "/"
  path line and the inline "No files to show" state instead of the
  alert; Engine Start looks dimmed and does not pop an alert;
  Threads shows the inline status on + with the engine down; a new
  chat shows "No messages yet."
- **The engine still cannot start in this build.** The guest core
  is still not linked; that needs the Mac build, which is a
  separate step. All the "not ready yet" copy is honest about that
  instead of pretending otherwise.
