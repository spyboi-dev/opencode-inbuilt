// OCEngine - the in-app engine host.
//
// ONE app, real OpenCode inside it. On launch the engine boots,
// starts the OpenCode server on 127.0.0.1:4096 (password in the
// Keychain, Basic auth user `opencode`), and shows the real
// OpenCode desktop app. The native iOS UI talks to that same
// server. There is no CLI mode any more (removed 2026-11-25):
// Desktop UI only, always.
//
// Engine interface: the engine provides an executor (a block
// that types a command at the system console; see KernGlue).
// The executor is registered on the first Start: the engine
// framework is loaded there, never at app launch, so a framework
// that dies while loading cannot kill the launch. In a build
// where the engine framework did not load, the engine reports
// that state and never pretends to be running. Everything else
// in this class works today: first-launch download (SHA-256
// verified), password handling, health checks and auto-restart.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, OCEngineState) {
    OCEngineStateNotInstalled, // first launch setup not done
    OCEngineStateInstalling,   // downloading/verifying the image
    OCEngineStateInstalled,    // image ready, not started
    OCEngineStateStarting,     // booting / server launching
    OCEngineStateRunning,      // desktop up, server answering on 4096
    OCEngineStateStopped,      // stopped (app killed, iOS suspend)
    OCEngineStateCorePending,  // engine not linked in this build
    OCEngineStateError
};

typedef void (^OCGuestExecutor)(NSString *command, NSString *workingDirectory,
                                void (^completion)(NSString * _Nullable output, NSInteger exitCode));

@interface OCEngine : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) OCEngineState state;
@property (nonatomic, readonly) NSString *stateDescription;
@property (nonatomic, readonly) BOOL guestCoreLinked; // NO when the engine framework did not load
// The engine has not been loaded yet, so the executor is not
// installed — but it CAN load on the first Start (see
// ensureRuntimeLoaded in KernGlue). NO in builds without the
// engine, where Start can never work.
@property (nonatomic, readonly) BOOL guestCoreLoadable;
// YES when a Start can be attempted: the engine is linked, or it
// can still be loaded on demand (not loaded yet).
@property (nonatomic, readonly) BOOL engineCanStart;
@property (nonatomic, copy, nullable) OCGuestExecutor guestExecutor; // set by the linked core
@property (nonatomic, copy, nullable) void (^stateDidChange)(OCEngineState state);
// Multicast state observers. stateDidChange above is a single
// callback, so whichever screen loaded last used to steal it and the
// other screen's engine row went stale. Observers all get every
// change; -addStateChangeObserver returns a token to pass to
// -removeStateChangeObserver (do it in dealloc). The legacy
// stateDidChange block, if set, is still called as well.
- (id)addStateChangeObserver:(void (^)(OCEngineState state))observer;
- (void)removeStateChangeObserver:(nullable id)token;
// Start the engine automatically, once per launch, when it can
// start: core linked and setup already done. Does nothing when the
// engine is already running or starting, when the core is not
// linked, or when setup has not finished. A failed automatic
// start retries by itself (2026-11-22: there is no manual Start
// any more): the next foreground return tries again, and one
// retry timer fires 60 s later. Safe to call in the unlinked
// build: it just leaves the honest "cannot start" state alone.
// It also waits for the launch update check to settle, and never
// auto-starts past a pending update (see updateAvailable).
- (void)maybeAutoStartEngine;
// YES when the installed image is an older release than
// this build's. A version difference is an update, never a
// failure: the image boots as-is, and the startup screen offers
// Update (plus Start to boot as-is) instead of auto-starting
// into the old image. Set by the launch update check.
@property (nonatomic, readonly) BOOL updateAvailable;
// YES while the launch update check (background, at cold launch)
// is still running. Auto-start waits for it to settle.
@property (nonatomic, readonly) BOOL launchUpdateCheckInFlight;
// Boot the installed image as-is, update or no update. Only from
// the stopped-with-update state (the startup screen's secondary
// Start button). The update stays available afterwards.
- (void)bootInstalledImageAsIs;
// In-app engine log + serve progress (for the Logs view and the Engine tab).
// serveProgress is 0..1 while the engine is starting; serveStatus is the
// current start stage ("Checking Node...", "Starting desktop...", ...).
@property (nonatomic, readonly) double serveProgress;
@property (nonatomic, readonly, nullable) NSString *serveStatus;
@property (nonatomic, copy, nullable) void (^serveProgressDidChange)(double progress, NSString * _Nullable status);
// Append a timestamped line to the in-app engine log (also persisted to
// Documents/Engine/engine.log). Never includes the server password.
- (void)appendEngineLog:(NSString *)line;
// Synchronous twin: the line is on disk when this returns. Used only
// for launch and boot milestones, where a crash a moment later must
// not lose the line that explains it. Safe from any thread.
- (void)appendEngineLogSync:(NSString *)line;
// Path of the persisted engine log, Documents/Engine/engine.log.
- (NSString *)engineLogPath;
// Full diagnostic text: engine log + console log. Missing files
// are noted instead of failing.
- (NSString *)fullLogText;
// Feed one chunk of console output (from KernGlue). Parses
// PROGRESS / ERROR / `DESKTOP READY` lines and appends the text to
// the console log.
- (void)handleGuestConsoleText:(NSString *)text;

- (void)refreshState;
- (void)startEngineWithCompletion:(void (^)(BOOL started, NSError * _Nullable error))completion;
- (void)stopEngine;
- (void)checkHealthWithCompletion:(void (^)(BOOL healthy, NSDictionary * _Nullable info))completion;
// First-launch setup: downloads the prebuilt system image
// (Node + OpenCode baked in) and verifies the SHA-256 of the
// archive and of the extracted image. Safe to call again; a verified
// image on disk skips the download.
- (BOOL)guestImageInstalled;
- (void)runFirstLaunchSetupWithProgress:(void (^)(double fraction, NSString *message))progress
                             completion:(void (^)(BOOL done, NSError * _Nullable error))completion;
- (NSString *)engineDirectory;    // Documents/Engine
@end

NS_ASSUME_NONNULL_END
