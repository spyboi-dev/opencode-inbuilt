# Auto-start the engine — OpenCode iOS app (2026-11-20)

When the app launches, the engine now starts itself when it can
start. No tap on Start needed. Same start path as a manual tap
(`OCEngine` start, guest boot, `serve.log` progress); only the
trigger is new.

## Trigger

`src/AppDelegate.m` (`didFinishLaunchingWithOptions`), after the
guest executor is registered:

```objc
[[OCEngine shared] refreshState];
#ifdef OC_CORE_LINKED
[[OCCoreGlue shared] installGuestExecutor];
#endif
[[OCEngine shared] maybeAutoStartEngine];
```

It runs in `OCEngine` rather than in the Engine view controller
because Threads is the launch tab: the Engine screen may never
load, and the engine should still start. The Engine screen shows
the in-flight start when it opens (`OCEngineViewController`
`viewWillAppear` restores the progress bar from
`serveProgress` / `serveStatus` when the state is Starting).

## Guards (`OCEngine.maybeAutoStartEngine`)

Checked in order; any guard that fails just returns, and the
reason is written to the engine log:

1. **Once per launch.** `autoStartAttempted` is set on the first
   call and never cleared, so a foreground return cannot start
   the engine a second time.
2. **Already running / starting.** State Running or Starting
   does nothing.
3. **User stopped it.** `userStoppedEngineThisSession` is set by
   the Stop button in the Engine screen and the Stop row in
   Integrations, and cleared by any start. Auto-start never
   restarts an engine the user stopped on purpose, including on
   a foreground return. (The health timer's own restart is
   unaffected: Stop invalidates the health timer, and a start
   clears the flag.)
4. **Core not linked.** `guestCoreLinked == NO` does nothing:
   the honest "cannot start in this build" state stays exactly
   as it was. This is the unlinked local build: auto-start
   compiles there, logs "Auto-start skipped: engine not ready
   yet in this build", and never touches the start path.
5. **Setup not done.** State NotInstalled or Installing does
   nothing. The user still taps through first-launch setup
   first; the engine auto-starts from the next launch after
   setup finishes. Setup completion deliberately does not
   trigger a start.

A failed auto-start is logged ("Auto-start failed: …") and the
state change (Error / CorePending) reaches every screen through
the state observers. No alert is shown for it.

## Stop while starting

Stop is now available while the engine is Starting, not just once
it is Running (`OCEngineViewController.refresh`). A stop during a
start used to lose: the guest executor's late completion marked
the engine Running again and restarted the health timer. A serve
generation counter in `OCEngine` fixes that: `stopEngine` bumps
the generation, and a completion from an older generation is
ignored (logged, no state change, no completion call).

## How to test on device (Mac / core-linked build)

1. Fresh launch with setup already done and the engine stopped:
   the Engine screen should show "Starting engine" and the
   progress bar moving through boot / Node / OpenCode / server
   start, with no tap. Threads should show "Engine: Starting
   engine", then "Engine running".
2. Tap Stop, background the app, foreground it again: the engine
   must stay stopped.
3. Tap Start by hand after a Stop: it starts (a manual start
   clears the stop flag).
4. Kill the app while the engine runs and relaunch: the engine
   starts again on its own (once per launch).
5. Unlinked build: launch shows "Installed, guest stopped" and
   the dimmed Start button, exactly as before; the log has the
   "Auto-start skipped: engine not ready yet" line and nothing
   else changed.
