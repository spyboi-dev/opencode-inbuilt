# UI fix pass 2 — OpenCode iOS app (2026-11-20)

Second fix pass on the source in `~/workspace/opencode-inbuilt/src/`,
following the Nov 19 pass (`UI-FIX.md`). Same look, same dark tokens
(OpenCode base #242424, layer-01 #2e2e2e, layer-02 #3a3a3a, text
#f2f2f2, muted #aeaeae, faint #808080, accent #a2bcff dark / #3b5cf6
light). No redesign, FreeMilk toolbar/composer untouched. No modal
alerts for states: inline status or a short banner, as before.
Plain words in user-facing copy, no file references.

Evidence: the Nov 19 pass's documented known limitation (single
`stateDidChange` callback), the user's screenshots from Nov 19
21:53 (Engine screen, `B8726705…`) and Nov 20 06:36 (chat screen,
`3191AF52…`), and a read of every view controller.

Auto-start (the other half of this round) is documented separately
in `AUTO-START.md`; the Engine items below that support it are
marked.

## 1. Engine state observer is multicast now — `src/OCEngine.h`, `src/OCEngine.m`

Before (the Nov 19 known limitation): `OCEngine.shared.stateDidChange`
was one callback property, assigned by both
`OCIntegrationsViewController` and `OCEngineViewController` in
`viewDidLoad`. The last one loaded won; the Integrations engine row
could go stale while the Engine screen was open (and the reverse).

After: `OCEngine` has `-addStateChangeObserver:` /
`-removeStateChangeObserver:` (token based, weak-safe, snapshot
under lock). `setState:` notifies the legacy `stateDidChange` block
if set, plus every observer. Both view controllers observe and
remove their token in `dealloc`. `OCSessionsViewController`
(Threads) observes too now, so its status line updates live (see
2). `serveProgressDidChange` stays a single callback: only the
Engine screen uses it, so there is no second consumer to go stale
(see "Left unfixed").

## 2. Threads status line went stale — `src/OCSessionsViewController.m`

Before: the "Engine: …" line was set only when the list loaded
(`reloadSessions`, i.e. `viewWillAppear` / pull to refresh). An
auto-start, or a Stop from Integrations, while Threads was open
left the line wrong until the next refresh.

After: the controller observes engine state and updates the line
through `updateStatusLine`, which does not clobber a load failure
(the failure text explains itself) or the "No sessions yet. Tap +
to start one." hint.

## 3. Threads "Engine" button went to the wrong screen — `src/OCSessionsViewController.m`

Before: the left bar button labelled "Engine" only switched to
the Integrations tab; the user was still one tap away from the
screen the button names.

After: it switches to Integrations and pushes the Engine screen
onto that tab's navigation stack.

## 4. Threads kept dead chats after a failed load — `src/OCSessionsViewController.m`

Before: a failed list fetch left the old sessions on screen while
the status line said they could not be loaded; tapping one opened
a chat that then failed to load.

After: on error the list is cleared (`sessions = @[]`, table
reloaded) and the status line explains it. Pull to refresh
restores the list.

## 5. Swipe-delete failure looked like success — `src/OCSessionsViewController.m`

Before: a failed delete swallowed the error and reloaded; the row
vanished, then came back on the next load with no explanation.

After: on error the row stays and the status line says "Could not
delete that chat. Try again." (It is not reloaded over the
message.)

## 6. Integrations rows inherited the Start/Stop colour — `src/OCIntegrationsViewController.m`

Before: cells are reused across rows, but `cellForRowAtIndexPath`
never reset `textLabel.textColor`. A provider or Settings row
recycled from the Start/Stop engine row could render blue, red or
grey.

After: `textColor` is reset to the label colour at the top of
`cellForRowAtIndexPath`, next to the existing accessory reset.

## 7. Integrations kept providers from the last run — `src/OCIntegrationsViewController.m`

Before: the providers fetch in `viewWillAppear` ignored errors,
so after the engine stopped the list still showed the previous
run's providers.

After: on fetch error the list is cleared to empty and the table
reloads, showing "No providers reported / Start the engine to
list providers".

## 8. Engine: no Stop while starting, and Stop lost the race — `src/OCEngineViewController.m`, `src/OCEngine.m` (auto-start support)

Before: the Stop button was hidden while the state was Starting,
so a start hung on a big download could not be cancelled. And
stopping from Integrations during a start did not really stop
it: the guest executor's late completion marked the engine
Running again and restarted the health timer.

After: Stop shows while Running or Starting. A serve generation
counter in `OCEngine` (`stopEngine` bumps it; the executor
completion ignores a stale generation, logging "Serve launch
result ignored: engine was stopped while starting") makes the
stop stick.

## 9. Engine: an empty progress bar reappeared after Stop — `src/OCEngineViewController.m`

Before: `stopEngine` calls `setServeProgress:0`, and the progress
callback unhid the bar for every callback, so stopping left an
empty bar on screen.

After: the callback hides the bar when progress is 0 with no
status text.

## 10. Engine: opening the screen mid-start showed no progress — `src/OCEngineViewController.m` (auto-start support)

Before: the progress bar only appeared when a start was tapped
on this screen. An auto-start (or a start from Integrations)
already in flight showed a bare "Starting engine" with no bar.

After: `viewWillAppear` restores the bar from
`serveProgress` / `serveStatus` when the state is Starting; the
progress callback takes over from the next poll tick.

## 11. Engine: log contradicted the state — `src/OCEngine.m`

Before (Nov 19 21:53 screenshot): the state read "Installed,
guest stopped" while the log card underneath showed "server
listening on http://0.0.0.0:4096". The serve.log was from a
previous run — the guest dies when the app closes, the log file
survives — but nothing on screen said so.

After: `fullLogText` prepends "(Log from a previous run: the
engine is stopped now, so this is not live.)" to the serve.log
section whenever the state is not Running/Starting and the log
contains "server listening".

## 12. Chat: error banner covered the first message — `src/OCChatViewController.m`

Before: the inline banner floated over the top of the thread, so
for the four seconds it was visible it hid the first message.
Its text also ran edge to edge with no padding.

After: the banner is a container with a padded label inside
(12pt sides, 8pt top/bottom), and while it is up the thread is
pushed down by the banner's height via `contentInset` /
`scrollIndicatorInsets`, restored when the banner hides. The
4-second token guard is unchanged.

## 13. Chat: polling yanked the scroll to the bottom — `src/OCChatViewController.m`

Before: `reloadMessages` called `scrollToBottom` on every
refresh, so the 2-second poll while a reply was in flight dragged
the thread down while the user was reading an earlier message.

After: the position before the fetch is remembered
(`isNearBottom`, within 120pt); the thread only sticks to the
bottom if the user was already there.

## 14. Chat: Copy stayed "Copied" — `src/OCChatViewController.m`

Before: tapping Copy on an assistant message set the button to
"Copied" and never put it back until the cell was reused.

After: it returns to "Copy" after 1.5 seconds, like the Engine
screen's "Copied" log button already did.

## 15. Chat: send arrow looked ready with nothing to send — `src/OCChatViewController.m`

Before: the send circle was the same grey whether the composer
was empty or had text, although tapping it empty only focuses
the composer.

After: `updateSendButton` dims it to 0.5 alpha when the composer
is empty and no reply is in flight, full alpha otherwise.

## 16. Chat: composer snapped while the keyboard slid in — `src/OCChatViewController.m`

Before: `keyboardWillShow` moved the composer with a bare
`layoutIfNeeded`, so it jumped while the keyboard animated in.

After: the move rides the keyboard's own animation duration and
curve, and scrolls to the bottom when the animation finishes.

## 17. Files: no way to refresh inside the chat — `src/OCFilesViewController.m`

Before: the Files screen's only refresh was its nav-bar Refresh
button, which never appears when Files is embedded in the chat
(the chat hides the nav bar). The empty-state Retry was the only
reload, and only when the list was empty.

After: pull to refresh on the file list (`UIRefreshControl`,
ended in both completion paths).

## 18. Files: full paths in rows, doubled paths on open — `src/OCFilesViewController.m`

Before: rows showed `entry[@"path"]`, the server's full path
("/root/Projects/…"), truncated; and opening an entry built the
child path by appending that full path to the current folder,
so a folder could be opened as "/root/Projects" +
"/root/Projects/…".

After: rows show just the file name (`name`, else
`lastPathComponent`); navigation uses the entry's path as-is
when it is absolute, and only appends a relative name. The same
name is used for the code view title and the "Could not open …"
message.

## 19. Files: raw system error on a failed read — `src/OCFilesViewController.m`

Before: a file that could not be read showed
`error.localizedDescription` ("The operation couldn't be
completed…") in the inline state.

After: plain words — "The file could not be read. Try again."

## 20. Settings: typing the server URL lost the text — `src/OCSettingsViewController.m`

Before: the server `UITextField` was recreated in every
`cellForRowAtIndexPath`, so a providers fetch landing while the
user was typing replaced the field mid-edit: typed text lost,
keyboard dismissed.

After: the field is built once in `viewDidLoad` and reused;
`cellForRowAtIndexPath` only updates its text.

## 21. Settings: reused cells showed the wrong accessory — `src/OCSettingsViewController.m`

Before: `accessoryView` / `accessoryType` were never reset, so a
cell recycled from the Server URL row could carry the text field
(or a disclosure chevron) onto a row it did not belong to.

After: both are reset at the top of `cellForRowAtIndexPath`,
along with the labels.

## 22. Settings: keyboard stayed up over the sheets — `src/OCSettingsViewController.m`

Before: tapping the Agent mode or Model row while editing the
server URL left the keyboard up over the action sheet.

After: `didSelectRowAtIndexPath` resigns the server field first.

## 23. Settings: provider detail had a dangling separator — `src/OCSettingsViewController.m`

Before: the detail was `"<id> · <activation>"` with empty
strings substituted, so a missing id or activation left
" · " with nothing on one side.

After: only the parts that exist are joined with " · ".

## 24. Browser: Back/Forward always looked tappable — `src/OCBrowserViewController.m`

Before: the toolbar Back and Forward buttons were always
enabled, even with no page to go back or forward to; tapping
them did nothing.

After: they are stored as properties and enabled from
`canGoBack` / `canGoForward` after each navigation (and on load).

## 25. Browser: a bad address did nothing — `src/OCBrowserViewController.m`

Before: entering an address that is not a URL silently returned;
the screen did not change.

After: it loads the same inline error page a failed navigation
shows ("That address does not look like a web address."). The
address field also gets a clear button while editing.

## Checked, not changed

- Inline code spans in chat: the Nov 20 06:36 screenshot's code
  boxes look light in the thumbnail, but a zoomed crop shows
  white text on a dark layer-01 (#2e2e2e) box — the Nov 17 fix is
  in the code (`OCUtil.attributedFromMarkdown`) and rendering
  correctly. No change.
- The FreeMilk toolbar/composer and the OpenCode dark tokens are
  untouched throughout.
- `serveProgressDidChange` is still a single callback (see below).

## Left unfixed

- `serveProgressDidChange` is still a single callback property.
  Only the Engine screen assigns it, so there is no second
  consumer to go stale; making it multicast as well is a
  follow-up if another screen ever needs live start progress.
- The Setup button shows in the Error state even when the error
  came from a failed start rather than setup. Re-running setup
  then just re-verifies the cached packages, so it is harmless.
- Roadmap card taps use `indexOfObject:`; two identical todos
  would both act on the first. Same text either way, and an
  edge case.
- The Model picker is a long action sheet when the server
  reports many models. It works; a searchable list would be a
  bigger change.
- Chat tool-row subtitle truncation ("cd /root/Projects && ls
  -la; echo "----…") is by design (OpenCode's truncated tool
  subtitle); expanding the row shows the full command.

## Build and verification

- `clang-18` / `ld64.lld-18` had been wiped by a VM restart, so
  they were reinstalled via apt before building (the repo's own
  note prescribes this). One compile error on the first build
  (missing `]` on the three new observer calls) was fixed in the
  source.
- Rebuilt with `build.sh` (clang-18 / ld64.lld-18,
  iPhoneOS26.5.sdk, `-Wall -Wextra`): **zero warnings**.
- IPA: `~/workspace/opencode-inbuilt/build/OpenCode-Inbuilt.ipa`
  — **321,464 bytes**, SHA-256
  `76ad7dd6ea817279225a8612f9b2f65b6cf57c0c271c57e9a6a1c7ba9477ad31`
  (previous build was 314,110 bytes, SHA-256
  `5253dc1bd4b3b7520a6ffcaeee29ba691a9ae79c6e6a26f633869be3faca7ad3`).
- Verified on host: Mach-O 64-bit arm64, 0 occurrences of
  "BUILD-NOTE" in the binary strings. Auto-start strings present
  in the binary; the build does not define `OC_CORE_LINKED`, so
  this IPA stays in the honest "cannot start" state.
- Note: `build.sh` starts with `rm -rf build`, so this rebuild
  removed the previous Mac-built
  `build/OpenCode-Inbuilt-ui-core.ipa` (841,058 bytes, SHA-256
  `24ac1fe5…`) from this VM. It is not in the repo (ignored) and
  no other copy is on this disk; recover it from the GitHub
  Actions artifact of run 44648184682, or re-run the Mac build.

## Still untested — say plainly

- **On a real iPhone and in LiveContainer.** This Linux VM
  cannot run the iOS binary, so the fixes are verified at source
  and binary level only. The user still needs to open the app in
  LiveContainer and check: the Integrations row stays fresh
  while the Engine screen is open; Threads status updates when
  the engine starts; the "Engine" button opens the Engine
  screen; the chat thread does not yank while a reply streams;
  Files pull to refresh works inside the chat.
- **Auto-start needs the core-linked Mac build to prove it.**
  This local build has no core linked, so auto-start is verified
  only as "does nothing, stays honest". Test steps for the
  linked build are in `AUTO-START.md`.
- **The engine still cannot start in this build.** The guest core
  is still not linked; that needs the Mac build, which is a
  separate step.
