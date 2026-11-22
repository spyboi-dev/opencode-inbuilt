// OCEngine - the in-app engine host.
//
// ONE app, real OpenCode inside it. The engine is the Kernarium core:
// a real Linux 6.18 kernel running a Debian 13 guest in-process, with
// Node and OpenCode (2.3.0) baked into the guest image. On launch the
// engine boots the guest and, depending on the engine mode, runs
// either the OpenCode CLI server or the real OpenCode desktop app:
//   CLI        - `opencode serve --port 4096 --hostname 0.0.0.0`
//                with OPENCODE_SERVER_PASSWORD from the Keychain. The
//                native iOS UI talks to the server at 127.0.0.1:4096
//                through the vsock bridge (see KernGlue).
//   Desktop UI - the real OpenCode Linux desktop app runs in the
//                guest and its window shows through the guest display
//                (Virtio-GPU to a Metal view). The native UI stays
//                available; the desktop window is a second surface.
// The mode is the user's choice, persisted in OCSettings, default
// CLI. Switching modes restarts the engine in the new mode.
//
// Guest boot interface: the embedded core provides a guest executor
// (a block that types a command at the guest console; see KernGlue).
// The executor is registered by the linked core on the first Start:
// the runtime framework is dlopen'd there, never at app launch, so
// a framework that dies while loading cannot kill the launch. In a
// build where the runtime framework did not load, the engine reports
// that state honestly and never pretends the guest is running.
// Everything else in this class is real and works today:
// first-launch guest image download (SHA-256 verified), password
// handling, health checks and auto-restart.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Engine modes. CLI is the default.
extern NSString *const OCEngineModeCLI;     // @"cli"
extern NSString *const OCEngineModeDesktop; // @"desktop"

typedef NS_ENUM(NSInteger, OCEngineState) {
    OCEngineStateNotInstalled, // first launch setup not done
    OCEngineStateInstalling,   // downloading/verifying the guest image
    OCEngineStateInstalled,    // image ready, guest not started
    OCEngineStateStarting,     // guest booting / serve launching
    OCEngineStateRunning,      // server answering (CLI) / desktop up (Desktop UI)
    OCEngineStateStopped,      // guest stopped (app killed, iOS suspend)
    OCEngineStateCorePending,  // guest core library not linked in this build
    OCEngineStateError
};

typedef void (^OCGuestExecutor)(NSString *command, NSString *workingDirectory,
                                void (^completion)(NSString * _Nullable output, NSInteger exitCode));

@interface OCEngine : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) OCEngineState state;
@property (nonatomic, readonly) NSString *stateDescription;
@property (nonatomic, readonly) BOOL guestCoreLinked; // NO when the runtime framework did not load
// Kernarium build only: the runtime framework has not been loaded
// yet, so the executor is not installed — but it CAN load on the
// first Start (see ensureRuntimeLoaded in KernGlue). NO in builds
// without the runtime, where Start can never work.
@property (nonatomic, readonly) BOOL guestCoreLoadable;
// YES when a Start can be attempted: the core is linked, or it can
// still be loaded on demand (Kernarium build, not loaded yet).
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
- (void)maybeAutoStartEngine;
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
// Full diagnostic text: engine log + guest console log. Missing files
// are noted instead of failing.
- (NSString *)fullLogText;
// Feed one chunk of guest console output (from KernGlue). Parses
// PROGRESS / ERROR / `server listening` / `DESKTOP READY` lines and
// appends the text to the guest console log.
- (void)handleGuestConsoleText:(NSString *)text;

- (void)refreshState;
- (void)startEngineWithCompletion:(void (^)(BOOL started, NSError * _Nullable error))completion;
- (void)stopEngine;
- (void)checkHealthWithCompletion:(void (^)(BOOL healthy, NSDictionary * _Nullable info))completion;
// First-launch setup: downloads the prebuilt Debian guest image
// (ext4, Node + OpenCode baked in) and verifies the SHA-256 of the
// archive and of the extracted image. Safe to call again; a verified
// image on disk skips the download.
- (BOOL)guestImageInstalled;
- (void)runFirstLaunchSetupWithProgress:(void (^)(double fraction, NSString *message))progress
                             completion:(void (^)(BOOL done, NSError * _Nullable error))completion;
// Engine mode: OCEngineModeCLI (default) or OCEngineModeDesktop.
// Persisted in OCSettings. Setting a different mode while the engine
// is running or starting restarts the engine in the new mode;
// otherwise it takes effect on the next start.
@property (nonatomic, readonly) NSString *engineMode;
- (void)setEngineMode:(NSString *)mode;
- (NSString *)serveLaunchCommand; // the exact CLI serve command run inside the guest
- (NSString *)engineDirectory;    // Documents/Engine
@end

NS_ASSUME_NONNULL_END
