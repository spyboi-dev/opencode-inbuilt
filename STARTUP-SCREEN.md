# Startup screen — OpenCode iOS app (2026-11-20)

When the app launches, a boot screen shows the real-time progress
of the engine and the server, in the layout of the Andarium boot
screen the user sent: a top row with a status dot plus "Starting"
on the left and a live elapsed timer on the right, a big bold app
title, and one rounded card holding checklist rows. A Log button
opens the log; a Continue button always gets the user into the app.

## What drives each row

`src/OCStartupViewController.m` polls `OCEngine` every 0.5s
(state, `serveProgress`, `serveStatus`) and also observes state
changes. `serveProgress` is the guest's own PROGRESS percentage
from serve.log, monotonic: boot writes 5, Node ready is 55,
OpenCode ready is 85, server starting is 90, and "server
listening" completes it at 1.0 and flips the state to Running. A
row flips to a green check only when its threshold is really
passed; the current stage shows a spinner with its detail line in
the accent colour; later stages stay dim. Nothing is faked.

| Row | Done when | Active when | Detail when done |
| --- | --- | --- | --- |
| Engine core | core linked (`guestCoreLinked`) | — | Linked, ready to boot |
| Guest boot | progress > 0.05, or Running | Starting, progress ≤ 0.05 | Debian 13 guest |
| Node | progress ≥ 0.55, or Running | Starting, 0.05 < progress < 0.55 | Node 22 LTS |
| OpenCode | progress ≥ 0.85, or Running | Starting, 0.55 ≤ progress < 0.85 | OpenCode 2.3.0 |
| Server | state Running | Starting, progress ≥ 0.85 | Listening on 127.0.0.1:4096 |

The active detail line is the guest's own current PROGRESS
message when it names the stage (e.g. "Downloading Node 22
(25 MB)...", "Installing tools (git, python3, pip3, gh, jq,
ripgrep)..."), otherwise a plain fallback ("Checking Node...",
"Installing OpenCode...", "Starting server..."). If Node or
OpenCode is already installed, the bootstrap skips its download
and the progress jumps past the threshold, so the row is done —
that is honest: the tool is present.

If the core is not linked, the Engine core row shows a red
outline and "Not ready in this build" instead of a check, and the
other rows stay dim.

## Log button

"View log" opens the SAME log screen already inside the app: the
Engine tab's live log view (`OCEngineViewController`, with its
Copy log button and its 1-second refresh), presented in a
navigation controller with a Done button. No second log view
exists. The log is live there too: the Engine screen's refresh
timer runs while it is open, and its `serveProgressDidChange`
callback takes over the progress bar while it is visible (the
startup screen polls, so it never fights for that callback).

## Dismiss and failure flow

- **Server listening:** when the state becomes Running, the
  screen waits 0.7s so the user sees every check green, then
  dismisses into the normal tabs (Threads/chat).
- **Log open when the server comes up:** the screen waits until
  the log closes instead of yanking it away, then dismisses.
- **Engine fails (state Error):** the header reads "Engine
  error" in red and the reason line says "The engine did not
  start. Check the log for the exact reason." The Continue button
  stays.
- **Core not linked:** header "Not ready", reason "The engine is
  not ready yet in this build. Setup already saved the Debian
  packages, but the engine cannot start here."
- **Setup not done:** header "Setup needed", reason "First-launch
  setup has not finished yet. Continue to the app to run setup
  from the Engine tab."
- **Engine stopped:** header "Stopped", reason "The engine
  stopped. You can start it again from the Engine tab."
- **Continue to app:** always on screen, dismisses immediately.
  The engine keeps starting in the background; the Engine tab
  shows its progress. The user is never trapped on the boot
  screen.

The screen starts nothing itself: `AppDelegate` still calls
`maybeAutoStartEngine` first, with all its guards (once per
launch, never after an explicit Stop in the same session, nothing
without the core, nothing before setup is done). The screen only
observes and presents. It is shown on every launch, presented
fullscreen over the tabs from `AppDelegate`.

## Tokens

OpenCode dark tokens, same as the chat: base #242424, layer-01
#2e2e2e (the card), layer-02 #3a3a3a (the buttons), text #f2f2f2,
muted #aeaeae, faint #808080, accent #a2bcff dark / #3b5cf6
light. Done checks are system green, like the Andarium model.
The FreeMilk toolbar/composer is untouched. Plain user-facing
copy, no BUILD-NOTE mentions, no modal alerts for states.

## How to test on device (Mac / core-linked build)

1. Fresh launch with setup done and the engine stopped: the boot
   screen appears with "Starting" and a running timer, the rows
   flip to green checks one by one as the guest boots, Node and
   OpenCode install, and the server starts, then the screen
   dismisses into Threads on its own.
2. Tap "View log" mid-boot: the Engine screen opens with the live
   log and Copy log; Done closes it back to the boot screen.
3. Tap "Continue to app" mid-boot: the tabs open, the engine
   keeps starting, and the Engine tab shows the progress.
4. Launch in the unlinked build: the screen shows "Not ready" and
   the red-outlined Engine core row, with Continue to the app.
5. Stop the engine, kill the app, relaunch: the boot screen
   starts the engine again on its own (auto-start, once per
   launch).
6. app.py: with /root/Projects/app.py present, `curl -s
   http://127.0.0.1:8000 | grep -o 'Hello from Python'` in a
   guest shell prints the line after the engine starts, and
   /root/Projects/server.log is non-empty. See AUTO-START.md.
