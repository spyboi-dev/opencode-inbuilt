// OCEngine - the in-app engine host.
#import "OCEngine.h"
#import "OCServerClient.h"
#import "OCSettings.h"
#import "OCGuestInstall.h"

#ifdef OC_KERNARIUM_LINKED
#import "KernGlue.h"
#endif

static NSString *const kGuestImageInstalled = @"oc.guestImageInstalled";

@interface OCEngine ()
@property (nonatomic, assign) OCEngineState state;
@property (nonatomic, strong, nullable) NSTimer *healthTimer;
@property (nonatomic, assign) NSInteger healthFailures;
// First start can take a while (guest boot); health failures before
// this date are ignored so the engine is not restarted while the
// guest is still coming up.
@property (nonatomic, strong, nullable) NSDate *healthGraceUntil;
@property (nonatomic, assign) double serveProgressValue;
@property (nonatomic, strong, nullable) NSString *serveStatusValue;
@property (nonatomic, assign) BOOL serveProgressDone;
// Guest diagnostics fetched through the server's file API
// (fetchGuestDiagnosticsIfNeeded): the console drops output
// once the TUI takes over, so the diagnostics file is read
// over HTTP instead. The file is rewritten every 10 s by the
// guest's diag-loop, so fetching is repeated on the same 10 s
// cadence (not once per boot): the first fetch is always too
// early — it lands before the CLI starts — and only the later
// ones name the TUI's state. Blocks are logged only when their
// content changed since the last fetch, so the engine log gets
// the state transitions, not twelve copies of the same block.
@property (nonatomic, assign) BOOL guestDiagnosticsFetched;
@property (nonatomic, strong, nullable) NSString *lastGuestDiagnosticsText;
// Misses are retried on a timer (fetchGuestDiagnosticsIfNeeded):
// the diagnostics file is written ~20 s after serve starts, so
// the first fetch usually misses. Attempts cap the retries.
@property (nonatomic, assign) NSUInteger guestDiagnosticsFetchAttempts;
@property (nonatomic, assign) BOOL guestDiagnosticsRetryPending;
// YES once the CLI bootstrap (phase 2) has been sent to the
// guest console. Phase 2 goes only after the server probe first
// succeeds, so the shell is idle and the tty buffer cannot drop
// the middle of a paste (977334d).
@property (nonatomic, assign) BOOL cliBootstrapSent;
// YES once the CLI TUI reported ready.
@property (nonatomic, assign) BOOL cliReady;
// YES once the guest console has shown the autologin shell prompt
// ("termux@termx"). Phase 1 is typed only after this: the boot
// gate fires on the getty "login: " prompt, which is not a shell,
// and typing a script into getty eats it as login attempts
// (dceea4c: dozens of "termx login:" prompts, ending at
// "Password:"). The prompt has no trailing newline, so it is
// detected on the raw console text, not on complete lines.
@property (nonatomic, assign) BOOL shellPromptSeen;
// YES while phase 1 is waiting to be sent; NO once it has been
// sent (or the watchdog gave up). phase1Generation is the serve
// attempt it belongs to, so a late trigger cannot send a stale
// bootstrap into a restarted engine.
@property (nonatomic, assign) BOOL phase1Pending;
@property (nonatomic, assign) BOOL phase1Sent;
@property (nonatomic, assign) NSUInteger phase1Generation;
// YES once the guest console printed "server listening" (the
// bootstrap's curl probe to /api/info succeeded in the guest).
@property (nonatomic, assign) BOOL serverListening;
// /api/info probe through the vsock bridge (the path the native UI
// uses): at most one in flight, last result remembered so a slow
// probe cannot pile up on the 5 s health timer. serverProbeEverOK
// is YES once a probe has ever succeeded; lastProbeLoggedError is
// the failure text already written to the log, so a dead server
// logs on transition only instead of every 5 s.
@property (nonatomic, assign) BOOL healthProbeInFlight;
@property (nonatomic, assign) BOOL lastProbeOK;
@property (nonatomic, assign) BOOL serverProbeEverOK;
@property (nonatomic, strong, nullable) NSString *lastProbeError;
@property (nonatomic, strong, nullable) NSString *lastProbeLoggedError;
@property (nonatomic, strong, nullable) NSMutableArray<NSDictionary *> *stateObserverEntries;
@property (nonatomic, assign) BOOL autoStartAttempted;
// First-launch setup in flight (2026-11-22 09:54 race): the guard
// is a flag, not the state variable — refreshState used to clobber
// Installing back to NotInstalled mid-download, so a state check
// let a second Install through to installGuestTo, which failed
// with "install already in progress" and flipped the state to
// Error, killing the first download's state.
@property (nonatomic, assign) BOOL setupInFlight;
// One automatic retry after a failed auto-start, 60 s later, once
// per launch (reset when the server is next confirmed healthy).
// A foreground return retries too; the timer is only so a failure
// while the app sits open heals itself.
@property (nonatomic, strong, nullable) NSTimer *autoStartRetryTimer;
@property (nonatomic, assign) BOOL autoStartRetryUsed;
@property (nonatomic, assign) NSUInteger serveGeneration;
// Launch update check (TermX c2f4ed5 + 28f2191): YES while the
// background check is still settling whether the installed image
// is this build's release; YES once it has settled on an older
// release. Readwrite here so the check can set them; the header
// exposes them readonly.
@property (nonatomic, assign) BOOL updateAvailable;
@property (nonatomic, assign) BOOL launchUpdateCheckInFlight;
@property (nonatomic, assign) BOOL launchUpdateCheckStarted;
- (void)startServeWithCompletion:(void (^)(BOOL, NSError * _Nullable))completion;
// The autologin shell prompt ("termux@termx") was seen on the
// guest console; phase 1 can go now (see startServeWithCompletion).
- (void)noteShellPromptSeen;
// Sends phase 1 once, if it is still pending for this serve
// attempt. Idempotent; safe to call from any trigger.
- (void)sendPhase1IfPending;
// CLI bootstrap (phase 2): sent only after the /api/info
// probe first succeeds, so the guest shell is idle. See
// consoleBootstrap (phase 1) for why the split exists.
- (NSString *)cliBootstrap;
// Writes the CLI script to the guest as a file through the
// server's file API, then types only the one-line `sh` command
// to run it. Typing a multi-KB script dropped bytes even into
// an idle shell (df597d2), so the file is the delivery now.
- (void)deliverCliBootstrap;
- (void)checkForImageUpdateForLaunch;
- (void)noteAutoStartFailed:(NSString *)reason;
@end

@implementation OCEngine

+ (instancetype)shared {
    static OCEngine *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[OCEngine alloc] init]; [s refreshState]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _stateObserverEntries = [NSMutableArray array];
        // The launch update check starts here, at first access:
        // AppDelegate calls refreshState then maybeAutoStartEngine
        // right after, so the in-flight flag must already be set
        // for the auto-start to wait on it.
        [self startLaunchUpdateCheckIfNeeded];
    }
    return self;
}

// The guest image path, computed directly (engineDirectory/guest
// + name) instead of through OCKernGlue: the glue's guestImagePath
// calls [OCEngine shared], and this runs from init inside
// shared's dispatch_once — going through the glue would deadlock.
// Identical path either way (KernGlue guestDirectory is
// engineDirectory/guest).
- (NSString *)guestImagePath {
    return [[[self engineDirectory] stringByAppendingPathComponent:@"guest"]
        stringByAppendingPathComponent:kOCGuestImageName];
}

// Launch update check (TermX c2f4ed5 + 28f2191): settles whether
// the installed image is this build's release, on a background
// queue — never the main thread, it can hash 1.78 GB. It sets
// updateAvailable, and when a newer image is available it holds
// the guest stopped (Installed -> Stopped) so the startup screen
// offers a tappable Update button (and a Start button to boot
// as-is) instead of racing the auto-boot. Runs once per launch,
// only when an image is installed. The in-flight flag is set
// synchronously here so the auto-start call right after this in
// didFinishLaunching waits instead of racing.
- (void)startLaunchUpdateCheckIfNeeded {
    if (self.launchUpdateCheckStarted) return;
    self.launchUpdateCheckStarted = YES;
    if (!self.guestImageInstalled) return;
    _launchUpdateCheckInFlight = YES;
    [self checkForImageUpdateForLaunch];
}

- (void)checkForImageUpdateForLaunch {
    NSString *imagePath = [self guestImagePath];
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __strong typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        // Cheap first: the fingerprint recorded by the install
        // pipeline carries the hash it verified. A recorded hash
        // answers with no 1.78 GB hash at all — equal means
        // current, different means an older release.
        NSString *recordedHash = [OCGuestInstall installedImageVerifiedHashAt:imagePath];
        BOOL answered = recordedHash != nil;
        BOOL current = answered && [recordedHash isEqualToString:kOCGuestImageSHA256];
        if (!answered) {
            // No fingerprint hash to answer from (image installed
            // by an older build, or the fingerprint predates the
            // hash field): one full hash settles it, and the hash
            // is recorded in the fingerprint either way, so the
            // next launch answers cheaply — a mismatch is an older
            // release, not a reason to hash 1.78 GB every launch.
            // (TermX records only on success; with a 1.78 GB
            // image the repeated hash costs too much to copy.)
            NSString *hash = [OCGuestInstall SHA256OfImageAt:imagePath];
            if (hash) {
                current = [hash isEqualToString:kOCGuestImageSHA256];
                NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:imagePath error:nil];
                if (attrs) [OCGuestInstall recordVerifiedFingerprintForPath:imagePath attrs:attrs hash:hash];
            } else {
                // Unreadable file: not current; the Update button
                // reinstalls it, and boot refuses it as damaged.
                current = NO;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(self) strongSelf2 = weakSelf;
            if (!strongSelf2 || !strongSelf2->_launchUpdateCheckInFlight) return;
            strongSelf2->_launchUpdateCheckInFlight = NO;
            // If the user tapped Install meanwhile, the install
            // owns the flag now and this completion stands down.
            if (strongSelf2.setupInFlight || strongSelf2.state == OCEngineStateInstalling) return;
            // An update holds the boot: the guest stays stopped so
            // the startup screen shows a tappable Update button
            // (and a Start button to boot as-is) instead of racing
            // the auto-boot into "Starting...". Only while the
            // guest is still Installed — if it already booted, the
            // Update button is offered from Running instead. The
            // state moves first, so no refresh in between can
            // schedule the auto-boot.
            if (!current && strongSelf2.state == OCEngineStateInstalled) {
                [strongSelf2 appendEngineLogSync:@"Update available — tap Update to install it, or Start to boot the image you have"];
                [strongSelf2 setState:OCEngineStateStopped];
            }
            strongSelf2.updateAvailable = !current;
            [strongSelf2 appendEngineLogSync:[NSString stringWithFormat:@"Image update check: installed image is %@", current ? @"the current release" : @"an older release — update available"]];
            if (current) {
                // Current release: the auto-start that waited for
                // this check can go now, without waiting for a
                // foreground return.
                [strongSelf2 maybeAutoStartEngine];
            }
        });
    });
}

// Boot the installed image as-is, update or no update. Only from
// the stopped-with-update state (the startup screen's secondary
// Start button). The update stays available: updateAvailable is
// untouched, so the next launch (and the startup screen after
// this guest stops) still offers it. A failure here goes through
// the normal auto-start retry: the state leaves Stopped, so the
// hold no longer applies.
- (void)bootInstalledImageAsIs {
    if (self.state != OCEngineStateStopped || !self.updateAvailable) return;
    if (!self.guestImageInstalled) return;
    self.autoStartAttempted = YES;
    [self appendEngineLogSync:@"Booting installed image as-is (update still available)"];
    __weak typeof(self) weakSelf = self;
    [self startEngineWithCompletion:^(BOOL started, NSError * _Nullable error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!started) {
            [strongSelf noteAutoStartFailed:error.localizedDescription ?: @"unknown"];
        }
    }];
}

- (id)addStateChangeObserver:(void (^)(OCEngineState))observer {
    if (!observer) return nil;
    NSString *token = [[NSUUID UUID] UUIDString];
    @synchronized (self) {
        [self.stateObserverEntries addObject:@{@"token": token, @"block": [observer copy]}];
    }
    return token;
}

- (void)removeStateChangeObserver:(nullable id)token {
    if (!token) return;
    @synchronized (self) {
        NSUInteger idx = [self.stateObserverEntries indexOfObjectPassingTest:^BOOL(NSDictionary *entry, NSUInteger i, BOOL *stop) {
            (void)i; (void)stop;
            return [entry[@"token"] isEqual:token];
        }];
        if (idx != NSNotFound) [self.stateObserverEntries removeObjectAtIndex:idx];
    }
}

- (void)notifyStateObservers:(OCEngineState)state {
    NSArray *entries = nil;
    @synchronized (self) { entries = [self.stateObserverEntries copy]; }
    for (NSDictionary *entry in entries) {
        void (^block)(OCEngineState) = entry[@"block"];
        if (block) block(state);
    }
}

// Start the engine on app launch when it can start. Once per
// launch; every guard is checked again here so a second call (or a
// foreground return) cannot start a second engine behind this one.
//
// Two skips deliberately do NOT consume the one attempt: setup not
// done yet (the startup screen's Install finishes it, and the
// state observer calls this again when it does), and a failed
// setup (the startup screen's Install retries that one — a
// 451 MB download does not restart on its own). A skip that
// consumed the attempt would leave a fresh install unable to
// auto-start after its own Install.
//
// A failed START is different (2026-11-22: there is no manual
// Start any more, so a dead end in Error would strand the engine):
// when the image is installed, Error falls through and the start
// is tried again, and a failure releases the one attempt (see
// noteAutoStartFailed) so the next foreground return retries.

// A failed automatic start must not strand the engine in Error
// with no way back. The next foreground return retries (the one
// attempt is released here), and one retry timer fires 60 s
// later, once per launch, so a failure while the app sits open
// heals itself without churning a broken boot forever. The log
// says plainly what happens next.
- (void)noteAutoStartFailed:(NSString *)reason {
    [self appendEngineLogSync:[NSString stringWithFormat:@"Auto-start failed: %@. Retrying in 60s; bringing the app to the foreground tries again.", reason ?: @"unknown"]];
    self.autoStartAttempted = NO;
    if (self.autoStartRetryUsed) return;
    self.autoStartRetryUsed = YES;
    [self.autoStartRetryTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.autoStartRetryTimer = [NSTimer scheduledTimerWithTimeInterval:60.0 repeats:NO block:^(NSTimer * _Nonnull timer) {
        (void)timer;
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf appendEngineLogSync:@"Automatic retry: starting engine"];
        [strongSelf maybeAutoStartEngine];
    }];
}

- (void)maybeAutoStartEngine {
    // Wait for the launch update check to settle before
    // auto-starting: if a newer image is available the engine
    // holds the guest stopped and the Update button is the choice,
    // not a race with the auto-boot. The poll tick / the check's
    // own completion re-enters here once it has settled, so
    // nothing is lost by waiting — and the attempt is NOT
    // consumed, so a current-release image still boots.
    if (self.launchUpdateCheckInFlight) return;
    if (self.autoStartAttempted) return;
    if (self.state == OCEngineStateRunning || self.state == OCEngineStateStarting) {
        self.autoStartAttempted = YES;
        return;
    }
    if (self.state == OCEngineStateNotInstalled || self.state == OCEngineStateInstalling) {
        [self appendEngineLogSync:@"Auto-start skipped: first-launch setup not done yet"];
        return;
    }
    // An update holds the boot: the guest stays stopped so the
    // startup screen offers a tappable Update button (and a Start
    // button to boot as-is). The Start button goes through
    // bootInstalledImageAsIs, not this method, so it is never
    // blocked here.
    if (self.updateAvailable && self.state == OCEngineStateStopped) {
        [self appendEngineLogSync:@"Auto-start held: update available — Update or Start on the startup screen"];
        return;
    }
    if (self.state == OCEngineStateError) {
        // The setup itself failed (image not on disk): the retry
        // is the startup screen's Install, not this. A start
        // failure (image installed) falls through and is tried
        // again below — there is no manual Start to fall back on.
        if (!self.guestImageInstalled) {
            [self appendEngineLogSync:@"Auto-start skipped: setup failed — Install on the startup screen tries again"];
            return;
        }
        [self appendEngineLogSync:@"Auto-start: retrying after a failed start"];
    }
    // This is a real attempt now: consume the flag before any async
    // work, so a second call (observer, foreground return) cannot
    // start a second engine behind this one.
    self.autoStartAttempted = YES;
    __weak typeof(self) weakSelf = self;
    if (!self.guestCoreLinked) {
        if (!self.guestCoreLoadable) {
            [self appendEngineLogSync:@"Auto-start skipped: runtime cannot load in this build"];
            return;
        }
        // Load the runtime on a background thread (dlopen of the
        // 52 MB framework), then start on the main thread: boot
        // and serve both expect the main thread, and the UI must
        // show Starting while the load is in flight. The state
        // flips to Starting FIRST so the startup screen (and the
        // Engine tab) show the attempt and disable their Start
        // buttons — otherwise a manual Start during the load
        // would race this one into a second boot.
        [self setState:OCEngineStateStarting];
        [self appendEngineLogSync:@"Auto-start: loading Kernarium runtime..."];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
#ifdef OC_KERNARIUM_LINKED
            BOOL loaded = [[OCKernGlue shared] ensureRuntimeLoaded];
#else
            BOOL loaded = NO;
#endif
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) strongSelf = weakSelf;
                if (!strongSelf) return;
                if (!loaded) {
                    [strongSelf setState:OCEngineStateCorePending];
                    [strongSelf noteAutoStartFailed:@"the Kernarium runtime did not load"];
                    return;
                }
                [strongSelf startEngineWithCompletion:^(BOOL started, NSError * _Nullable error) {
                    typeof(self) strongSelf2 = weakSelf;
                    if (!strongSelf2) return;
                    if (!started) {
                        [strongSelf2 noteAutoStartFailed:error.localizedDescription ?: @"unknown"];
                    }
                }];
            });
        });
        return;
    }
    [self appendEngineLogSync:@"Auto-start: starting engine"];
    [self startEngineWithCompletion:^(BOOL started, NSError * _Nullable error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!started) {
            [strongSelf noteAutoStartFailed:error.localizedDescription ?: @"unknown"];
        }
    }];
}

- (BOOL)guestCoreLinked { return self.guestExecutor != nil; }

- (BOOL)guestCoreLoadable {
#ifdef OC_KERNARIUM_LINKED
    // Kernarium build: the runtime has not been loaded yet (it
    // loads on the first Start), so the executor is not installed
    // — but a Start can still load it. A build without the runtime
    // never reaches this branch.
    return self.guestExecutor == nil;
#else
    return NO;
#endif
}

- (BOOL)engineCanStart { return self.guestCoreLinked || self.guestCoreLoadable; }

- (NSString *)engineDirectory {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"Engine"];
}

- (NSString *)stateDescription {
    switch (self.state) {
        case OCEngineStateNotInstalled: return @"Not installed";
        case OCEngineStateInstalling: return @"Installing";
        case OCEngineStateInstalled: return @"Installed, stopped";
        case OCEngineStateStarting: return @"Starting engine";
        case OCEngineStateRunning: return @"Engine running";
        case OCEngineStateStopped: return @"Engine stopped";
        case OCEngineStateCorePending: return @"Not ready yet";
        case OCEngineStateError: return @"Engine error";
    }
}

- (void)setState:(OCEngineState)state {
    if (_state == state) return;
    _state = state;
    // Synchronous: a state change is a milestone, and a crash a
    // moment later must not lose the line that says where the
    // engine got to.
    [self appendEngineLogSync:[NSString stringWithFormat:@"State: %@", self.stateDescription]];
    if (self.stateDidChange) self.stateDidChange(state);
    [self notifyStateObservers:state];
}

- (void)refreshState {
    // Do not clobber a live engine: viewWillAppear calls this every
    // time the Engine tab is shown, and it was resetting a Running
    // engine back to "Installed, guest stopped" while the server
    // was up. The flag on disk only describes install state.
    // Do not clobber an install in flight either: while a download
    // is running the flag still says "not installed", and resetting
    // to NotInstalled mid-download re-enabled Install — the next
    // tap then failed with "install already in progress" and
    // flipped the state to Error (2026-11-22 09:54). Error is NOT
    // skipped: a failed setup re-derives to NotInstalled so
    // Install can be retried, and a failed start re-derives to
    // Installed so auto-start can retry it.
    if (self.state == OCEngineStateRunning || self.state == OCEngineStateStarting ||
        self.state == OCEngineStateInstalling) return;
    // Do not undo the update hold: while the guest is stopped
    // with an update available, the state must stay Stopped so
    // the startup screen keeps offering Update / Start. Without
    // this, re-deriving from the install flag would flip it back
    // to Installed and the next auto-start would race the choice.
    if (self.updateAvailable && self.state == OCEngineStateStopped) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d boolForKey:kGuestImageInstalled]) { [self setState:OCEngineStateNotInstalled]; return; }
    [self setState:OCEngineStateInstalled];
}

#pragma mark - Engine log + console feed (in-app diagnostics)

// Serial queue so log appends from any thread (main, console
// callback, timers) cannot interleave in the file.
static const void *kOCEngineLogQueueKey = &kOCEngineLogQueueKey;
static dispatch_queue_t OCEngineLogQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.spyboy.opencode.engineLog", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(q, kOCEngineLogQueueKey, (void *)1, NULL);
    });
    return q;
}

// Incomplete console line held between chunks, on the log queue only.
static NSMutableString *OCEngineConsolePartial(void) {
    static NSMutableString *partial;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ partial = [NSMutableString string]; });
    return partial;
}

- (NSString *)engineLogPath {
    return [[self engineDirectory] stringByAppendingPathComponent:@"engine.log"];
}

- (NSString *)guestConsoleLogPath {
    return [[self engineDirectory] stringByAppendingPathComponent:@"guest.log"];
}

// Keep a log file from growing forever: once it passes 512 KB,
// keep only the last 256 KB, starting at a line boundary.
// Byte-based, so a chunk of non-UTF-8 console output cannot defeat
// it. Runs on OCEngineLogQueue only.
static void OCEngineCapLogFileToTail(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length <= 256 * 1024) return;
    NSUInteger keepFrom = data.length - 256 * 1024;
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    while (keepFrom < data.length && bytes[keepFrom] != '\n') keepFrom++;
    if (keepFrom < data.length) keepFrom++; // skip the newline itself
    NSData *tail = [data subdataWithRange:NSMakeRange(keepFrom, data.length - keepFrom)];
    [tail writeToFile:path atomically:YES];
}

// The file write itself: queue-confined (see OCEngineLogQueue).
// Creates the directory, appends one timestamped line, and keeps
// the file from growing forever by keeping only the last 256 KB
// once it passes 512 KB. Failure-tolerant: a logging failure must
// never break the engine.
static void OCEngineWriteLogLineToFile(NSString *path, NSString *line) {
    if (!path.length || !line.length) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss";
    NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:[NSDate date]], line];
    NSData *data = [entry dataUsingEncoding:NSUTF8StringEncoding];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!fh) {
        [data writeToFile:path atomically:NO];
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:data];
    unsigned long long size = [fh offsetInFile];
    // fsync before close: a SIGKILL a millisecond later cannot
    // lose the line. (write() alone survives process death, but
    // the download milestones must survive anything short of the
    // phone losing power, so the next log names the exact part,
    // percent and footprint where it died.)
    [fh synchronizeFile];
    [fh closeFile];
    if (size > 512 * 1024) OCEngineCapLogFileToTail(path);
}

- (void)appendEngineLog:(NSString *)line {
    if (!line.length) return;
    NSString *copy = [line copy];
    dispatch_async(OCEngineLogQueue(), ^{
        OCEngineWriteLogLineToFile([self engineLogPath], copy);
    });
}

- (void)appendEngineLogSync:(NSString *)line {
    if (!line.length) return;
    NSString *copy = [line copy];
    if (dispatch_get_specific(kOCEngineLogQueueKey)) {
        // Already on the log queue: write directly instead of
        // deadlocking on dispatch_sync.
        OCEngineWriteLogLineToFile([self engineLogPath], copy);
        return;
    }
    dispatch_sync(OCEngineLogQueue(), ^{
        OCEngineWriteLogLineToFile([self engineLogPath], copy);
    });
}

+ (nullable NSString *)contentsOfFileOrNote:(NSString *)path label:(NSString *)label {
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text) return [NSString stringWithFormat:@"(%@ not present yet)\n", label];
    if (!text.length) return [NSString stringWithFormat:@"(%@ is empty)\n", label];
    return text;
}

// Last N lines of a file, or the whole file when it is short. The
// display activity log can hold a line a second while the terminal
// runs, so the pasted log carries its tail, not its whole history.
+ (nullable NSString *)tailOfFile:(NSString *)path maxLines:(NSUInteger)maxLines label:(NSString *)label {
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text) return [NSString stringWithFormat:@"(%@ not present yet)\n", label];
    if (!text.length) return [NSString stringWithFormat:@"(%@ is empty)\n", label];
    NSArray *lines = [text componentsSeparatedByString:@"\n"];
    if (lines.count <= (NSInteger)maxLines + 1) return text;
    NSArray *tail = [lines subarrayWithRange:NSMakeRange(lines.count - maxLines, maxLines)];
    return [[NSString stringWithFormat:@"(... %lu earlier lines omitted)\n", (unsigned long)(lines.count - maxLines)] stringByAppendingString:[tail componentsJoinedByString:@"\n"]];
}

- (NSString *)fullLogText {
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"=== Engine log ===\n"];
    NSString *engine = [OCEngine contentsOfFileOrNote:[self engineLogPath] label:@"engine.log"];
    [out appendString:engine];
    if (![engine hasSuffix:@"\n"]) [out appendString:@"\n"];
    [out appendString:@"\n=== Guest log (console) ===\n"];
    [out appendString:@"(Guest boot and serve output arrive over the console now; there is no separate serve.log file.)\n"];
    NSString *guest = [OCEngine contentsOfFileOrNote:[self guestConsoleLogPath] label:@"guest.log"];
    // A guest.log that says "server listening" while the engine is
    // stopped is from a previous run (the guest dies when the app
    // is closed, the log file survives). Say so, or the screen
    // contradicts itself: state "stopped" above a log that claims
    // the server is up.
    if (self.state != OCEngineStateRunning && self.state != OCEngineStateStarting &&
        ([guest containsString:@"server listening"] || [guest containsString:@"CLI READY"])) {
        [out appendString:@"(Log from a previous run: the engine is stopped now, so this is not live.)\n"];
    }
    [out appendString:guest];
    [out appendString:@"\n=== Display log (runtime) ===\n"];
    [out appendString:@"(The runtime's own record of guest scanouts: presented, dropped, or refused and why. Written only when the runtime logs it; absent means no scanout was recorded.)\n"];
    NSString *displayLog = [[self engineDirectory] stringByAppendingPathComponent:@"display-activity.log"];
    [out appendString:[OCEngine tailOfFile:displayLog maxLines:100 label:@"display-activity.log"]];
    return out;
}

- (double)serveProgress { return self.serveProgressValue; }
- (nullable NSString *)serveStatus { return self.serveStatusValue; }

- (void)setServeProgress:(double)progress status:(nullable NSString *)status {
    self.serveProgressValue = progress;
    self.serveStatusValue = status;
    void (^cb)(double, NSString * _Nullable) = self.serveProgressDidChange;
    if (cb) dispatch_async(dispatch_get_main_queue(), ^{ cb(progress, status); });
}

// One complete guest console line, on the main queue. Applies
// PROGRESS / ERROR lines and the definitive start signals.
// Strip ANSI escape sequences (CSI, OSC, and single-char escapes)
// from a console line. The guest console wraps output in bracketed
// paste markers (ESC[?2004l / ESC[?2004h) and the shell prompt adds
// color codes, so a bare marker line like "CLI READY" arrives
// with a prefix that defeats hasPrefix/isEqualToString. Stripping
// lets the marker match on the bare output line only.
static NSString *OCEngineStripANSI(NSString *line) {
    NSMutableString *out = [NSMutableString stringWithCapacity:line.length];
    NSUInteger i = 0, n = line.length;
    while (i < n) {
        unichar c = [line characterAtIndex:i];
        if (c == 0x1B) {
            // ESC [ ... final byte: CSI sequence.
            if (i + 1 < n && [line characterAtIndex:i + 1] == '[') {
                i += 2;
                while (i < n) {
                    unichar d = [line characterAtIndex:i];
                    i++;
                    if (d >= 0x40 && d <= 0x7E) break;
                }
                continue;
            }
            // ESC ] ... BEL or ESC \: OSC sequence.
            if (i + 1 < n && [line characterAtIndex:i + 1] == ']') {
                i += 2;
                while (i < n) {
                    unichar d = [line characterAtIndex:i];
                    if (d == 0x07) { i++; break; }
                    if (d == 0x1B && i + 1 < n && [line characterAtIndex:i + 1] == '\\') { i += 2; break; }
                    i++;
                }
                continue;
            }
            // Any other ESC sequence: drop ESC and the next char.
            i += (i + 1 < n) ? 2 : 1;
            continue;
        }
        [out appendFormat:@"%C", c];
        i++;
    }
    return out;
}

- (void)handleGuestConsoleLine:(NSString *)line {
    if (!line.length) return;
    // Clean the line first: strip ANSI escapes, then trim. The
    // bare marker lines arrive with a bracketed-paste prefix
    // (ESC[?2004l), so the prefix checks below must run on the
    // cleaned line or they never match.
    NSString *clean = [OCEngineStripANSI(line) stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!clean.length) return;
    if ([clean containsString:@"termux@termx"]) {
        // The shell prompt prefixes every echoed command line,
        // and the bare prompt itself is caught on the raw text
        // (see handleGuestConsoleText). Either way, the shell
        // is up, so phase 1 can go.
        [self noteShellPromptSeen];
    }
    if ([clean hasPrefix:@"DIAG "]) {
        // The bootstrap's compact CLI summary: it belongs in
        // the engine log too, so the pasted log names the VT, the
        // server and the TUI state without needing the whole
        // guest console. The full block stays in guest.log.
        [self appendEngineLogSync:clean];
        return;
    }
    if ([clean isEqualToString:@"server listening"]) {
        // The bootstrap's curl probe to /api/info succeeded in the
        // guest. Record it and log it. This must be an exact match:
        // the typed curl loop line itself contains the words
        // `echo "server listening"`, so containsString fired on the
        // echo of the script ~1 s after serve launch, before the
        // server existed. The bare output line is the only true
        // signal. (The server is also proven independently by the
        // health probe through the vsock bridge.)
        if (!self.serverListening) {
            self.serverListening = YES;
            [self appendEngineLogSync:@"Server listening (from guest console)"];
            // The guest's curl probe already proved /api/info
            // answers, so start the health timer now and probe
            // at once — a fixed 5 s tick fired before the server
            // was ready and hung the full 30 s timeout (77b9a2f:
            // healthy at 41 s). startHealthTimer is idempotent
            // and fires the first probe immediately.
            if (self.state == OCEngineStateStarting) {
                [self startHealthTimer];
                [self appendEngineLogSync:@"Health probe starting (server listening in guest)"];
            }
        }
        return;
    }
    if ([clean isEqualToString:@"CLI READY"]) {
        // Exact match only. The script prints this once, when the
        // TUI process is confirmed alive (pgrep) — it is not the
        // echo of a loop line, and only the one-line `sh` command
        // is ever typed, so no typed line contains the marker.
        // Record a real one even if the server probe already
        // marked the engine running, so the log names a genuine
        // running TUI.
        if (!self.cliReady) {
            self.cliReady = YES;
            [self appendEngineLogSync:@"CLI ready (from guest console)"];
            // The diagnostics run right after the READY loop, so
            // fetch them through the server in 10 s: the console
            // drops them, the file API does not.
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [weakSelf fetchGuestDiagnosticsIfNeeded];
            });
        }
        if (!self.serveProgressDone) {
            self.serveProgressDone = YES;
            [self setServeProgress:1.0 status:@"Engine running"];
            if (self.state != OCEngineStateRunning) [self setState:OCEngineStateRunning];
        }
        return;
    }
    if ([clean hasPrefix:@"PROGRESS "]) {
        NSArray<NSString *> *parts = [clean componentsSeparatedByString:@" "];
        if (parts.count >= 3) {
            double pct = [parts[1] doubleValue] / 100.0;
            // Progress only moves forward: a stale PROGRESS 90 line
            // must not pull the bar back down.
            if (pct > self.serveProgressValue) {
                NSString *msg = [[parts subarrayWithRange:NSMakeRange(2, parts.count - 2)] componentsJoinedByString:@" "];
                [self setServeProgress:pct status:msg];
            }
        }
        return;
    }
    if ([clean hasPrefix:@"ERROR "]) {
        [self setServeProgress:self.serveProgressValue status:clean];
        return;
    }
}

// Guest console output arrives here from KernGlue (runtime thread).
// The text is appended to the guest console log, and complete lines
// are parsed for progress. The password never reaches this method:
// the bootstrap types it with echo off, and KernGlue redacts it.
- (void)handleGuestConsoleText:(NSString *)text {
    if (!text.length) return;
    NSString *copy = [text copy];
    __weak typeof(self) weakSelf = self;
    dispatch_async(OCEngineLogQueue(), ^{
        NSString *path = [[weakSelf engineDirectory] stringByAppendingPathComponent:@"guest.log"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        NSData *data = [copy dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [data writeToFile:path atomically:NO];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:data];
            unsigned long long size = [fh offsetInFile];
            [fh closeFile];
            // Same 512 KB cap as the engine log: a chatty guest
            // console must not grow this file forever.
            if (size > 512 * 1024) OCEngineCapLogFileToTail(path);
        }
        NSMutableString *partial = OCEngineConsolePartial();
        [partial appendString:copy];
        // The shell prompt has no trailing newline, so it sits in
        // the partial buffer until the next line arrives — it
        // never reaches handleGuestConsoleLine on its own. Detect
        // it here, on the raw text: the prompt string survives
        // ANSI codes (it appears literally, twice, in the raw
        // prompt bytes), so a plain containsString is enough.
        if ([partial containsString:@"termux@termx"]) {
            __weak typeof(self) weakPrompt = self;
            dispatch_async(dispatch_get_main_queue(), ^{
                typeof(self) promptSelf = weakPrompt;
                if (promptSelf) [promptSelf noteShellPromptSeen];
            });
        }
        while (YES) {
            NSRange nl = [partial rangeOfString:@"\n"];
            if (nl.location == NSNotFound) break;
            NSString *line = [[partial substringToIndex:nl.location] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            [partial deleteCharactersInRange:NSMakeRange(0, nl.location + 1)];
            if (!line.length) continue;
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            dispatch_async(dispatch_get_main_queue(), ^{ [strongSelf handleGuestConsoleLine:line]; });
        }
    });
}

#pragma mark - First-launch setup (guest image download)

+ (NSError *)setupErrorWithCode:(NSInteger)code message:(NSString *)message {
    return [NSError errorWithDomain:@"OCEngine" code:code
                         userInfo:@{NSLocalizedDescriptionKey: message ?: @"Setup failed"}];
}

- (BOOL)guestImageInstalled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kGuestImageInstalled];
}

- (void)runFirstLaunchSetupWithProgress:(void (^)(double, NSString *))progress
                             completion:(void (^)(BOOL, NSError * _Nullable))completion {
    // Coalesce concurrent setups: a second call while one is in
    // flight is a silent no-op — no error, no log failure, no
    // state change. The in-flight attempt owns the outcome, and
    // its own completion updates the state. (Before this, the
    // second call reached installGuestTo and its "install already
    // in progress" error flipped the state to Error, killing the
    // first download's state.)
    @synchronized (self) {
        if (self.setupInFlight) return;
        self.setupInFlight = YES;
    }
    // Setup is only the prebuilt guest image. It never touches the
    // guest core: guestExecutor is nil in a build without the runtime
    // framework, and is never called here.
    [self appendEngineLogSync:@"First-launch setup started (guest image download)"];
    [self setState:OCEngineStateInstalling];
    NSString *imagePath =
#ifdef OC_KERNARIUM_LINKED
        [[OCKernGlue shared] guestImagePath];
#else
        [[[self engineDirectory] stringByAppendingPathComponent:@"guest"]
            stringByAppendingPathComponent:kOCGuestImageName];
#endif
    __weak typeof(self) weakSelf = self;
    [OCGuestInstall installGuestTo:imagePath progress:progress completion:^(BOOL ok, NSString *error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        @synchronized (strongSelf) { strongSelf.setupInFlight = NO; }
        if (ok) {
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kGuestImageInstalled];
            // The new image is the current release: the update is
            // done, so clear the flag BEFORE the state flips to
            // Installed — the observer auto-starts from there, and
            // a still-set flag would hold the fresh install.
            self.updateAvailable = NO;
            [strongSelf appendEngineLogSync:@"First-launch setup done: guest image downloaded and verified"];
            [strongSelf setState:OCEngineStateInstalled];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(YES, nil); });
        } else {
            // Backstop: the installer's own in-flight guard can
            // still answer "install already in progress" if a
            // second install was started out of band. That is not
            // a failure of this attempt — the in-flight install
            // owns the state — so ignore it instead of flipping
            // to Error.
            if ([error isEqualToString:@"install already in progress"]) {
                [strongSelf appendEngineLogSync:@"First-launch setup: duplicate install ignored, the in-flight install continues"];
                return;
            }
            [strongSelf appendEngineLogSync:[NSString stringWithFormat:@"First-launch setup failed: %@", error ?: @"unknown"]];
            [strongSelf setState:OCEngineStateError];
            NSError *e = [OCEngine setupErrorWithCode:6 message:error ?: @"Setup failed"];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, e); });
        }
    }];
}

#pragma mark - Start / stop / health

- (void)startEngineWithCompletion:(void (^)(BOOL, NSError * _Nullable))completion {
    // A start is always automatic now (auto-start, the health
    // timer restarting a dead guest, or a mode switch): there is
    // no manual Start and no stop flag to clear any more.
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d boolForKey:kGuestImageInstalled]) {
        NSError *e = [NSError errorWithDomain:@"OCEngine" code:3
                                     userInfo:@{NSLocalizedDescriptionKey: @"First launch setup has not finished yet"}];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, e); });
        return;
    }
#ifdef OC_KERNARIUM_LINKED
    // Lazy runtime load: the framework is dlopen'd here, on the
    // first real start — never at app launch, so a framework that
    // dies while loading kills a Start tap, not the launch. The
    // crash recorder is already installed (main), and the result
    // is logged synchronously either way.
    if (!self.guestCoreLinked) {
        [self appendEngineLogSync:@"Loading Kernarium runtime..."];
        if (![[OCKernGlue shared] ensureRuntimeLoaded]) {
            [self setState:OCEngineStateCorePending];
            NSError *e = [NSError errorWithDomain:@"OCEngine" code:4
                                         userInfo:@{NSLocalizedDescriptionKey: @"The Kernarium runtime did not load. See the engine log for the exact reason."}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, e); });
            return;
        }
    }
#endif
    if (!self.guestCoreLinked) {
        // The guest core library is not linked in this build. The engine
        // cannot boot without it, and this method says so instead of
        // pretending the server is running.
        [self setState:OCEngineStateCorePending];
        NSError *e = [NSError errorWithDomain:@"OCEngine" code:4
                                     userInfo:@{NSLocalizedDescriptionKey: @"The engine is not ready yet in this build, so it cannot start."}];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, e); });
        return;
    }
#ifdef OC_KERNARIUM_LINKED
    // Core linked but the guest is not booted yet (first Start after a
    // relaunch): boot it first, then launch the server (and the terminal).
    // When the define is absent this block does not exist and
    // behaviour is unchanged.
    if (![OCKernGlue shared].booted) {
        [self setState:OCEngineStateStarting];
        [self setServeProgress:0.05 status:@"Starting…"];
        [self appendEngineLogSync:@"Guest boot started"];
        // A fresh boot means a fresh console: the shell prompt
        // sighting from any earlier boot is stale, so phase 1
        // waits for a new one (see startServeWithCompletion).
        self.shellPromptSeen = NO;
        __weak typeof(self) weakSelf = self;
        [[OCKernGlue shared] bootWithCompletion:^(BOOL ok, NSError * _Nullable error) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (!ok) {
                [strongSelf appendEngineLogSync:[NSString stringWithFormat:@"Guest boot failed: %@", error.localizedDescription ?: @"unknown"]];
                [strongSelf setState:OCEngineStateError];
                dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
                return;
            }
            [strongSelf appendEngineLogSync:@"Guest boot finished"];
            [strongSelf startServeWithCompletion:completion];
        }];
        return;
    }
#endif
    [self startServeWithCompletion:completion];
}

// The serve launch itself, factored out of startEngineWithCompletion
// so the boot-on-demand path above can reuse it.
- (void)startServeWithCompletion:(void (^)(BOOL, NSError * _Nullable))completion {
#ifdef OC_KERNARIUM_LINKED
    // Generation guard: if stopEngine runs while a start is in
    // flight (health-timer restart, mode-switch restart), a late
    // console line must not mark the engine Running again or
    // restart the health timer. stopEngine bumps the generation;
    // the console feed checks state, and a start from an older
    // generation is ignored.
    self.serveGeneration++;
    NSUInteger generation = self.serveGeneration;
    self.serveProgressDone = NO;
    self.cliReady = NO;
    self.serverListening = NO;
    self.guestDiagnosticsFetched = NO;
    self.lastGuestDiagnosticsText = nil;
    self.guestDiagnosticsFetchAttempts = 0;
    self.guestDiagnosticsRetryPending = NO;
    self.cliBootstrapSent = NO;
    self.healthProbeInFlight = NO;
    self.lastProbeOK = NO;
    self.serverProbeEverOK = NO;
    self.lastProbeError = nil;
    self.lastProbeLoggedError = nil;
    [self setState:OCEngineStateStarting];
    [self setServeProgress:0.05 status:@"Starting terminal..."];
    [self appendEngineLogSync:@"Serve launch started"];
    // The bootstrap string is built fresh in sendPhase1IfPending
    // (consoleBootstrap is deterministic: same password, same
    // commands), so there is no local to hold here.
    // The password is typed with echo off (see the bootstrap) and is
    // also the glue's redact string, so it never lands in a log.
    NSString *pw = [[OCSettings shared] ensureServerPassword];
    [OCKernGlue shared].consoleRedactString = pw;
    // Phase 1 goes only into a real shell, never into getty.
    // The boot gate fires on the getty "login: " prompt
    // (KernGlue), which is not a shell: the serial getty
    // auto-logs in as termux, and the shell prompt
    // ("termux@termx") follows ~1 s later. Typing the script
    // before that prompt eats it as login attempts (dceea4c:
    // dozens of "termx login:" prompts on the tty1 display,
    // ending at "Password:"). So the send waits for the shell
    // prompt (see noteShellPromptSeen); if the prompt was
    // already seen (a restart on a live guest), it goes after
    // 1 s as before. A 30 s watchdog gives up with a clear
    // error instead of typing into a login prompt or waiting
    // forever.
    [self setState:OCEngineStateStarting];
    [self setServeProgress:0.05 status:@"Starting terminal..."];
    // The guest still has to boot its userland and print the
    // ready marker; give the first start 5 minutes before health
    // failures can restart the engine.
    self.healthGraceUntil = [NSDate dateWithTimeIntervalSinceNow:300];
    // The health timer starts when the guest console reports
    // "server listening" (see handleGuestConsoleLine), NOT on
    // a fixed tick: a probe fired before the server is ready
    // hangs the full request timeout through the vsock bridge
    // instead of failing fast (77b9a2f: first probe at ~6 s,
    // server ready at ~8 s, healthy at 41 s). Fallback: if
    // the console marker never arrives (the console has
    // dropped output before), start the timer anyway 20 s
    // after serve launch so the engine cannot stall forever.
    __weak typeof(self) weakFallback = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) fallbackSelf = weakFallback;
        if (!fallbackSelf) return;
        if (generation != fallbackSelf.serveGeneration) return;
        if (fallbackSelf.state == OCEngineStateStopped) return;
        if (fallbackSelf.healthTimer) return;
        [fallbackSelf appendEngineLog:@"Health timer fallback: no server listening marker in 20 s"];
        [fallbackSelf startHealthTimer];
    });
    self.phase1Pending = YES;
    self.phase1Sent = NO;
    self.phase1Generation = generation;
    if (self.shellPromptSeen) {
        // Restart on a live guest: the shell is already there.
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf sendPhase1IfPending];
        });
    }
    // Fresh boot: the prompt has not been seen yet, so the send
    // waits for noteShellPromptSeen. The watchdog bounds the wait.
    __weak typeof(self) weakWatchdog = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) watchdogSelf = weakWatchdog;
        if (!watchdogSelf) return;
        if (generation != watchdogSelf.serveGeneration) return;
        if (!watchdogSelf.phase1Pending || watchdogSelf.phase1Sent) return;
        watchdogSelf.phase1Pending = NO;
        [watchdogSelf appendEngineLog:@"ERROR: no shell prompt on the guest console after 30 s — the guest is at a login prompt, so the bootstrap was not sent"];
    });
    dispatch_async(dispatch_get_main_queue(), ^{ completion(YES, nil); });
#else
    (void)completion;
    [self setState:OCEngineStateCorePending];
    NSError *e = [NSError errorWithDomain:@"OCEngine" code:4
                                 userInfo:@{NSLocalizedDescriptionKey: @"The engine is not ready yet in this build, so it cannot start."}];
    dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, e); });
#endif
}

// The guest console showed the autologin shell prompt
// ("termux@termx"). Called on the main queue, from the console
// text (the prompt has no trailing newline, so it is detected
// on the raw text, not on complete lines) and from complete
// console lines (the prompt prefixes every echoed command).
- (void)noteShellPromptSeen {
    if (!self.shellPromptSeen) {
        self.shellPromptSeen = YES;
        [self appendEngineLogSync:@"Shell prompt seen on the guest console"];
    }
    [self sendPhase1IfPending];
}

// Send phase 1 if it is still pending for this serve attempt.
// Idempotent: the 1 s timer, the prompt detection, and the
// watchdog can all reach it, but the script goes once.
- (void)sendPhase1IfPending {
    if (!self.phase1Pending || self.phase1Sent) return;
    if (self.phase1Generation != self.serveGeneration) return;
    self.phase1Sent = YES;
    self.phase1Pending = NO;
    [[OCKernGlue shared] sendConsoleText:[self consoleBootstrap]];
    [self appendEngineLogSync:@"Phase 1 sent (shell prompt seen)"];
}

// The console bootstrap: one block of shell typed at the autologin
// shell (serial console ttyS0) after the shell prompt
// ("termux@termx"). The boot gate fires on the getty "login: "
// prompt, which is not a shell — typing before the shell prompt
// eats the script as login attempts (dceea4c). See
// startServeWithCompletion. Node and OpenCode are baked into
// the guest image, so this only CHECKS them (a missing binary is an
// ERROR line, never a download: the overlay is wiped every boot, so
// a first-Start download would repeat on every launch). The same
// block starts the vsock proxies, the user's app.py (guarded on the
// file existing), and then the CLI terminal (phase 2, after the
// server is healthy).
//
// Password: typed with echo off (`stty -echo` first), so the tty
// never echoes it back into the console transcript the app logs.
// The password is 32 hex chars, so it cannot break the quoting.
- (NSString *)consoleBootstrap {
    NSString *pw = [[OCSettings shared] ensureServerPassword];
    NSString *quotedPw = [pw stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
    NSMutableString *b = [NSMutableString string];
    [b appendString:@"echo OC-BOOTSTRAP-START\n"];
    [b appendString:@"stty -echo\n"];
    [b appendFormat:@"export OPENCODE_SERVER_PASSWORD='%@'\n", quotedPw];
    [b appendString:@"stty echo\n"];
    [b appendString:@"echo \"PROGRESS 5 Checking Node...\"\n"];
    [b appendString:@"command -v node >/dev/null 2>&1 && echo \"PROGRESS 55 Node ready\" || echo \"ERROR Node missing from image\"\n"];
    [b appendString:@"command -v opencode >/dev/null 2>&1 && echo \"PROGRESS 85 OpenCode ready\" || echo \"ERROR OpenCode missing from image\"\n"];
    // Tools are baked in too; a missing one is logged, never apt-
    // installed at boot (it would vanish on the next reboot anyway).
    [b appendString:@"command -v git >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v rg >/dev/null 2>&1 && command -v gh >/dev/null 2>&1 && command -v bun >/dev/null 2>&1 && echo \"PROGRESS 89 Tools ready\" || echo \"ERROR A baked-in tool is missing (see above)\"\n"];
    // V8 JIT check removed (2026-11-26): it answered the
    // question and cost ~2-3 s before serve on every boot.
    // Two device runs proved JIT works in the guest
    // (default 308/284 ms vs forced-no-JIT 1448/1513 ms):
    // LiveContainer launches with a debugger attached, which
    // grants the whole app process executable memory, guest
    // included. No separate JIT enabler is needed for the
    // guest. (See KERNARIUM-BUILD.md.)
    // The vsock proxies: the systemd units are the normal path, but
    // a unit that did not start must not leave the server cut off.
    // A second socat that cannot bind just exits; the first one
    // keeps serving.
    [b appendString:@"command -v socat >/dev/null 2>&1 && (nohup socat VSOCK-LISTEN:4096,fork TCP:127.0.0.1:4096 >/tmp/vsock-4096.log 2>&1 &) ; command -v socat >/dev/null 2>&1 && (nohup socat VSOCK-LISTEN:8000,fork TCP:127.0.0.1:8000 >/tmp/vsock-8000.log 2>&1 &)\n"];
    // The user's own app in /root/Projects: start it detached
    // whenever the engine starts, so it is up without anyone
    // typing a command. The guest agent cannot start it itself:
    // it treats its shell as read-only and refuses state-changing
    // commands, and the server was never actually up (re-tested
    // 2026-11-20: curl to 127.0.0.1:8000 fails, server.log still
    // 0 bytes). Guarded on the file existing, so a missing
    // app.py changes nothing. Run detached with nohup so it
    // survives the bootstrap shell exiting, logging to
    // /root/Projects/server.log. A failure here never blocks the
    // engine start. NOTE: /root/Projects does not persist across
    // boots yet (see KERNARIUM-ENGINE.md, PERSISTENCE-TODO), so on
    // the first Kernarium build this is a no-op until the project
    // is restored at boot; the command is wired and logs which way
    // it went.
    [b appendString:@"if [ -f /root/Projects/app.py ]; then (cd /root/Projects && nohup python3 app.py > server.log 2>&1 &); echo \"app.py started\"; else echo \"no app.py in guest\"; fi\n"];
    // The server is the engine: it starts FIRST, backgrounded, and
    // the CLI TUI joins that same server on 4096 (its sessions
    // are the native UI's sessions). 5f307ff deleted this launch
    // with the CLI mode, so nothing listened on 4096 and Threads
    // could not load chats while the engine claimed to be running
    // (2026-11-25, c360a14 device test). Restored from the desktop
    // branch (9ccab19): the curl wait loop proves the server
    // answers in the guest before the CLI starts, and the
    // "server listening" echo keeps the marker in guest.log. The
    // password reaches curl only as $OPENCODE_SERVER_PASSWORD, so
    // the literal never lands in the console transcript.
    [b appendString:@"echo \"PROGRESS 90 Starting server...\"\n"];
    // The CLI TUI (and the mobile app pairing) find their server
    // through the service registration file
    // (~/.local/state/opencode/service.json): the client reads
    // the URL + password there and reuses a healthy server
    // instead of spawning its own sidecar. A plain `serve`
    // writes no registration, so a client spawns its own
    // sidecar on 49374 — the desktop did exactly that, and the
    // renderer's bootstrap fetch to that sidecar failed (the
    // e001c27 "Failed to fetch" error page). Running serve in
    // --service mode registers OUR server (already proven up by
    // the /api/info probe below) so the TUI adopts it. The
    // service password comes from the service config file, not
    // the environment, so the config is pre-written here with
    // the same Keychain password the native UI uses — otherwise
    // serve --service would generate a random one and lock
    // the native UI out. Hostname 127.0.0.1: every consumer
    // (vsock bridge, TUI, curl loop) reaches the server
    // on loopback, and the registered URL is then unambiguous
    // (a 0.0.0.0 bind would register an unusable URL).
    [b appendString:@"mkdir -p /home/termux/.config/opencode\n"];
    [b appendString:@"printf '{\"password\":\"%s\"}' \"$OPENCODE_SERVER_PASSWORD\" > /home/termux/.config/opencode/service.json\n"];
    [b appendString:@"chmod 600 /home/termux/.config/opencode/service.json\n"];
    [b appendString:@"nohup opencode serve --service --port 4096 --hostname 127.0.0.1 >/tmp/opencode-serve.log 2>&1 &\n"];
    [b appendString:@"for i in $(seq 1 60); do if curl -fsS -u \"opencode:$OPENCODE_SERVER_PASSWORD\" http://127.0.0.1:4096/api/info >/dev/null 2>&1; then echo \"server listening\"; break; fi; sleep 2; done\n"];
    [b appendString:@"ss -ltn 2>/dev/null | grep -q ':4096' && echo \"Server on 4096 confirmed\" || echo \"ERROR Server did not start (see /tmp/opencode-serve.log)\"\n"];
    // Phase 1 ends here: the server is up and the shell is about
    // to go idle (the curl loop broke on the answer). The CLI
    // section is a separate injection (cliBootstrap), sent
    // only after the host's /api/info probe first succeeds — the
    // health timer sends it. Typing the whole bootstrap at
    // once overflows the tty input buffer while the shell is
    // blocked in the curl loop, and the middle is dropped
    // (977334d: the shell never got past `systemctl stop`, the
    // desktop never started, no diagnostics file). Phase 1 is
    // ~2 KB, so even the curl loop's 6 s cannot overflow the
    // 4 KB buffer behind it.
    return b;
}

// The CLI bootstrap (phase 2): everything after the server
// is up. Sent only after the /api/info probe first succeeds, so
// the guest shell is idle at its prompt and consumes each line
// as it arrives. The TUI runs in the foreground of the console
// shell (see cliBootstrap): the only long foreground command in
// the script is the TUI itself, and the script's `wait` keeps
// the console shell there until the TUI exits.
// Phase 2 delivery: the CLI script goes to the guest as a
// file, not as typed console input. Typing a multi-KB script
// into the tty dropped bytes even into an idle shell (df597d2
// logs: the diag-snapshot heredoc opener was lost so the script
// was never written, the fbdev.conf heredoc was mangled, and the
// ai.opencode line was split mid-flag — `--disable-gpu` became
// `--disable-` plus a `gpu` command that exited 127, so the
// desktop never started). The server is already proven up by
// the /api/info probe, and its POST /api/experimental/fs/write
// endpoint writes raw bytes to an absolute path (the desktop
// app uploads attachments through it; the 2.3.0 server in the
// guest has it). Only one short line is ever typed:
// `sh /tmp/cli-bootstrap.sh`. The script's heredocs are
// read from the file by sh, not from the tty, so they cannot
// be split. If the write fails the old console typing is the
// fallback, so a surprise in the experimental endpoint leaves
// the CLI delayed rather than unlaunched.
- (void)deliverCliBootstrap {
    OCSettings *settings = [OCSettings shared];
    OCServerClient *client = [[OCServerClient alloc] initWithServerURL:settings.serverURL password:[settings serverPassword]];
    NSData *data = [[self cliBootstrap] dataUsingEncoding:NSUTF8StringEncoding];
    __weak typeof(self) weakSelf = self;
    [client writeFileAtPath:@"/tmp/cli-bootstrap.sh" content:data completion:^(NSString * _Nullable resolvedPath, NSError * _Nullable error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.state == OCEngineStateStopped) return;
        if (!error && resolvedPath.length) {
            [strongSelf appendEngineLog:@"CLI launch started"];
            [[OCKernGlue shared] sendConsoleText:@"sh /tmp/cli-bootstrap.sh"];
            // Start the diagnostics cadence now, not only when the
            // user opens the Terminal view: the snapshot file is
            // rewritten every 10 s, and the fetches name the TUI's
            // state as it starts (25bb172: the only fetch was the
            // too-early first snapshot, because nothing fetched
            // again).
            [strongSelf fetchGuestDiagnosticsIfNeeded];
            return;
        }
        [strongSelf appendEngineLog:[NSString stringWithFormat:@"CLI bootstrap write failed (%@), falling back to console", error ? error.localizedDescription : @"no path"]];
        [strongSelf appendEngineLog:@"CLI launch started"];
        [[OCKernGlue shared] sendConsoleText:[strongSelf cliBootstrap]];
        [strongSelf fetchGuestDiagnosticsIfNeeded];
    }];
}

- (NSString *)cliBootstrap {
    NSMutableString *b = [NSMutableString string];
    // The CLI session, started here instead of through the
    // opencode-desktop systemd service: the service is disabled
    // at boot (rootfs-build) and the desktop is gone (2026-11-26:
    // the user replaced it with the CLI TUI, which is lite). The
    // TUI runs on tty1 (see below), not on this script's tty:
    // this script runs in the autologin termux shell on the
    // serial console (ttyS0), which the user never sees, while
    // the Terminal view shows the framebuffer (tty1). No Xorg,
    // no openbox, no Electron: the whole desktop stack is
    // deleted from the bootstrap (it stays in git history and
    // in the image; the image slimming is a separate follow-up).
    // Leftovers are killed first so a restart is clean: a stale
    // diagnostics loop from a previous boot would keep writing
    // the previous boot's state over the new one.
    // No `systemctl stop opencode-desktop` here: the service is
    // disabled at boot (rootfs-build), so there is nothing to
    // stop — and on 977334d the shell never got past that line
    // (systemctl can block on D-Bus/systemd for up to 90 s),
    // so X never started and no diagnostics file was written.
    // The pkill line below already kills any stray processes.
    [b appendString:@"echo \"PROGRESS 95 Starting terminal...\"\n"];
    [b appendString:@"sudo pkill -f diag-loop.sh 2>/dev/null; true\n"];
    // Diagnostics that survive: the console drops output once
    // the TUI takes over (alternate screen), so the diagnostics
    // must not wait for the TUI. Write them as a script
    // (/tmp/diag-snapshot.sh), run it once now — the file exists
    // within ~20 s of serve start, so the server fetch finds
    // it — and re-run it every 10 s in the background so it
    // stays fresh. The file is the durable copy; the console
    // cannot carry it after the TUI starts.
    // The snapshot reports the server and the TUI, not Xorg:
    // pgrep names both processes, and the loop heartbeat names
    // whether the loop itself is alive. The serve log tail is
    // the server's own record of the TUI connecting.
    [b appendString:@"cat > /tmp/diag-snapshot.sh <<'EOF'\n"];
    [b appendString:@"#!/bin/sh\n"];
    [b appendString:@"{ echo \"--- cli diagnostics ---\"\n"];
    [b appendString:@"echo \"Active VT: $(cat /sys/class/tty/tty0/active 2>/dev/null || echo unknown)\"\n"];
    [b appendString:@"ps aux | grep -E \"opencode\" | grep -v grep\n"];
    [b appendString:@"echo \"DIAG server: $(pgrep -f 'opencode serve' >/dev/null 2>&1 && echo running || echo down)\"\n"];
    [b appendString:@"echo \"DIAG tui: $(pgrep -f '^opencode$' >/dev/null 2>&1 && echo running || echo down)\"\n"];
    [b appendString:@"echo \"DIAG serve log: $(tail -1 /tmp/opencode-serve.log 2>/dev/null | tr -cd '\\11\\40-\\176' | cut -c1-160)\"\n"];
    // Loop heartbeat: the 16f1cc2 fetches all returned the first
    // snapshot, so whether diag-loop.sh is alive or dead was
    // never visible. The next run's snapshot names it.
    [b appendString:@"echo \"DIAG loop: $(pgrep -f diag-loop.sh >/dev/null 2>&1 && echo running || echo DEAD)\"\n"];
    [b appendString:@"echo \"--- end cli diagnostics ---\"; } > /tmp/cli-diag.txt 2>&1\n"];
    // Absolute home path, not `~`: the loop runs this script as
    // root, so `~` expands to /root and the copy lands in
    // /root/cli-diag.txt while the server reads
    // /home/termux/cli-diag.txt — that is why every 16f1cc2
    // fetch returned the first snapshot. chmod so the termux
    // server can read the root-written copy.
    [b appendString:@"cp /tmp/cli-diag.txt /home/termux/cli-diag.txt 2>/dev/null; chmod 644 /home/termux/cli-diag.txt 2>/dev/null; cp /tmp/cli-diag.txt /root/Projects/cli-diag.txt 2>/dev/null; true\n"];
    [b appendString:@"EOF\n"];
    [b appendString:@"chmod +x /tmp/diag-snapshot.sh\n"];
    [b appendString:@"sh /tmp/diag-snapshot.sh\n"];
    [b appendString:@"cat > /tmp/diag-loop.sh <<'EOF'\n"];
    [b appendString:@"#!/bin/sh\n"];
    [b appendString:@"while true; do\n"];
    [b appendString:@"  sh /tmp/diag-snapshot.sh\n"];
    [b appendString:@"  sleep 10\n"];
    [b appendString:@"done\n"];
    [b appendString:@"EOF\n"];
    [b appendString:@"chmod +x /tmp/diag-loop.sh\n"];
    [b appendString:@"sudo nohup sh /tmp/diag-loop.sh >/tmp/diag-loop.log 2>&1 &\n"];
    // The TUI runs on tty1, the framebuffer VT the Terminal view
    // shows — NOT on this script's tty (the serial console ttyS0).
    // Two terminals, and dceea4c confused them: the autologin
    // shell (and this script) run on ttyS0, which the user never
    // sees, while the Terminal view shows tty1, whose getty has
    // no autologin and sits at "termx login:". A TUI started here
    // draws on ttyS0 (invisible) and reads the serial console,
    // not the user's keyboard (which feeds tty1). So the TUI is
    // moved to tty1: stop its getty, size it from the
    // framebuffer, and run the TUI as a session leader with tty1
    // as its controlling terminal, so the Terminal view shows it
    // and the keyboard reaches it. TERM is linux on the virtual
    // console (not the xterm-256color the serial autologin sets).
    // Stop getty first: it owns tty1, and a TUI that shares the
    // VT with a live getty fights it for input. Bounded with
    // timeout — a systemctl that hangs on D-Bus (977334d) must
    // not stall the script. Restart it when the TUI exits, so
    // the user gets a login prompt back instead of a blank VT.
    [b appendString:@"timeout 15 sudo systemctl stop getty@tty1 2>/dev/null || echo \"WARN getty@tty1 did not stop\"\n"];
    // A stale TUI from a restart would fight the new one for
    // tty1. The serve ("opencode serve ...") does not match
    // the exact-name pattern, so it is left alone.
    [b appendString:@"sudo pkill -f '^opencode$' 2>/dev/null; true\n"];
    // Terminal size: tty1 is the 1290x2796 framebuffer with the
    // kernel's 8x16 font, so it reports 161 cols x 174 rows.
    // Make the size explicit and export it so the TUI lays out
    // for the full screen. If the kernel ever reports something
    // narrow, fall back to the framebuffer-derived size instead
    // of handing the TUI a narrow terminal.
    [b appendString:@"SZ=$(stty size < /dev/tty1 2>/dev/null || echo \"174 161\"); set -- $SZ; TR=$1; TC=$2; [ \"$TC\" -lt 100 ] && { TR=174; TC=161; }; stty rows $TR cols $TC < /dev/tty1 2>/dev/null; export COLUMNS=$TC LINES=$TR; echo \"Terminal size: ${TR} rows x ${TC} cols (tty1)\"\n"];
    [b appendString:@"export TERM=linux\n"];
    // The TUI's project directory: the autologin shell starts in
    // /home/termux, and the server's default project is there
    // too, so the TUI opens on the same sessions the native UI
    // and the mobile app see. cd explicitly so a stray cwd from
    // a restart cannot change it.
    [b appendString:@"cd /home/termux\n"];
    // The CLI TUI, on tty1 (see above): `opencode` with no args
    // runs the default command, which resolves its server
    // through Service.discover — it finds our serve's
    // registration (URL http://127.0.0.1:4096 + password from
    // service.json, written by phase 1) and connects to it, and
    // only spawns its own server when no healthy registration
    // exists (packages/cli/src/commands/handlers/default.ts:35,
    // packages/cli/src/services/server-connection.ts:51-60).
    // Same mechanism as the desktop's ensure (77b9a2f), same
    // registration — the TUI adopts our server, no second
    // server. It runs in the background of this script so the
    // script can confirm the process is alive and print the
    // CLI READY marker the app watches for. The poll loop below
    // keeps the script — and the console shell — in the
    // foreground until the TUI exits.
    // setsid makes the TUI a session leader with tty1 as its
    // controlling terminal (the --ctty terminal is stdin,
    // redirected from /dev/tty1), so the Terminal view's
    // keyboard — which feeds tty1 — reaches it and Ctrl-C works.
    // Fall back to a plain redirect if setsid fails (the TUI
    // still reads and draws on tty1 through stdio; only job
    // control is weaker). The first pgrep loop waits the full
    // 10 s before the fallback, so a slow-starting TUI is not
    // doubled.
    [b appendString:@"setsid -c opencode </dev/tty1 >/dev/tty1 2>&1 &\n"];
    [b appendString:@"for i in $(seq 1 10); do pgrep -f '^opencode$' >/dev/null 2>&1 && break; sleep 1; done\n"];
    [b appendString:@"if ! pgrep -f '^opencode$' >/dev/null 2>&1; then echo \"WARN setsid TUI did not start, retrying without setsid\"; opencode </dev/tty1 >/dev/tty1 2>&1 & for i in $(seq 1 10); do pgrep -f '^opencode$' >/dev/null 2>&1 && break; sleep 1; done; fi\n"];
    [b appendString:@"if pgrep -f '^opencode$' >/dev/null 2>&1; then echo \"CLI READY\"; else echo \"ERROR CLI did not start\"; fi\n"];
    // Wait for the TUI to exit by polling, not `wait $!`:
    // setsid may fork, so $! is not reliably the TUI's PID.
    // The poll keeps the script — and the console shell — in
    // the foreground until the TUI exits.
    [b appendString:@"while pgrep -f '^opencode$' >/dev/null 2>&1; do sleep 5; done; echo \"CLI exited\"\n"];
    [b appendString:@"sudo systemctl start getty@tty1 2>/dev/null || true\n"];
    return b;
}

- (void)stopEngine {
    [self.healthTimer invalidate];
    self.healthTimer = nil;
    // A stop means a start is being driven explicitly (health
    // restart): cancel any pending automatic retry.
    [self.autoStartRetryTimer invalidate];
    self.autoStartRetryTimer = nil;
    // Bump the serve generation so a start already in flight cannot
    // mark the engine Running again after this stop.
    self.serveGeneration++;
    self.serveProgressDone = NO;
    self.cliReady = NO;
    self.serverListening = NO;
    self.guestDiagnosticsFetched = NO;
    self.lastGuestDiagnosticsText = nil;
    self.guestDiagnosticsFetchAttempts = 0;
    self.guestDiagnosticsRetryPending = NO;
    self.cliBootstrapSent = NO;
    self.healthProbeInFlight = NO;
    self.lastProbeOK = NO;
    self.serverProbeEverOK = NO;
    self.lastProbeError = nil;
    self.lastProbeLoggedError = nil;
    [self setServeProgress:0 status:nil];
#ifdef OC_KERNARIUM_LINKED
    [[OCKernGlue shared] stopGuest];
#endif
    [self appendEngineLog:@"Engine stopped"];
    [self setState:OCEngineStateStopped];
}

- (void)startHealthTimer {
    // Idempotent: the "server listening" marker and the 20 s
    // fallback both call this; only the first one starts the
    // timer. The first probe fires at once ([timer fire]),
    // not on the next 5 s tick — the marker already proves
    // the server answers /api/info in the guest, so the first
    // probe should succeed in under a second and the engine
    // goes healthy ~6 s after serve launch, as in the
    // pre-77b9a2f runs.
    if (self.healthTimer) return;
    self.healthFailures = 0;
    __weak typeof(self) weakSelf = self;
    self.healthTimer = [NSTimer scheduledTimerWithTimeInterval:5.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) { [timer invalidate]; return; }
        [strongSelf checkHealthWithCompletion:^(BOOL healthy, NSDictionary * _Nullable info) {
            (void)info;
            if (healthy) {
                strongSelf.healthFailures = 0;
                // The server is up: a later failure gets a fresh
                // automatic retry (the once-per-launch timer).
                strongSelf.autoStartRetryUsed = NO;
                if (!strongSelf.serveProgressDone) {
                    strongSelf.serveProgressDone = YES;
                    [strongSelf setServeProgress:1.0 status:@"Engine running"];
                    [strongSelf appendEngineLog:@"Server healthy at 127.0.0.1:4096"];
                    // Phase 2 of the bootstrap: the CLI section
                    // goes now, not with the serve launch — and not
                    // as typed console input. Typing the ~4.5 KB
                    // script dropped bytes even into a ready shell
                    // (df597d2: the diag-snapshot heredoc opener
                    // was lost so the script was never written, the
                    // fbdev.conf heredoc was mangled, and the
                    // ai.opencode line split mid-flag so `gpu`
                    // exited 127 and the desktop never started).
                    // The server answering means it can receive
                    // the script as a file, so deliverCli-
                    // Bootstrap writes it through the server's
                    // file API and types only the one-line `sh`
                    // command. 2 s later, so the curl loop has
                    // finished breaking.
                    if (!strongSelf.cliBootstrapSent) {
                        strongSelf.cliBootstrapSent = YES;
                        __weak OCEngine *weakEngine = strongSelf;
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            OCEngine *engine = weakEngine;
                            if (!engine) return;
                            if (engine.state == OCEngineStateStopped) return;
                            [engine deliverCliBootstrap];
                        });
                    }
                    // Running now means the server answers, not the
                    // CLI marker: the marker is a console line
                    // and the console drops post-TUI output, so the
                    // state must not wait on it — otherwise the
                    // startup screen never presents the tabs
                    // (maybePresentTabs gates on Running) and the
                    // user is stuck on "Starting…".
                    if (strongSelf.state != OCEngineStateRunning) [strongSelf setState:OCEngineStateRunning];
                }
                return;
            }
            // First start can still be booting; ignore failures
            // until the grace period ends.
            if (strongSelf.healthGraceUntil && [[NSDate date] compare:strongSelf.healthGraceUntil] == NSOrderedAscending) return;
            strongSelf.healthFailures++;
            if (strongSelf.healthFailures >= 3) {
                // Guest died (iOS suspended or killed the app).
                // Files do not persist in this engine (see
                // PERSISTENCE-TODO), processes do not: mark stopped
                // and try to restart the server.
                [strongSelf stopEngine];
                [strongSelf startEngineWithCompletion:^(BOOL started, NSError * _Nullable error) { (void)started; (void)error; }];
            }
        }];
    }];
    [self.healthTimer fire];
}

- (void)checkHealthWithCompletion:(void (^)(BOOL, NSDictionary * _Nullable))completion {
    // Healthy means the guest is up AND the server answers /api/info
    // through the same vsock bridge the native UI uses. The
    // The cliReady flag is deliberately NOT a gate here: it is a
    // console marker, and the console proved unreliable twice — the
    // echo of the typed READY loop fired the old DESKTOP READY 1 s
    // after serve launch (containsString), and the post-TUI console
    // output that would carry a real READY is dropped (the console
    // drops output once the TUI takes over). Gating health on it
    // would restart the engine every 5 minutes whenever the console
    // drops the marker. The server probe is the honest health
    // signal; the terminal view is available as a tab regardless,
    // and a real CLI READY still lands in the engine log when it
    // arrives.
    // The probe is one small HTTP request; at most one is in flight,
    // and while one runs the last result answers, so a slow probe
    // cannot pile up on the 5 s health timer. Probe failures log on
    // transition only.
#ifdef OC_KERNARIUM_LINKED
    if (![[OCKernGlue shared] booted]) { completion(NO, nil); return; }
    if (self.healthProbeInFlight) { completion(self.lastProbeOK, nil); return; }
    self.healthProbeInFlight = YES;
    OCSettings *settings = [OCSettings shared];
    OCServerClient *client = [[OCServerClient alloc] initWithServerURL:settings.serverURL password:[settings serverPassword]];
    __weak typeof(self) weakSelf = self;
    [client healthCheckWithCompletion:^(BOOL ok, NSDictionary * _Nullable info, NSError * _Nullable error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) { completion(NO, nil); return; }
        strongSelf.healthProbeInFlight = NO;
        strongSelf.lastProbeOK = ok;
        if (ok) {
            if (!strongSelf.serverProbeEverOK) {
                strongSelf.serverProbeEverOK = YES;
                [strongSelf appendEngineLog:@"Server probe: /api/info 200 (native UI path works)"];
            } else if (strongSelf.lastProbeLoggedError) {
                [strongSelf appendEngineLog:@"Server probe: /api/info 200 again"];
            }
            strongSelf.lastProbeError = nil;
            strongSelf.lastProbeLoggedError = nil;
        } else {
            NSString *detail = error.localizedDescription ?: @"unknown error";
            strongSelf.lastProbeError = detail;
            if (![detail isEqualToString:strongSelf.lastProbeLoggedError ?: @""]) {
                strongSelf.lastProbeLoggedError = detail;
                [strongSelf appendEngineLog:[NSString stringWithFormat:@"Server probe failed: %@", detail]];
            }
        }
        completion(ok, info);
    }];
#else
    completion(NO, nil);
#endif
}

// Guest diagnostics through the server's file API, not the
// console: the console drops post-TUI output, so the diagnostics
// file the bootstrap writes (and copies to ~/cli-diag.txt) is read
// over HTTP through the vsock bridge instead — the same channel
// the /api/info probe proves every run. The diagnostics file is
// written ~20 s after serve starts (diag-snapshot.sh runs before
// the TUI starts, diag-loop.sh refreshes it every 10 s), so the
// first fetch usually misses: a miss schedules a retry in 10 s,
// up to 12 attempts (~2 min). Every miss is logged with its
// attempt number, so the engine log shows the retry history
// instead of one silent miss (977334d: the fetch missed once at
// 15:30:21 and the later opens retried silently while the file
// was never written, because the desktop script had never run).
- (void)fetchGuestDiagnosticsIfNeeded {
    // Repeated, not once per boot: the guest rewrites
    // /tmp/cli-diag.txt every 10 s, and the first fetch
    // usually lands before the TUI starts (25bb172: the only
    // fetched block was the too-early first snapshot). Stop
    // only at the attempt cap (12 x 10 s ~= 2 min) or when the
    // engine stops. One fetch or retry pending at a time, so
    // viewDidAppear, the post-CLI trigger and the
    // deliverCliBootstrap call below all funnel into one
    // cadence instead of stacking timers.
    if (self.guestDiagnosticsFetchAttempts >= 12) return;
    if (self.guestDiagnosticsRetryPending) return;
    if (self.state == OCEngineStateStopped) return;
    self.guestDiagnosticsFetchAttempts++;
    NSUInteger attempt = self.guestDiagnosticsFetchAttempts;
    OCSettings *settings = [OCSettings shared];
    OCServerClient *client = [[OCServerClient alloc] initWithServerURL:settings.serverURL password:[settings serverPassword]];
    __weak typeof(self) weakSelf = self;
    [client readFileAtPath:@"cli-diag.txt" completion:^(NSString * _Nullable text, NSError * _Nullable error) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (text.length) {
            strongSelf.guestDiagnosticsFetched = YES;
            // Log only when the block changed: the state moves as
            // the TUI starts, so the log gets the
            // transitions (early / TUI up / TUI down / ready)
            // instead of twelve copies of the same block.
            if (![text isEqualToString:strongSelf.lastGuestDiagnosticsText]) {
                strongSelf.lastGuestDiagnosticsText = text;
                [strongSelf appendEngineLog:[NSString stringWithFormat:@"Guest diagnostics (via server) [fetch %lu]:\n%@", (unsigned long)attempt, text]];
            }
        } else {
            [strongSelf appendEngineLog:[NSString stringWithFormat:@"Guest diagnostics not available via server yet (attempt %lu/12: %@)", (unsigned long)attempt, error ? error.localizedDescription : @"no file"]];
        }
        // Re-fetch in 10 s whether this one hit or missed: a hit
        // is a snapshot, not the final state, and the next one is
        // the one that names the TUI's fate.
        if (attempt < 12 && !strongSelf.guestDiagnosticsRetryPending) {
            strongSelf.guestDiagnosticsRetryPending = YES;
            __weak typeof(self) weakRetry = strongSelf;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                typeof(self) retrySelf = weakRetry;
                if (!retrySelf) return;
                retrySelf.guestDiagnosticsRetryPending = NO;
                if (retrySelf.state == OCEngineStateStopped) return;
                [retrySelf fetchGuestDiagnosticsIfNeeded];
            });
        }
    }];
}

@end
