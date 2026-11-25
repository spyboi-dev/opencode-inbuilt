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
// YES once the desktop app reported ready.
@property (nonatomic, assign) BOOL desktopReady;
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
// queue — never the main thread, it can hash 4.46 GB. It sets
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
        // answers with no 4.46 GB hash at all — equal means
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
            // release, not a reason to hash 4.46 GB every launch.
            // (TermX records only on success; with a 4.46 GB
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
// 1.16 GB download does not restart on its own). A skip that
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
// display activity log can hold a line a second while the desktop
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
        ([guest containsString:@"server listening"] || [guest containsString:@"DESKTOP READY"])) {
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
// color codes, so a bare marker line like "DESKTOP READY" arrives
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
    if ([clean hasPrefix:@"DIAG "]) {
        // The bootstrap's compact desktop summary: it belongs in
        // the engine log too, so the pasted log names the VT, the
        // mapped window and the Xorg/app failures without needing
        // the whole guest console. The full block stays in guest.log.
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
        }
        return;
    }
    if ([clean isEqualToString:@"DESKTOP READY"]) {
        // Exact match only. The typed READY loop line itself
        // contains `echo "DESKTOP READY"`, so containsString fired
        // on the echo of the script 1-2 s after "Serve launch
        // started" in every run from c360a14 through 873e1ee,
        // before X or Electron existed — the engine claimed
        // "Desktop ready" and "Engine running" while the screen
        // was still black, and the 873e1ee "window mapped on :0"
        // conclusion was void: no bare DESKTOP READY line ever
        // reached the log. Record a real one even if the server
        // probe already marked the engine running, so the log
        // names a genuine mapped window.
        if (!self.desktopReady) {
            self.desktopReady = YES;
            [self appendEngineLogSync:@"Desktop ready (from guest console)"];
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
    // relaunch): boot it first, then launch the server (or desktop).
    // When the define is absent this block does not exist and
    // behaviour is unchanged.
    if (![OCKernGlue shared].booted) {
        [self setState:OCEngineStateStarting];
        [self setServeProgress:0.05 status:@"Starting…"];
        [self appendEngineLogSync:@"Guest boot started"];
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
    self.desktopReady = NO;
    self.serverListening = NO;
    self.healthProbeInFlight = NO;
    self.lastProbeOK = NO;
    self.serverProbeEverOK = NO;
    self.lastProbeError = nil;
    self.lastProbeLoggedError = nil;
    [self setState:OCEngineStateStarting];
    [self setServeProgress:0.05 status:@"Starting desktop..."];
    [self appendEngineLogSync:@"Serve launch started"];
    NSString *bootstrap = [self consoleBootstrap];
    // The password is typed with echo off (see the bootstrap) and is
    // also the glue's redact string, so it never lands in a log.
    NSString *pw = [[OCSettings shared] ensureServerPassword];
    [OCKernGlue shared].consoleRedactString = pw;
    // The login prompt means systemd is up, but the shell needs a
    // moment before the first typed line lands.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (generation != strongSelf.serveGeneration) {
            [strongSelf appendEngineLog:@"Serve launch ignored: engine was stopped while starting"];
            return;
        }
        [[OCKernGlue shared] sendConsoleText:bootstrap];
        [strongSelf setState:OCEngineStateStarting];
        [strongSelf setServeProgress:0.05 status:@"Starting desktop..."];
        // The guest still has to boot its userland and print the
        // ready marker; give the first start 5 minutes before health
        // failures can restart the engine.
        strongSelf.healthGraceUntil = [NSDate dateWithTimeIntervalSinceNow:300];
        [strongSelf startHealthTimer];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(YES, nil); });
    });
#else
    (void)completion;
    [self setState:OCEngineStateCorePending];
    NSError *e = [NSError errorWithDomain:@"OCEngine" code:4
                                 userInfo:@{NSLocalizedDescriptionKey: @"The engine is not ready yet in this build, so it cannot start."}];
    dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, e); });
#endif
}

// The console bootstrap: one block of shell typed at the autologin
// shell after the `login: ` prompt. Node and OpenCode are baked into
// the guest image, so this only CHECKS them (a missing binary is an
// ERROR line, never a download: the overlay is wiped every boot, so
// a first-Start download would repeat on every launch). The same
// block starts the vsock proxies, the user's app.py (guarded on the
// file existing), and then the desktop app.
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
    // the desktop app joins that same server on 4096 (its sessions
    // are the native UI's sessions). 5f307ff deleted this launch
    // with the CLI mode, so nothing listened on 4096 and Threads
    // could not load chats while the engine claimed to be running
    // (2026-11-25, c360a14 device test). Restored from the desktop
    // branch (9ccab19): the curl wait loop proves the server
    // answers in the guest before the desktop starts, and the
    // "server listening" echo keeps the marker in guest.log. The
    // password reaches curl only as $OPENCODE_SERVER_PASSWORD, so
    // the literal never lands in the console transcript.
    [b appendString:@"echo \"PROGRESS 90 Starting server...\"\n"];
    [b appendString:@"nohup opencode serve --port 4096 --hostname 0.0.0.0 >/tmp/opencode-serve.log 2>&1 &\n"];
    [b appendString:@"for i in $(seq 1 60); do if curl -fsS -u \"opencode:$OPENCODE_SERVER_PASSWORD\" http://127.0.0.1:4096/api/info >/dev/null 2>&1; then echo \"server listening\"; break; fi; sleep 2; done\n"];
    [b appendString:@"ss -ltn 2>/dev/null | grep -q ':4096' && echo \"Server on 4096 confirmed\" || echo \"ERROR Server did not start (see /tmp/opencode-serve.log)\"\n"];
    // The desktop session, started here instead of through the
    // opencode-desktop systemd service: the service's session
    // script runs `Xorg :0` with no VT argument, so X takes a
    // free VT (tty2) and the display stays on tty1's text console
    // — the black Desktop view on c360a14, with the tty1 login
    // prompt still visible at the top edge. The session script is
    // baked into the read-only rootfs, and chvt is not installed,
    // so the display cannot be switched after the fact: X must
    // start on the VT the display is already on (vt01). The
    // bootstrap shell is the autologin termux shell with
    // passwordless sudo, so Xorg runs via sudo as root and openbox
    // + the app run as termux, exactly as the service did.
    // Leftovers are killed first so a restart is clean.
    // fbdev, not modesetting/virgl: the 873e1ee display log
    // (Engine/display-activity.log) has ONLY 2D CPU flushes of
    // resource 2 — the virtio-gpu console framebuffer, 1290x2796
    // — repeated ~5/s through 37 s, and NO virgl/GPU scanout
    // ever. X's modesetting driver never produces a scanout the
    // runtime presents, so the desktop can never show through
    // the GPU path. fbdev draws straight into /dev/fb0, which
    // IS the presented framebuffer (fb0: virtio_gpudrmfb, and
    // the runtime already flushes it on the CPU path), so the
    // desktop rides the path that is proven to reach the screen.
    // The config is written to /tmp (writable overlay) and
    // passed with -configdir; Xorg runs as root, so an absolute
    // configdir path is allowed. Electron is forced to software
    // rendering (--disable-gpu): with X on fbdev there is no
    // DRI, so the GPU process would only spin up and fall back
    // anyway — make it deterministic from the start.
    [b appendString:@"echo \"PROGRESS 95 Starting desktop...\"\n"];
    [b appendString:@"sudo systemctl stop opencode-desktop 2>/dev/null; true\n"];
    [b appendString:@"sudo pkill -f ai.opencode 2>/dev/null; true\n"];
    [b appendString:@"sudo pkill -x Xorg 2>/dev/null; true\n"];
    // Wait for the old Xorg to actually die, then clear its lock
    // and socket. A fixed `sleep 1` was a race on engine restart:
    // a still-dying Xorg leaves /tmp/.X0-lock behind, the new Xorg
    // fails with "Server is already active for display 0", and the
    // socket wait below breaks at once on the STALE socket — so
    // openbox and the app start against a dead server and the
    // desktop stays black with no reason in the log. Removing the
    // lock/socket first means the wait loop only breaks on a fresh
    // X server.
    [b appendString:@"for _ in $(seq 1 10); do pgrep -x Xorg >/dev/null 2>&1 || break; sleep 1; done\n"];
    [b appendString:@"rm -f /tmp/.X0-lock /tmp/.X11-unix/X0\n"];
    [b appendString:@"sudo mkdir -p /run/user/1000; sudo chown termux:termux /run/user/1000 2>/dev/null; true\n"];
    [b appendString:@"export DISPLAY=:0; export XDG_RUNTIME_DIR=/run/user/1000\n"];
    // Force X onto fbdev (see the comment above): the config lives
    // in /tmp so no root write is needed to create it, and Xorg
    // (root, via sudo) takes the absolute -configdir path.
    [b appendString:@"mkdir -p /tmp/xorg.conf.d\n"];
    [b appendString:@"cat > /tmp/xorg.conf.d/10-fbdev.conf <<'EOF'\n"];
    [b appendString:@"Section \"Device\"\n"];
    [b appendString:@"    Identifier \"Card0\"\n"];
    [b appendString:@"    Driver \"fbdev\"\n"];
    [b appendString:@"    Option \"fbdev\" \"/dev/fb0\"\n"];
    [b appendString:@"EndSection\n"];
    [b appendString:@"Section \"Screen\"\n"];
    [b appendString:@"    Identifier \"Screen0\"\n"];
    [b appendString:@"    Device \"Card0\"\n"];
    [b appendString:@"EndSection\n"];
    [b appendString:@"Section \"ServerLayout\"\n"];
    [b appendString:@"    Identifier \"Layout0\"\n"];
    [b appendString:@"    Screen \"Screen0\"\n"];
    [b appendString:@"EndSection\n"];
    [b appendString:@"EOF\n"];
    [b appendString:@"sudo nohup Xorg :0 -ac -noreset -nolisten tcp vt01 -configdir /tmp/xorg.conf.d >/tmp/Xorg.log 2>&1 &\n"];
    [b appendString:@"for _ in $(seq 1 30); do [ -S /tmp/.X11-unix/X0 ] && break; sleep 1; done\n"];
    // If the socket never appeared, say why: Xorg's own log goes
    // to /var/log/Xorg.0.log, but a failure before it opens that
    // file lands only in /tmp/Xorg.log (the stderr redirect).
    // Without this the desktop just stays black and the READY
    // loop's ERROR line names no cause.
    [b appendString:@"[ -S /tmp/.X11-unix/X0 ] || { echo \"ERROR Xorg did not start\"; tail -20 /tmp/Xorg.log 2>/dev/null; }\n"];
    [b appendString:@"nohup openbox --sm-disable >/tmp/openbox.log 2>&1 &\n"];
    [b appendString:@"nohup env DISPLAY=:0 XDG_RUNTIME_DIR=/run/user/1000 HOME=/home/termux /opt/OpenCode/ai.opencode --no-sandbox --disable-dev-shm-usage --disable-gpu >/tmp/ai-opencode.log 2>&1 &\n"];
    // The real app binary is /opt/OpenCode/ai.opencode; the old
    // pgrep pattern (opencode-desktop) matched the session script
    // itself. Gate on the app process, and on the window actually
    // being mapped on :0: the process + socket gate fired while
    // the screen was still black, because a running Electron
    // process with no mapped window draws nothing. xwininfo
    // -root -tree lists the root's children as lines starting
    // with a window id; zero such lines means nothing is mapped.
    // If the process is up but no window ever maps, say so and
    // do not claim ready. NOTE: the "DESKTOP READY" the engine
    // logged 1 s after serve launch in every run was the ECHO of
    // this loop line, not its output — the parser matched the
    // words inside the typed command. The parser now requires a
    // bare line, so only the loop's own echo (below) counts.
    [b appendString:@"for i in $(seq 1 60); do if pgrep -f ai.opencode >/dev/null 2>&1 && [ -S /tmp/.X11-unix/X0 ] && [ $(DISPLAY=:0 xwininfo -root -tree 2>/dev/null | grep -c '^ *0x') -gt 0 ]; then echo \"DESKTOP READY\"; break; fi; sleep 2; done\n"];
    [b appendString:@"pgrep -f ai.opencode >/dev/null 2>&1 || echo \"ERROR Desktop did not start (see above)\"\n"];
    [b appendString:@"pgrep -f ai.opencode >/dev/null 2>&1 && [ $(DISPLAY=:0 xwininfo -root -tree 2>/dev/null | grep -c '^ *0x') -eq 0 ] && echo \"ERROR Desktop window did not appear (ai.opencode is running but no window is mapped on :0)\"\n"];
    // Diagnostics for the next device log: prove the window is
    // mapped on the display the framebuffer shows, and which VT
    // is active. xwininfo is in the image; chvt is not, which is
    // why X starts on vt01 above instead of being switched.
    // The block runs inside a brace group redirected to
    // /tmp/desktop-diag.txt, then sleeps 5 s and cats the file
    // back to the console. Two reasons. First, on 873e1ee the
    // diagnostics' executed output never reached guest.log or the
    // engine log at all, even though the script ran to completion
    // (the prompt returned): the console channel drops lines
    // under the load of X + Electron starting (the runtime's own
    // note: the console "loses lines under load"). Emitting the
    // block after the burst has settled gives it a far better
    // chance of arriving. Second, the file is the durable copy:
    // if the re-emit still does not arrive, the next step is to
    // fetch it through the vsock bridge instead of the console.
    // The DIAG app-log line strips every non-printable byte
    // (tr -cd tab + printable ASCII): Electron's log can carry
    // binary bytes, and one bad byte poisons the whole console
    // chunk the app's UTF-8 decode reads, dropping the
    // DESKTOP READY and DIAG lines with it. Compact summary, one
    // line each with a DIAG prefix: the console handler copies
    // these into the engine log, so the pasted log names the VT,
    // the mapped window and the Xorg/app failures without needing
    // the whole guest console.
    [b appendString:@"{ echo \"--- desktop diagnostics ---\"\n"];
    [b appendString:@"echo \"Active VT: $(cat /sys/class/tty/tty0/active 2>/dev/null || echo unknown)\"\n"];
    [b appendString:@"ps aux | grep -E \"Xorg|ai.opencode|openbox\" | grep -v grep\n"];
    [b appendString:@"DISPLAY=:0 xwininfo -root -tree 2>&1 | head -20\n"];
    [b appendString:@"grep -F \"(EE)\" /var/log/Xorg.0.log 2>/dev/null | tail -5; true\n"];
    // The (EE) grep above misses a failure before Xorg opens its
    // own log file; that reason is only in the stderr redirect.
    // The app log tail shows whether Electron even got going.
    [b appendString:@"echo \"Xorg log:\"; tail -20 /tmp/Xorg.log 2>/dev/null; echo \"Desktop app log:\"; tail -10 /tmp/ai-opencode.log 2>/dev/null; true\n"];
    [b appendString:@"echo \"DIAG Active VT: $(cat /sys/class/tty/tty0/active 2>/dev/null || echo unknown)\"\n"];
    [b appendString:@"echo \"DIAG Windows on :0: $(DISPLAY=:0 xwininfo -root -tree 2>/dev/null | grep -c '^ *0x')\"\n"];
    [b appendString:@"echo \"DIAG Xorg errors: $(grep -c -F '(EE)' /var/log/Xorg.0.log 2>/dev/null; true)\"\n"];
    [b appendString:@"echo \"DIAG app log: $(tail -1 /tmp/ai-opencode.log 2>/dev/null | tr -cd '\\11\\40-\\176' | cut -c1-160)\"\n"];
    [b appendString:@"echo \"--- end desktop diagnostics ---\"; } > /tmp/desktop-diag.txt 2>&1\n"];
    [b appendString:@"sleep 5\n"];
    [b appendString:@"cat /tmp/desktop-diag.txt\n"];
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
    self.desktopReady = NO;
    self.serverListening = NO;
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
    [self.healthTimer invalidate];
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
                    // Running now means the server answers, not the
                    // desktop marker: the marker is a console line
                    // and the console drops post-X output, so the
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
}

- (void)checkHealthWithCompletion:(void (^)(BOOL, NSDictionary * _Nullable))completion {
    // Healthy means the guest is up AND the server answers /api/info
    // through the same vsock bridge the native UI uses. The
    // desktopReady flag is deliberately NOT a gate here: it is a
    // console marker, and the console proved unreliable twice — the
    // echo of the typed READY loop fired it 1 s after serve launch
    // (containsString), and the post-X console output that would
    // carry a real READY is dropped (873e1ee: no bare DESKTOP READY
    // line ever reached the log). Gating health on it would restart
    // the engine every 5 minutes whenever the console drops the
    // marker. The server probe is the honest health signal; the
    // desktop view is available as a tab regardless, and a real
    // DESKTOP READY still lands in the engine log when it arrives.
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

@end
