# Auto-start the engine — OpenCode iOS app (2026-11-20)

> 2026-11-22: fully automatic. The manual Start/Stop buttons (Engine
> tab and Integrations row) and the Engine-tab mode picker are
> removed; the mode is chosen at Install time on the startup screen.
> The `userStoppedEngineThisSession` flag is gone. A failed
> automatic start retries by itself (foreground return + one 60 s
> timer); a failed setup does not — the startup screen's Install
> retries that. The guards and test steps below are updated to
> match; the app.py section is unchanged.

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

1. **Once per launch — except a failed attempt.** `autoStartAttempted`
   is set when a real attempt starts, so a foreground return cannot
   start a second engine. A failed attempt releases it, so the next
   foreground return retries; one retry timer also fires 60 s after
   a failure, once per launch (`noteAutoStartFailed`).
2. **Already running / starting.** State Running or Starting
   does nothing.
3. **User stopped it — gone (2026-11-22).** There is no manual Stop
   any more, so the stop flag is removed. The health timer's own
   restart is unaffected: `stopEngine` (health restart, mode-switch
   restart) bumps the serve generation, and a completion from an
   older generation is ignored.
4. **Core not linked.** `guestCoreLinked == NO` does nothing:
   the honest "cannot start in this build" state stays exactly
   as it was. This is the unlinked local build: auto-start
   compiles there, logs "Auto-start skipped: engine not ready
   yet in this build", and never touches the start path.
5. **Setup not done.** State NotInstalled or Installing does
   nothing. The user still taps through first-launch setup
   first; when setup finishes, the startup screen's state
   observer calls `maybeAutoStartEngine` on the Installed
   transition, so the engine starts with no further tap. A
   failed setup (Error + image not installed) is not retried
   automatically — the startup screen's Install retries that.

A failed auto-start is logged ("Auto-start failed: … Retrying in
60s; bringing the app to the foreground tries again.") and the
state change (Error / CorePending) reaches every screen through
the state observers. No alert is shown for it.

## Stop while starting (serve generation)

The Stop button is gone (2026-11-22), but the generation guard
stays: `stopEngine` (health-timer restart, mode-switch restart)
bumps the generation, and a completion from an older generation
is ignored (logged, no state change, no completion call). A stop
during a start used to lose: the guest executor's late completion
marked the engine Running again and restarted the health timer;
the generation counter fixes that.

## How to test on device (Mac / core-linked build)

1. Fresh launch with setup already done and the engine stopped:
   the Engine screen should show "Starting engine" and the
   progress bar moving through boot / Node / OpenCode / server
   start, with no tap. Threads should show "Engine: Starting
   engine", then "Engine running".
2. No Stop button any more: background the app while the engine
   runs and foreground it again — the engine keeps running, and
   a failed engine retries on the foreground return.
3. Kill the app while the engine runs and relaunch: the engine
   starts again on its own (once per launch).
4. Unlinked build: launch shows the Engine screen with state +
   logs only and no Start button; the log has the "Auto-start
   skipped: engine not ready yet" line and nothing else changed.

## App auto-start — /root/Projects/app.py (2026-11-20)

The user's own app starts with the engine, so it is up without
anyone typing a command. Why the bootstrap does it: the guest
agent cannot start it itself. It treats its shell as read-only and
refuses state-changing commands, and a fresh re-test on 2026-11-20
confirmed the server was never actually up: curl to
127.0.0.1:8000 fails and server.log is still 0 bytes. (An earlier
note saying the server was up was wrong.)

What happens on every engine start, in the guest bootstrap
(`OCEngine.m`, `startServeWithCompletion`, before the old server
is killed and the OpenCode server starts):

```sh
if [ -f /root/Projects/app.py ]; then
  (cd /root/Projects && nohup python3 app.py > server.log 2>&1 &)
  echo "app.py started" >> "$SLOG"
fi
```

This is the exact command the guest agent itself gave. Guards:

- **File must exist.** `[ -f /root/Projects/app.py ]` — a missing
  app.py changes nothing.
- **Detached.** `nohup` plus `&` in a subshell, so the app
  survives the bootstrap shell exiting. Its output goes to
  `/root/Projects/server.log`.
- **Never fails the engine start.** The block always exits 0, and
  it runs before the OpenCode server launch, so a broken app.py
  cannot stop the engine. If an older app.py still holds port
  8000, the new one just exits while the old one keeps serving;
  no process is killed.
- **Every engine start**, manual or auto: the app comes up with
  the engine, and dies with it when the app is closed (iOS kills
  the guest with the app; files persist).

How to test on device: start the engine, then in a guest shell
run `curl -s http://127.0.0.1:8000 | grep -o 'Hello from Python'`
— it should print the line. `server.log` in /root/Projects should
be non-empty. The startup screen's Log button shows the
"app.py started" line in the guest serve.log.
