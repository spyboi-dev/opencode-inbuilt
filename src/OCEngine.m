// OCEngine - the in-app engine host.
#import "OCEngine.h"
#import "OCSettings.h"
#import "OCServerClient.h"
#import <CommonCrypto/CommonDigest.h>

#ifdef OC_CORE_LINKED
#import "CoreGlue.h"
#endif

static NSString *const kEngineInstalled = @"oc.engineInstalled";
static NSString *const kDebianCached = @"oc.debianCached";

@interface OCEngine ()
@property (nonatomic, assign) OCEngineState state;
@property (nonatomic, strong, nullable) NSTimer *healthTimer;
@property (nonatomic, assign) NSInteger healthFailures;
// First start can take minutes (Node + OpenCode install in the guest);
// health failures before this date are ignored so the engine is not
// restarted while the install is still running.
@property (nonatomic, strong, nullable) NSDate *healthGraceUntil;
// Serve progress: the guest writes PROGRESS lines to the exchange
// dir's serve.log; this timer polls it while the engine is starting
// and drives serveProgress/serveStatus for the Engine tab.
@property (nonatomic, strong, nullable) NSTimer *serveProgressTimer;
@property (nonatomic, assign) double serveProgressValue;
@property (nonatomic, strong, nullable) NSString *serveStatusValue;
@property (nonatomic, assign) NSUInteger serveLogLinesSeen;
@property (nonatomic, assign) BOOL serveProgressDone;
// First-launch setup chain state. The chain is held STRONGLY by the
// OCEngine singleton (which lives for the life of the app), and it is
// driven by the -setupDownloadNext instance method, never by a block
// that calls itself. A previous version held the next step in a
// __weak block variable; nothing retained that block after
// runFirstLaunchSetup returned, so the first async download's
// completion handler called a nil block and crashed (see CRASH-FIX.md).
@property (nonatomic, assign) BOOL setupActive;
@property (nonatomic, strong, nullable) NSArray *setupPackages;
@property (nonatomic, strong, nullable) NSString *setupCacheDir;
@property (nonatomic, strong, nullable) NSString *setupRepository;
@property (nonatomic, assign) NSUInteger setupIndex;
@property (nonatomic, copy, nullable) void (^setupProgress)(double fraction, NSString *message);
@property (nonatomic, copy, nullable) void (^setupCompletion)(BOOL done, NSError * _Nullable error);
@property (nonatomic, strong, nullable) NSURLSession *setupSession;
- (void)startServeWithCompletion:(void (^)(BOOL, NSError * _Nullable))completion;
#ifdef OC_CORE_LINKED
- (NSArray<NSString *> *)cachedDebianPackagePaths;
#endif
@end

@implementation OCEngine

+ (instancetype)shared {
    static OCEngine *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[OCEngine alloc] init]; [s refreshState]; });
    return s;
}

- (BOOL)guestCoreLinked { return self.guestExecutor != nil; }

- (NSString *)engineDirectory {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"Engine"];
}

- (NSString *)stateDescription {
    switch (self.state) {
        case OCEngineStateNotInstalled: return @"Not installed";
        case OCEngineStateInstalling: return @"Installing Debian";
        case OCEngineStateInstalled: return @"Installed, guest stopped";
        case OCEngineStateStarting: return @"Starting engine";
        case OCEngineStateRunning: return @"Engine running";
        case OCEngineStateStopped: return @"Engine stopped";
        case OCEngineStateCorePending: return @"Engine core pending link";
        case OCEngineStateError: return @"Engine error";
    }
}

- (void)setState:(OCEngineState)state {
    if (_state == state) return;
    _state = state;
    [self appendEngineLog:[NSString stringWithFormat:@"State: %@", self.stateDescription]];
    if (self.stateDidChange) self.stateDidChange(state);
}

- (void)refreshState {
    // Do not clobber a live engine: viewWillAppear calls this every
    // time the Engine tab is shown, and it was resetting a Running
    // engine back to "Installed, guest stopped" while the server
    // was up. The flags on disk only describe install state.
    if (self.state == OCEngineStateRunning || self.state == OCEngineStateStarting) return;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d boolForKey:kEngineInstalled]) { [self setState:OCEngineStateNotInstalled]; return; }
    if (![d boolForKey:kDebianCached]) { [self setState:OCEngineStateNotInstalled]; return; }
    [self setState:OCEngineStateInstalled];
}

- (NSString *)serveLaunchCommand {
    // Password is never put in a log; this string is only handed to the guest.
    NSString *pw = [[OCSettings shared] ensureServerPassword];
    return [NSString stringWithFormat:@"OPENCODE_SERVER_PASSWORD=%@ opencode serve --port 4096 --hostname 0.0.0.0", pw];
}

#pragma mark - Engine log + serve progress (in-app diagnostics)

// Serial queue so log appends from any thread (main, executor
// completion, timers) cannot interleave in the file.
static dispatch_queue_t OCEngineLogQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("com.spyboy.opencode.engineLog", DISPATCH_QUEUE_SERIAL); });
    return q;
}

- (NSString *)engineLogPath {
    return [[self engineDirectory] stringByAppendingPathComponent:@"engine.log"];
}

- (NSString *)guestServeLogPath {
    return [[[self engineDirectory] stringByAppendingPathComponent:@"exchange"] stringByAppendingPathComponent:@"serve.log"];
}

- (NSString *)guestBootLogPath {
    return [[self engineDirectory] stringByAppendingPathComponent:@"boot.log"];
}

- (void)appendEngineLog:(NSString *)line {
    if (!line.length) return;
    NSString *copy = [line copy];
    dispatch_async(OCEngineLogQueue(), ^{
        NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"HH:mm:ss";
        NSString *entry = [NSString stringWithFormat:@"[%@] %@\n", [fmt stringFromDate:[NSDate date]], copy];
        NSString *path = [self engineLogPath];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:[path stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
        NSData *data = [entry dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!fh) {
            [data writeToFile:path atomically:NO];
        } else {
            [fh seekToEndOfFile];
            [fh writeData:data];
            unsigned long long size = [fh offsetInFile];
            [fh closeFile];
            if (size > 200 * 1024) {
                NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
                if (old.length > 100 * 1024) {
                    NSString *tail = [old substringFromIndex:old.length - 100 * 1024];
                    NSRange nl = [tail rangeOfString:@"\n"];
                    if (nl.location != NSNotFound) tail = [tail substringFromIndex:nl.location + 1];
                    [tail writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
                }
            }
        }
    });
}

+ (nullable NSString *)contentsOfFileOrNote:(NSString *)path label:(NSString *)label {
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text) return [NSString stringWithFormat:@"(%@ not present yet)\n", label];
    if (!text.length) return [NSString stringWithFormat:@"(%@ is empty)\n", label];
    return text;
}

- (NSString *)fullLogText {
    NSMutableString *out = [NSMutableString string];
    [out appendString:@"=== Engine log ===\n"];
    NSString *engine = [OCEngine contentsOfFileOrNote:[self engineLogPath] label:@"engine.log"];
    [out appendString:engine];
    if (![engine hasSuffix:@"\n"]) [out appendString:@"\n"];
    [out appendString:@"\n=== Guest boot.log ===\n"];
    [out appendString:[OCEngine contentsOfFileOrNote:[self guestBootLogPath] label:@"boot.log"]];
    [out appendString:@"\n=== Guest serve.log ===\n"];
    [out appendString:[OCEngine contentsOfFileOrNote:[self guestServeLogPath] label:@"serve.log"]];
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

- (void)startServeProgressTimer {
    [self.serveProgressTimer invalidate];
    self.serveProgressTimer = nil;
    self.serveLogLinesSeen = 0;
    self.serveProgressDone = NO;
    __weak typeof(self) weakSelf = self;
    self.serveProgressTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer * _Nonnull timer) {
        (void)timer;
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf pollServeLog];
    }];
}

- (void)stopServeProgressTimer {
    [self.serveProgressTimer invalidate];
    self.serveProgressTimer = nil;
}

// Read the guest serve.log (exchange dir), apply the latest PROGRESS
// line, and append any new guest lines to the in-app engine log.
- (void)pollServeLog {
    NSString *text = [NSString stringWithContentsOfFile:[self guestServeLogPath] encoding:NSUTF8StringEncoding error:nil];
    if (!text) return;
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    if (lines.count > self.serveLogLinesSeen) {
        for (NSUInteger i = self.serveLogLinesSeen; i < lines.count; i++) {
            NSString *l = lines[i];
            if (l.length) [self appendEngineLog:[NSString stringWithFormat:@"guest: %@", l]];
        }
        self.serveLogLinesSeen = lines.count;
    }
    // The server prints "server listening on ..." when it is up.
    // That is the definitive start signal: complete the bar and the
    // state even if the HTTP health check has not confirmed it yet.
    if ([text containsString:@"server listening"]) {
        if (!self.serveProgressDone) {
            self.serveProgressDone = YES;
            [self setServeProgress:1.0 status:@"Engine running"];
            [self stopServeProgressTimer];
            [self appendEngineLog:@"Server listening (from guest serve.log)"];
            if (self.state != OCEngineStateRunning) [self setState:OCEngineStateRunning];
        }
        return;
    }
    for (NSInteger i = (NSInteger)lines.count - 1; i >= 0; i--) {
        NSString *l = lines[(NSUInteger)i];
        if ([l hasPrefix:@"PROGRESS "]) {
            NSArray<NSString *> *parts = [l componentsSeparatedByString:@" "];
            if (parts.count >= 3) {
                double pct = [parts[1] doubleValue] / 100.0;
                // Progress only moves forward: the executor already
                // set 0.95 once the serve launched, and a stale
                // PROGRESS 90 line must not pull it back down.
                if (pct > self.serveProgressValue) {
                    NSString *msg = [[parts subarrayWithRange:NSMakeRange(2, parts.count - 2)] componentsJoinedByString:@" "];
                    [self setServeProgress:pct status:msg];
                }
            }
            return;
        }
        if ([l hasPrefix:@"ERROR "]) {
            [self setServeProgress:self.serveProgressValue status:l];
            return;
        }
    }
}

#pragma mark - First-launch setup (Debian package cache)

+ (nullable NSString *)sha256OfFileAtPath:(NSString *)path {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return nil;
    CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx);
    while (YES) {
        NSData *chunk = [fh readDataOfLength:65536];
        if (!chunk.length) break;
        CC_SHA256_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
    }
    [fh closeFile];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

+ (nullable NSData *)debianManifestData {
    // LiveContainer patches NSBundle.mainBundle to the guest bundle, so
    // mainBundle is normally right. bundleForClass is the fallback for
    // any host where the guest code lives in a different bundle: it is
    // the bundle the OCEngine class itself was loaded from.
    NSURL *url = [[NSBundle mainBundle] URLForResource:@"debian-manifest" withExtension:@"json"];
    NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
    if (!data) {
        NSURL *classURL = [[NSBundle bundleForClass:[OCEngine class]] URLForResource:@"debian-manifest" withExtension:@"json"];
        data = classURL ? [NSData dataWithContentsOfURL:classURL] : nil;
    }
    return data;
}

+ (NSError *)setupErrorWithCode:(NSInteger)code message:(NSString *)message {
    return [NSError errorWithDomain:@"OCEngine" code:code
                         userInfo:@{NSLocalizedDescriptionKey: message ?: @"Setup failed"}];
}

// Finish setup exactly once, always on the main queue, always with a
// non-nil error when done == NO. Clears the retained chain state first
// so a second tap (or a late download callback) cannot re-enter it.
- (void)setupFinishWithSuccess:(BOOL)done error:(nullable NSError *)error {
    void (^completion)(BOOL, NSError * _Nullable) = self.setupCompletion;
    NSURLSession *session = self.setupSession;
    self.setupCompletion = nil;
    self.setupProgress = nil;
    self.setupPackages = nil;
    self.setupCacheDir = nil;
    self.setupRepository = nil;
    self.setupIndex = 0;
    self.setupSession = nil;
    self.setupActive = NO;
    if (!completion) return;
    NSError *finalError = error;
    if (!done && !finalError) finalError = [OCEngine setupErrorWithCode:9 message:@"Setup failed with no error reported"];
    if (done) {
        [self appendEngineLog:@"First-launch setup done: Debian packages cached and verified"];
        [self setState:OCEngineStateInstalled];
    } else {
        [self appendEngineLog:[NSString stringWithFormat:@"First-launch setup failed: %@", finalError.localizedDescription ?: @"unknown"]];
        [self setState:OCEngineStateError];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(done, finalError);
        [session finishTasksAndInvalidate];
    });
}

- (void)setupReportProgress:(double)fraction message:(nullable NSString *)message {
    void (^progress)(double, NSString *) = self.setupProgress;
    if (!progress) return;
    NSString *msg = message ?: @"";
    dispatch_async(dispatch_get_main_queue(), ^{ progress(fraction, msg); });
}

// One step of the setup chain. Called from runFirstLaunchSetup (main
// thread) and from each download task's completion handler (background
// queue). It never calls itself through a block: the chain lives in
// the singleton's properties, so it survives the return of
// runFirstLaunchSetup and survives the app being a LiveContainer guest.
- (void)setupDownloadNext {
    if (!self.setupActive || !self.setupCompletion) return;
    NSArray *packages = self.setupPackages ?: @[];
    NSString *cacheDir = self.setupCacheDir ?: @"";
    NSString *repository = self.setupRepository ?: @"https://deb.debian.org/debian/";
    // Skip already-cached, SHA-verified files iteratively (no recursion,
    // so 103 cached files cannot grow the stack).
    while (self.setupIndex < packages.count) {
        id entry = packages[self.setupIndex];
        if (![entry isKindOfClass:[NSDictionary class]]) {
            [self setupFinishWithSuccess:NO error:[OCEngine setupErrorWithCode:5 message:[NSString stringWithFormat:@"Debian manifest entry %lu is not an object", (unsigned long)self.setupIndex]]];
            return;
        }
        NSString *filename = entry[@"Filename"];
        NSString *expectedSHA = entry[@"SHA256"];
        if (![filename isKindOfClass:[NSString class]] || !filename.length ||
            ![expectedSHA isKindOfClass:[NSString class]] || !expectedSHA.length) {
            [self setupFinishWithSuccess:NO error:[OCEngine setupErrorWithCode:5 message:[NSString stringWithFormat:@"Debian manifest entry %lu has no Filename or SHA256", (unsigned long)self.setupIndex]]];
            return;
        }
        NSString *name = [filename lastPathComponent];
        if (!name.length) {
            [self setupFinishWithSuccess:NO error:[OCEngine setupErrorWithCode:5 message:[NSString stringWithFormat:@"Debian manifest entry %lu has no file name", (unsigned long)self.setupIndex]]];
            return;
        }
        NSString *dest = [cacheDir stringByAppendingPathComponent:name];
        NSString *existingSHA = [OCEngine sha256OfFileAtPath:dest];
        if (existingSHA && [existingSHA isEqualToString:expectedSHA]) {
            self.setupIndex++;
            [self setupReportProgress:(double)self.setupIndex / (double)packages.count message:name];
            continue;
        }
        break;
    }
    if (self.setupIndex >= packages.count) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kDebianCached];
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kEngineInstalled];
        [self setupFinishWithSuccess:YES error:nil];
        return;
    }
    NSDictionary *pkg = packages[self.setupIndex];
    NSString *filename = pkg[@"Filename"];
    NSString *expectedSHA = pkg[@"SHA256"];
    NSString *name = [filename lastPathComponent];
    NSString *dest = [cacheDir stringByAppendingPathComponent:name];
    NSURL *url = [NSURL URLWithString:[repository stringByAppendingString:filename]];
    if (!url) {
        [self setupFinishWithSuccess:NO error:[OCEngine setupErrorWithCode:6 message:[NSString stringWithFormat:@"Bad download URL for %@", name]]];
        return;
    }
    [self setupReportProgress:(double)self.setupIndex / (double)packages.count message:name];
    if (!self.setupSession) {
        self.setupSession = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
    }
    NSURLSession *session = self.setupSession;
    __weak typeof(self) weakSelf = self;
    NSURLSessionDownloadTask *task = [session downloadTaskWithURL:url
        completionHandler:^(NSURL * _Nullable location, NSURLResponse * _Nullable response, NSError * _Nullable error) {
        (void)response;
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!strongSelf.setupActive || !strongSelf.setupCompletion) return;
        if (error || !location) {
            NSError *e = error ?: [OCEngine setupErrorWithCode:6 message:[NSString stringWithFormat:@"Download failed for %@ with no file and no error", name]];
            [strongSelf setupFinishWithSuccess:NO error:e];
            return;
        }
        NSError *moveError = nil;
        [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
        [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:dest] error:&moveError];
        if (moveError) { [strongSelf setupFinishWithSuccess:NO error:moveError]; return; }
        NSString *actualSHA = [OCEngine sha256OfFileAtPath:dest];
        if (!actualSHA || ![actualSHA isEqualToString:expectedSHA]) {
            [[NSFileManager defaultManager] removeItemAtPath:dest error:nil];
            NSError *e = [OCEngine setupErrorWithCode:2 message:[NSString stringWithFormat:@"SHA-256 mismatch for %@", name]];
            [strongSelf setupFinishWithSuccess:NO error:e];
            return;
        }
        strongSelf.setupIndex++;
        [strongSelf setupDownloadNext];
    }];
    [task resume];
}

- (void)runFirstLaunchSetupWithProgress:(void (^)(double, NSString *))progress
                             completion:(void (^)(BOOL, NSError * _Nullable))completion {
    // Guard: a tap while a setup chain is already running must not
    // start a second chain. The new caller gets a clear error, on the
    // main queue, and the running chain is untouched.
    if (self.setupActive || self.state == OCEngineStateInstalling) {
        NSError *e = [OCEngine setupErrorWithCode:7 message:@"Setup is already running"];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, e); });
        return;
    }
    // Setup is only the Debian package cache. It never touches the
    // guest core: guestExecutor is nil in this build and is never
    // called here. When the core is not linked, setup still caches
    // the packages and then stops cleanly; the view controller tells
    // the user the core is pending link and Start stays unavailable.
    self.setupActive = YES;
    self.setupProgress = progress;
    self.setupCompletion = completion;
    self.setupIndex = 0;
    [self appendEngineLog:@"First-launch setup started (Debian package download)"];
    [self setState:OCEngineStateInstalling];
    NSData *manifestData = [OCEngine debianManifestData];
    NSDictionary *manifest = nil;
    if (manifestData) {
        id parsed = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil];
        if ([parsed isKindOfClass:[NSDictionary class]]) manifest = parsed;
    }
    NSArray *packages = manifest[@"packages"];
    if (![packages isKindOfClass:[NSArray class]] || !packages.count) {
        NSError *e = [OCEngine setupErrorWithCode:1 message:@"Debian manifest missing from the app bundle"];
        [self setupFinishWithSuccess:NO error:e];
        return;
    }
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (!docs.length) {
        NSError *e = [OCEngine setupErrorWithCode:8 message:@"Documents directory is not available"];
        [self setupFinishWithSuccess:NO error:e];
        return;
    }
    NSString *cacheDir = [[self engineDirectory] stringByAppendingPathComponent:@"debian-cache"];
    NSError *dirError = nil;
    [[NSFileManager defaultManager] createDirectoryAtPath:cacheDir withIntermediateDirectories:YES attributes:nil error:&dirError];
    if (dirError) { [self setupFinishWithSuccess:NO error:dirError]; return; }
    self.setupPackages = packages;
    self.setupCacheDir = cacheDir;
    id repo = manifest[@"repository"];
    self.setupRepository = [repo isKindOfClass:[NSString class]] && ((NSString *)repo).length ? repo : @"https://deb.debian.org/debian/";
    [self setupDownloadNext];
}

#pragma mark - Start / stop / health

#ifdef OC_CORE_LINKED
// The cached .deb paths, in manifest order, re-derived from the bundle
// manifest and the cache dir (Engine/debian-cache). setupPackages and
// setupCacheDir are in-memory only and are nil after a relaunch, so
// this reads the manifest again instead of trusting them. Only files
// that actually exist on disk are returned.
- (NSArray<NSString *> *)cachedDebianPackagePaths {
    NSData *manifestData = [OCEngine debianManifestData];
    NSArray<NSString *> *paths = @[];
    if (!manifestData) return paths;
    id parsed = [NSJSONSerialization JSONObjectWithData:manifestData options:0 error:nil];
    if (![parsed isKindOfClass:[NSDictionary class]]) return paths;
    id packages = ((NSDictionary *)parsed)[@"packages"];
    if (![packages isKindOfClass:[NSArray class]]) return paths;
    NSString *cacheDir = [[self engineDirectory] stringByAppendingPathComponent:@"debian-cache"];
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (id entry in (NSArray *)packages) {
        if (![entry isKindOfClass:[NSDictionary class]]) continue;
        NSString *filename = ((NSDictionary *)entry)[@"Filename"];
        if (![filename isKindOfClass:[NSString class]] || !filename.length) continue;
        NSString *path = [cacheDir stringByAppendingPathComponent:[filename lastPathComponent]];
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) [out addObject:path];
    }
    return out;
}
#endif

- (void)startEngineWithCompletion:(void (^)(BOOL, NSError * _Nullable))completion {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    if (![d boolForKey:kEngineInstalled] || ![d boolForKey:kDebianCached]) {
        NSError *e = [NSError errorWithDomain:@"OCEngine" code:3
                                     userInfo:@{NSLocalizedDescriptionKey: @"First launch setup has not finished yet"}];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, e); });
        return;
    }
    if (!self.guestCoreLinked) {
        // The guest core library is not linked in this build. The engine
        // cannot boot without it, and this method says so instead of
        // pretending the server is running. See BUILD-NOTE.md.
        [self setState:OCEngineStateCorePending];
        NSError *e = [NSError errorWithDomain:@"OCEngine" code:4
                                     userInfo:@{NSLocalizedDescriptionKey: @"Guest engine core is not linked in this build. Link the LinuxRunner core (see BUILD-NOTE.md) and rebuild."}];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, e); });
        return;
    }
#ifdef OC_CORE_LINKED
    // Core linked but the guest is not booted yet (first Start after a
    // relaunch): boot it from the cached .deb packages first, then
    // launch the server. When the define is absent this block does
    // not exist and behaviour is unchanged.
    if (![OCCoreGlue shared].booted) {
        [self setState:OCEngineStateStarting];
        [self setServeProgress:0.05 status:@"Booting guest..."];
        [self appendEngineLog:@"Guest boot started"];
        __weak typeof(self) weakSelf = self;
        [[OCCoreGlue shared] bootWithPackagePaths:[self cachedDebianPackagePaths]
                                       completion:^(BOOL ok, NSError * _Nullable error) {
            typeof(self) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (!ok) {
                [strongSelf appendEngineLog:[NSString stringWithFormat:@"Guest boot failed: %@", error.localizedDescription ?: @"unknown"]];
                [strongSelf setState:OCEngineStateError];
                dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, error); });
                return;
            }
            [strongSelf appendEngineLog:@"Guest boot finished"];
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
    [self setState:OCEngineStateStarting];
    [self setServeProgress:0.05 status:@"Starting server..."];
    [self appendEngineLog:@"Serve launch started"];
    [self startServeProgressTimer];
    NSString *command = [self serveLaunchCommand];
    // Install Node + OpenCode once, then launch the server, inside the guest.
    // The Debian rootfs ships no Node, so the first Start downloads the
    // official Node 22 LTS arm64 binary (v22.23.5, verified live).
    // OpenCode 2.3.0 is NOT on npm (opencode-ai is the 1.x line,
    // latest 1.19.5, and has no 2.x versions), so it is installed
    // from the official release binary instead: the repo moved
    // sst/opencode -> anomalyco/opencode, asset
    // opencode-linux-arm64.tar.gz (114 MB, single opencode binary).
    // The .tar.gz is deliberate: the
    // guest has gzip but no xz binary, so tar -xJf fails with
    // "xz: Cannot exec" (seen in the 2026-11-17 device log).
    // Every step writes a PROGRESS line
    // (and any command output) to the exchange dir's serve.log, so the
    // app can show a live progress bar and the Logs view can show
    // exactly which step failed. The serve itself also logs there.
    NSString *bootstrap =
        @"SLOG=/home/mobile/Downloads/serve.log; "
        @"echo \"PROGRESS 5 Checking Node...\" > \"$SLOG\" 2>/dev/null; "
        @"if ! command -v node >/dev/null 2>&1; then "
        @"echo \"PROGRESS 10 Downloading Node 22 (25 MB)...\" >> \"$SLOG\" 2>/dev/null; "
        @"(cd /tmp && curl -fsSL -o node.tar.gz https://nodejs.org/dist/v22.23.5/node-v22.23.5-linux-arm64.tar.gz >> \"$SLOG\" 2>&1 && echo \"PROGRESS 40 Node downloaded, extracting...\" >> \"$SLOG\" && tar -xzf node.tar.gz -C /usr/local --strip-components=1 >> \"$SLOG\" 2>&1 && rm -f node.tar.gz && echo \"PROGRESS 55 Node ready\" >> \"$SLOG\") || echo \"ERROR Node install failed (see above)\" >> \"$SLOG\"; fi; "
        @"if ! command -v opencode >/dev/null 2>&1; then "
        @"echo \"PROGRESS 60 Downloading OpenCode 2.3.0 (114 MB)...\" >> \"$SLOG\" 2>/dev/null; "
        @"(cd /tmp && curl -fsSL -o opencode.tar.gz https://github.com/anomalyco/opencode/releases/download/v2.3.0/opencode-linux-arm64.tar.gz >> \"$SLOG\" 2>&1 && echo \"PROGRESS 80 OpenCode downloaded, installing...\" >> \"$SLOG\" && tar -xzf opencode.tar.gz -C /usr/local/bin opencode >> \"$SLOG\" 2>&1 && chmod +x /usr/local/bin/opencode && rm -f opencode.tar.gz && echo \"PROGRESS 85 OpenCode ready\" >> \"$SLOG\") || echo \"ERROR OpenCode install failed (see above)\" >> \"$SLOG\"; fi; "
        @"echo \"PROGRESS 90 Starting server...\" >> \"$SLOG\" 2>/dev/null; ";
    NSString *serveWithLog = [command stringByAppendingString:@" >> \"$SLOG\" 2>&1"];
    NSString *full = [bootstrap stringByAppendingString:serveWithLog];
    __weak typeof(self) weakSelf = self;
    self.guestExecutor(full, @"$HOME/Projects", ^(NSString * _Nullable output, NSInteger exitCode) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        // Pull the latest guest lines into the in-app log first.
        [strongSelf pollServeLog];
        if (exitCode != 0) {
            [strongSelf stopServeProgressTimer];
            [strongSelf appendEngineLog:[NSString stringWithFormat:@"Serve launch failed (exit %ld)", (long)exitCode]];
            if (output.length) NSLog(@"[OCEngine] serve launch failed, guest output: %@", output);
            [strongSelf setServeProgress:strongSelf.serveProgressValue status:@"Serve launch failed, see Logs"];
            [strongSelf setState:OCEngineStateError];
            NSError *e = [NSError errorWithDomain:@"OCEngine" code:(NSInteger)exitCode
                                         userInfo:@{NSLocalizedDescriptionKey: @"Guest serve launch failed"}];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(NO, e); });
            return;
        }
        [strongSelf setState:OCEngineStateRunning];
        [strongSelf setServeProgress:0.95 status:@"Waiting for server..."];
        // The Node/OpenCode install can still be running when the
        // executor acks; give the first start 5 minutes before health
        // failures can restart the engine.
        strongSelf.healthGraceUntil = [NSDate dateWithTimeIntervalSinceNow:300];
        [strongSelf startHealthTimer];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(YES, nil); });
    });
}

- (void)stopEngine {
    [self.healthTimer invalidate];
    self.healthTimer = nil;
    [self stopServeProgressTimer];
    [self setServeProgress:0 status:nil];
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
                if (!strongSelf.serveProgressDone) {
                    strongSelf.serveProgressDone = YES;
                    [strongSelf setServeProgress:1.0 status:@"Engine running"];
                    [strongSelf stopServeProgressTimer];
                    [strongSelf appendEngineLog:@"Server healthy at 127.0.0.1:4096"];
                }
                return;
            }
            // First start can still be installing Node/OpenCode; ignore
            // failures until the grace period ends.
            if (strongSelf.healthGraceUntil && [[NSDate date] compare:strongSelf.healthGraceUntil] == NSOrderedAscending) return;
            strongSelf.healthFailures++;
            if (strongSelf.healthFailures >= 3) {
                // Guest died (iOS suspended or killed the app). Files persist,
                // processes do not: mark stopped and try to restart the server.
                [strongSelf stopEngine];
                [strongSelf startEngineWithCompletion:^(BOOL started, NSError * _Nullable error) { (void)started; (void)error; }];
            }
        }];
    }];
}

- (void)checkHealthWithCompletion:(void (^)(BOOL, NSDictionary * _Nullable))completion {
    OCSettings *settings = [OCSettings shared];
    OCServerClient *client = [[OCServerClient alloc] initWithServerURL:settings.serverURL password:[settings serverPassword]];
    [client healthCheckWithCompletion:^(BOOL ok, NSDictionary * _Nullable info, NSError * _Nullable error) {
        (void)error;
        completion(ok, info);
    }];
}

@end
