// OCEngine - the in-app engine host.
//
// ONE app, real OpenCode inside it. The engine is the LinuxRunner core:
// an ARM64 interpreter + Linux syscall layer running a Debian 13 guest
// in-process, with Node and OpenCode (opencode-ai@2.3.0) installed in it.
// On launch the engine boots the guest and runs:
//   opencode serve --port 4096 --hostname 0.0.0.0
// with OPENCODE_SERVER_PASSWORD from the Keychain. Node runs --jitless
// under the interpreter. The UI talks to the server at 127.0.0.1:4096.
//
// Guest boot interface: the embedded core provides a guest executor
// (a block that runs a command inside the guest and returns its output).
// The executor is registered by the linked core at app start. In this
// build the core library is NOT yet linked (see BUILD-NOTE.md, "Embedding
// decision"): the engine reports that state honestly and never pretends
// the guest is running. Everything else in this class is real and works
// today: first-launch Debian package cache (download + SHA-256 verify
// against the bundled manifest), password handling, health checks and
// auto-restart.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, OCEngineState) {
    OCEngineStateNotInstalled, // first launch setup not done
    OCEngineStateInstalling,   // downloading/verifying Debian packages
    OCEngineStateInstalled,    // packages cached, guest not started
    OCEngineStateStarting,     // guest booting / serve launching
    OCEngineStateRunning,      // /api/info answers
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
@property (nonatomic, readonly) BOOL guestCoreLinked; // NO in this build, see BUILD-NOTE.md
@property (nonatomic, copy, nullable) OCGuestExecutor guestExecutor; // set by the linked core
@property (nonatomic, copy, nullable) void (^stateDidChange)(OCEngineState state);
// In-app engine log + serve progress (for the Logs view and the Engine tab).
// serveProgress is 0..1 while the engine is starting; serveStatus is the
// current start stage ("Downloading Node...", "Installing OpenCode...", ...).
@property (nonatomic, readonly) double serveProgress;
@property (nonatomic, readonly, nullable) NSString *serveStatus;
@property (nonatomic, copy, nullable) void (^serveProgressDidChange)(double progress, NSString * _Nullable status);
// Append a timestamped line to the in-app engine log (also persisted to
// Documents/Engine/engine.log). Never includes the server password.
- (void)appendEngineLog:(NSString *)line;
// Full diagnostic text: engine log + guest boot.log + guest serve.log.
// Missing files are noted instead of failing.
- (NSString *)fullLogText;

- (void)refreshState;
- (void)startEngineWithCompletion:(void (^)(BOOL started, NSError * _Nullable error))completion;
- (void)stopEngine;
- (void)checkHealthWithCompletion:(void (^)(BOOL healthy, NSDictionary * _Nullable info))completion;
// First-launch setup: downloads the Debian 13.7 package set from
// deb.debian.org (37 MB, 103 packages) and verifies every SHA-256
// against the bundled manifest. Safe to call again; verified files skip.
- (void)runFirstLaunchSetupWithProgress:(void (^)(double fraction, NSString *message))progress
                             completion:(void (^)(BOOL done, NSError * _Nullable error))completion;
- (NSString *)serveLaunchCommand; // the exact command run inside the guest
- (NSString *)engineDirectory;    // Documents/Engine
@end

NS_ASSUME_NONNULL_END
