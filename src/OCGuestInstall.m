// OCGuestInstall - see OCGuestInstall.h.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "OCGuestInstall.h"
#import "OCEngine.h"
#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <zlib.h>

// Guest image published 2026-11-21 as release rootfs-20261120
// (opencode-debian-trixie-arm64.ext4.gz, 1,159,150,314 bytes).
// Hashes from rootfs-build/SHA256SUMS. A version difference is an
// update, not a failure: an installed image from an older release
// boots as-is (see guestInstalledAt:), and only a file that cannot
// be a guest image at all is damaged.
//
// Chunked delivery: the 1.16 GB .gz is split into 12 ~100 MiB parts
// (rootfs-build/CHUNKS-SHA256SUMS). The app downloads each part,
// verifies its SHA-256, and only then reassembles the .gz and verifies
// the whole archive hash. A part that fails verification is deleted
// and re-downloaded; already-verified parts are kept, so a killed
// Install resumes at the first missing part instead of restarting
// from zero.
//
// Download design (2026-11-24, the download crash): the transfer
// runs in a BACKGROUND NSURLSession (OCChunkedDownload below), so it
// lives in the nsurlsessiond daemon, not in the app process — the
// app's memory stays flat while 100 MB parts arrive, and the
// download survives the app being suspended or killed (the daemon
// finishes the part; the next Install resumes from the verified
// parts). The old design — [NSURLSession sharedSession] with a
// completion handler and a dispatch_semaphore_wait poll loop on a
// blocked GCD thread — kept the whole 1.16 GB transfer in-process
// while the app sat in the background on its location budget, and
// died SIGKILL-class (no CRASH line, no error, log stops
// mid-download) on two builds. The log never named the killer
// because nothing logged during the download at all: progress only
// updated the UI. So this file now logs every part start/finish and
// every 10% with bytes AND footprint, via appendEngineLogSync
// (synchronous; the engine-log write fsyncs), so the next log names
// the exact part, percent and footprint where it died.
//
// Resume data IS used now, but validated first (TermX 8c76d48:
// downloadTaskWithResumeData: THROWS NSInvalidArgumentException on
// a stale blob instead of returning nil, so a stale resume file
// made every Install tap crash in under a second). A blob is only
// used when it is a plist dictionary whose remote URL matches the
// part being downloaded, and the call is still wrapped in
// @try/@catch — a bad blob can only ever cost a fresh download,
// never a crash. A part that fails verification is deleted and
// re-downloaded; already-verified parts are kept, so a killed
// Install resumes at the first missing part instead of restarting
// from zero. Task creation is still wrapped in @try/@catch, and the
// install pipeline (assemble / gunzip / verify) runs on a background
// queue: the installed check SHA-256s a 4.46 GB image and must never
// run on the main thread.
// Extraction design (2026-11-25, the extraction crash): the
// download fix worked — the a29614b run verified all 12 parts and
// reached "Download verified" — but the app still died, now in the
// silent extraction phase (gunzip 1.16 GB -> 4.46 GB, then a full
// SHA-256 of the 4.46 GB image), with no log line and no error.
// Two causes, both fixed here: (1) SHA256OfFile and AssembleChunks
// loop readDataOfLength:1MB with no @autoreleasepool, so a 4.46 GB
// hash inside the install block can retain gigabytes of dead
// NSData past the jetsam limit; every streaming loop now drains
// per chunk. (2) The extraction had no logging and no resumability
// — a kill mid-extraction forced a full 1.16 GB re-download (parts
// deleted, archive deleted at install start). The verified archive
// is now kept until the swap succeeds, so a kill costs a
// re-extraction; the extraction logs every 10% with bytes and
// footprint; and the background-task expiration handler stops the
// gunzip cleanly instead of being frozen mid-write and killed
// while suspended.
NSString *const kOCGuestImageChunkBaseURL =
    @"https://github.com/spyboi-dev/opencode-ios/releases/download/rootfs-20261120/";
NSString *const kOCGuestImageName = @"opencode-debian-trixie-arm64.ext4";
NSString *const kOCGuestImageGzSHA256 = @"b1018c9357236ea2355bff488eda32171cc25c450997cccd7052b15992d3a8fa";
NSString *const kOCGuestImageSHA256 = @"c7511200d3e23e21bcd68e63904e489b4724e24c263464e92c8dd72963a83e1f";
const long long kOCGuestImageSize = 4462739456; // extracted .ext4 size in bytes

// Chunk table: 12 parts, 100 MiB each except the last (5,716,714 bytes).
// Names and SHA-256 from rootfs-build/CHUNKS-SHA256SUMS.
static const NSInteger kOCGuestImageChunkCount = 12;
static NSString *const kOCGuestImageChunkNames[] = {
    @"opencode-debian-trixie-arm64.ext4.gz.part00",
    @"opencode-debian-trixie-arm64.ext4.gz.part01",
    @"opencode-debian-trixie-arm64.ext4.gz.part02",
    @"opencode-debian-trixie-arm64.ext4.gz.part03",
    @"opencode-debian-trixie-arm64.ext4.gz.part04",
    @"opencode-debian-trixie-arm64.ext4.gz.part05",
    @"opencode-debian-trixie-arm64.ext4.gz.part06",
    @"opencode-debian-trixie-arm64.ext4.gz.part07",
    @"opencode-debian-trixie-arm64.ext4.gz.part08",
    @"opencode-debian-trixie-arm64.ext4.gz.part09",
    @"opencode-debian-trixie-arm64.ext4.gz.part10",
    @"opencode-debian-trixie-arm64.ext4.gz.part11",
};
static NSString *const kOCGuestImageChunkSHA256[] = {
    @"fcb2337ab43d5e4158295d69a355388c31bfdb06e6bfdad9e008c962ce95ba53",
    @"35a25e8b2ede174bd02ab20bf36d8e7b5cf121f7358f3b4b102d2a0737308fe3",
    @"0eabfe831216767a07b89909d42e4707a33d9789018566f3f2abb64113158ef9",
    @"a56f58349f8906932ba294c64e94faf3ea62a28a824ee886f4c1ea58316170cd",
    @"aac03682fac715e776623e9a4ca0a2a0b19b3b671bc6c3a0a9551f016110c98b",
    @"a957c690982dbd46f8ae56841e38d523af0f063b4e9b98bbaec8d7223164b14f",
    @"7fb8d922db43f2baaa3d36f511c9dbc0e31ebb3babdb2bb83e6c8a3aaa768fd8",
    @"00a262fc27ab876063b5f200d6f607482a645bcba5a3b3b0b1c84695e9d2bea7",
    @"e53e8d09f2dd0ee5410f1056aa74d05f8492fc3a16163332fe51027ddf25e601",
    @"9dad6dc9cf7df436bd1a12348bbe63da54303231862e13a316c40274c7c62360",
    @"ffba913c707fe29c94a7a2f109b479794843da7ca6ab22bfa1d46f11442d7297",
    @"77d42a1fcf088a4cd917b0cb48cb648969263fbbad5593ae77ce662569013db5",
};
static const long long kOCGuestImageChunkSizes[] = {
    104857600, 104857600, 104857600, 104857600, 104857600, 104857600,
    104857600, 104857600, 104857600, 104857600, 104857600, 5716714,
};

// Stop flag for the extraction: set by the install pipeline's
// background-task expiration handler when iOS's ~30 s background
// budget runs out mid-extraction. The gunzip loop checks it per
// chunk and stops cleanly instead of being frozen mid-write and
// killed while suspended. Volatile: set on the main queue
// (expiration handler), read on the install queue.
static volatile BOOL s_extractionStopRequested = NO;

static NSString *SHA256OfFile(NSString *path, NSError **outError) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) {
        if (outError) *outError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
        return nil;
    }
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    while (YES) {
        // @autoreleasepool per chunk: readDataOfLength: returns an
        // autoreleased 1 MB NSData, and this loop runs inside the
        // install block on a GCD worker thread whose pool only
        // drains when the block returns. Without the pool, hashing
        // the 4.46 GB extracted image retains gigabytes of dead
        // NSData in the pool — on top of the ~2.4 GB already hashed
        // in this block (12 parts + the .gz) — and iOS SIGKILLs
        // the app past its jetsam limit with no crash line,
        // exactly the silent death the 2026-11-25 log shows (log
        // stops after "Download verified", no extraction lines, no
        // error). Whether Foundation elides the autorelease here is
        // not provable statically; the pool makes the footprint
        // flat either way.
        @autoreleasepool {
            NSData *chunk = [handle readDataOfLength:1 << 20];
            if (chunk.length == 0) break;
            CC_SHA256_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
        }
    }
    [handle closeFile];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

static BOOL FileHasHash(NSString *path, NSString *expected) {
    NSError *error = nil;
    NSString *hash = SHA256OfFile(path, &error);
    return hash && [hash isEqualToString:expected];
}

static BOOL FileHasSize(NSString *path, long long expected) {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    // Cast: fileSize is unsigned long long; expected is always a
    // positive size here, so the comparison is exact. (Silences a
    // -Wsign-compare warning from the desktop-branch port.)
    return attrs && [attrs fileSize] == (unsigned long long)expected;
}

// Human-readable byte counts for the log (TermX TXFormatBytes).
static NSString *OCFormatBytes(unsigned long long bytes) {
    if (bytes >= (1ULL << 30)) {
        return [NSString stringWithFormat:@"%.2f GiB", (double)bytes / (double)(1ULL << 30)];
    }
    if (bytes >= (1ULL << 20)) {
        return [NSString stringWithFormat:@"%.0f MiB", (double)bytes / (double)(1ULL << 20)];
    }
    if (bytes >= (1ULL << 10)) {
        return [NSString stringWithFormat:@"%.0f KiB", (double)bytes / (double)(1ULL << 10)];
    }
    return [NSString stringWithFormat:@"%llu B", bytes];
}

// The app's own memory footprint (phys_footprint via task_info).
// Logged with every download milestone: if the app is ever killed
// mid-download again, the last footprint line says whether memory
// was climbing. (TermX TXCurrentFootprintBytes.)
static unsigned long long OCCurrentFootprintBytes(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS) {
        return (unsigned long long)info.phys_footprint;
    }
    return 0;
}

// One log line to the engine log, synchronously: a SIGKILL a
// millisecond later cannot lose it (the write fsyncs). Used for
// every download milestone, so a killed download leaves its exact
// position instead of silence.
static void OCInstallLog(NSString *line) {
    if (!line.length) return;
    [[OCEngine shared] appendEngineLogSync:line];
}

// Resume data is a plist the system wrote when a download was
// interrupted. It can go stale: the daemon temp file it names may
// be purged between runs, or the blob can be truncated. And
// downloadTaskWithResumeData: THROWS NSInvalidArgumentException on
// malformed data instead of returning nil — an unguarded call is an
// instant crash on every Install tap until the file is deleted.
// (TermX 8c76d48, same validation here.) Validate first (lenient:
// a plist dictionary with a remote URL), and still catch, so a bad
// blob can only ever cost a fresh download, never a crash. The
// remote URL must also match the part this blob is for: a resume
// blob for another part is stale by definition — resuming it would
// keep downloading the wrong bytes, which then fail the hash check.
static BOOL OCResumeDataIsUsable(NSData *data, NSString *partURLString) {
    if (!data.length) return NO;
    NSError *error = nil;
    id plist = [NSPropertyListSerialization propertyListWithData:data
                                                         options:NSPropertyListImmutable
                                                          format:NULL
                                                           error:&error];
    if (![plist isKindOfClass:[NSDictionary class]]) return NO;
    NSString *remoteURL = plist[@"NSURLSessionResumeInfoRemoteURL"];
    if (![remoteURL isKindOfClass:[NSString class]] || !remoteURL.length) return NO;
    if (![remoteURL isEqualToString:partURLString]) return NO;
    return YES;
}

// Disk-full, anywhere in the error chain: an NSURLSession failure
// can carry ENOSPC as an NSPOSIXErrorDomain code, or as
// NSFileWriteOutOfSpaceError in the Cocoa domain, on the error
// itself or on its underlying error. A full disk is not a Wi-Fi
// problem, and the old generic "check Wi-Fi" message sent the user
// to the wrong fix. (TermX, same helper.)
static BOOL OCErrorIsOutOfSpace(NSError *error) {
    for (NSError *e = error; e; e = e.userInfo[NSUnderlyingErrorKey]) {
        if (![e isKindOfClass:[NSError class]]) break;
        if ([e.domain isEqualToString:NSPOSIXErrorDomain] && e.code == ENOSPC) return YES;
        if ([e.domain isEqualToString:NSCocoaErrorDomain] && e.code == NSFileWriteOutOfSpaceError) return YES;
    }
    return NO;
}

// Free bytes on the volume holding path, or 0 when it cannot be
// measured (fails open: the install proceeds and the real error,
// if any, names itself).
static unsigned long long OCFreeSpaceAtPath(NSString *path) {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:path error:nil];
    NSNumber *free = attrs[NSFileSystemFreeSize];
    return free ? [free unsignedLongLongValue] : 0;
}

// Progress is always reported on the main queue (the interface
// contract in OCGuestInstall.h); the install itself runs on a
// background queue.
static void ReportProgress(void (^progress)(double, NSString *), double fraction, NSString *step) {
    if (!progress) return;
    dispatch_async(dispatch_get_main_queue(), ^{ progress(fraction, step); });
}

// OCChunkedDownload: one background download, owned for the
// process lifetime. It is the NSURLSessionDownloadDelegate, so
// progress, completion, resume data and the background wake-up all
// arrive here even when the app was killed and relaunched in the
// background: the daemon (nsurlsessiond) owns the transfer, not the
// app process, so a part keeps downloading while the app is
// suspended and finishes even if the app died — and the next
// Install finds the part already verified instead of restarting
// from zero. (TermX TXRootfsDownload, same shape, single file;
// here one part at a time, 12 parts in sequence.)
//
// Why a background session (2026-11-24, the download crash): the
// old code used [NSURLSession sharedSession] with a completion
// handler and a dispatch_semaphore_wait poll loop on a blocked GCD
// thread — the whole 1.16 GB transfer ran in-process while the app
// sat on its background location budget, and died SIGKILL-class
// (no CRASH line, no error, log stops mid-download) on two builds.
// A background session moves the transfer out of the app's memory
// budget entirely, so the app's footprint stays flat while parts
// arrive; the only in-process work per part is a SHA-256 verify.
//
// The session identifier is stable across builds: the daemon
// matches pending tasks by identifier, so a part started by an
// older build is still delivered to this build's delegate. A
// task's taskDescription carries its destination path, so a part
// that finished while the app was dead is moved into place by the
// delegate on relaunch with no pipeline running.
static NSString *const kOCGuestDownloadSessionID = @"com.spyboy.opencode.guestdownload";

@interface OCChunkedDownload : NSObject <NSURLSessionDownloadDelegate>
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong, nullable) NSURLSessionDownloadTask *task;
@property (nonatomic, copy, nullable) NSString *currentURLString;
@property (nonatomic, copy, nullable) NSString *currentDstPath;
@property (nonatomic, copy, nullable) NSString *currentPartName;
@property (nonatomic, copy, nullable) void (^progressBlock)(double);
@property (nonatomic, copy, nullable) void (^completionBlock)(BOOL ok, NSString * _Nullable error);
@property (nonatomic, copy, nullable) void (^backgroundCompletion)(void);
@property (nonatomic) int64_t received;
@property (nonatomic) int64_t expected;
@property (nonatomic) NSInteger lastLoggedPercent; // -1 until the first 10%
@end

static OCChunkedDownload *s_sharedDownload = nil;

@implementation OCChunkedDownload

+ (instancetype)sharedDownload {
    // Thread-safe: installGuestTo: starts on a background queue and
    // the background-wake path calls this from the main thread, so
    // two threads can race a plain nil check and create two sessions
    // with the same identifier (the second invalidates the first,
    // and its tasks die with it). (TermX, same note.)
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s_sharedDownload = [[OCChunkedDownload alloc] init];
        s_sharedDownload.lastLoggedPercent = -1;
        NSURLSessionConfiguration *config =
            [NSURLSessionConfiguration backgroundSessionConfigurationWithIdentifier:kOCGuestDownloadSessionID];
        config.allowsCellularAccess = YES;
        config.sessionSendsLaunchEvents = YES;
        s_sharedDownload.session = [NSURLSession sessionWithConfiguration:config
                                                                 delegate:s_sharedDownload
                                                            delegateQueue:nil];
        [[NSNotificationCenter defaultCenter] addObserver:s_sharedDownload
                                                 selector:@selector(memoryWarning:)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
    });
    return s_sharedDownload;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)memoryWarning:(NSNotification *)note {
    (void)note;
    OCInstallLog([NSString stringWithFormat:@"MEMORY WARNING during download: %@ — %@ of %@ received, footprint %@",
                  self.currentPartName ?: @"?",
                  OCFormatBytes((unsigned long long)MAX(0, self.received)),
                  OCFormatBytes((unsigned long long)MAX(0, self.expected)),
                  OCFormatBytes(OCCurrentFootprintBytes())]);
}

// Re-attach after a background relaunch: create the session (if it
// does not exist yet) so the daemon delivers its pending events to
// this delegate, and hold the system completion handler until the
// session has delivered them all. Called from the AppDelegate
// background-session handler. (TermX, same shape.)
+ (void)reconnectBackgroundSessionWithCompletionHandler:(void (^)(void))handler {
    OCChunkedDownload *dl = [self sharedDownload];
    @synchronized (dl) {
        dl.backgroundCompletion = handler;
    }
    OCInstallLog([NSString stringWithFormat:@"Background URL session event: %@", kOCGuestDownloadSessionID]);
}

// Resume file for a part: tmp/<partname>.resume, next to the part.
- (NSString *)resumePathForDstPath:(NSString *)dstPath {
    return [dstPath stringByAppendingString:@".resume"];
}

// Download one part (urlString -> dstPath). The transfer runs in
// the daemon; this call blocks the calling thread on a semaphore
// until the delegate reports the part done or failed — the thread
// is parked, not working, and the app's memory stays flat. If the
// daemon is already downloading this part (the app died mid-part
// and was relaunched), attach to that task instead of creating a
// second one for the same URL. Calls progress (0..1 within this
// part) and completion (YES when the file is in place) — completion
// is invoked exactly once per call. Safe to call from any thread.
- (void)downloadPartAtURL:(NSString *)urlString
                   toPath:(NSString *)dstPath
                 progress:(void (^)(double))progress
               completion:(void (^)(BOOL ok, NSString * _Nullable error))completion {
    // Adopt a task the daemon is still running for this URL (the
    // app died mid-part and the user tapped Install again before
    // it finished): creating a second task for the same URL would
    // download the same 100 MB twice and race the move. The query
    // is local and fast; the 10 s cap means a stuck query can only
    // ever cost a duplicate task, never a hang.
    __block NSArray<NSURLSessionDownloadTask *> *inflight = nil;
    dispatch_semaphore_t found = dispatch_semaphore_create(0);
    [self.session getTasksWithCompletionHandler:^(NSArray<NSURLSessionDataTask *> *dataTasks,
                                                  NSArray<NSURLSessionUploadTask *> *uploadTasks,
                                                  NSArray<NSURLSessionDownloadTask *> *downloadTasks) {
        (void)dataTasks; (void)uploadTasks;
        inflight = downloadTasks;
        dispatch_semaphore_signal(found);
    }];
    dispatch_semaphore_wait(found, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)));
    @synchronized (self) {
        for (NSURLSessionDownloadTask *t in inflight) {
            if (t.state == NSURLSessionTaskStateRunning &&
                [t.originalRequest.URL.absoluteString isEqualToString:urlString]) {
                OCInstallLog([NSString stringWithFormat:@"Download: part %@ is already downloading in the background — waiting for it",
                              [urlString lastPathComponent]]);
                self.task = t;
                self.currentURLString = urlString;
                self.currentDstPath = dstPath;
                self.currentPartName = [urlString lastPathComponent];
                self.progressBlock = progress;
                self.completionBlock = completion;
                self.received = t.countOfBytesReceived;
                self.expected = t.countOfBytesExpectedToReceive;
                self.lastLoggedPercent = -1;
                return;
            }
        }
    }

    // No live task for this part: start one, resuming from
    // validated resume data when it exists.
    NSURLSessionDownloadTask *task = nil;
    NSString *resumePath = [self resumePathForDstPath:dstPath];
    NSData *resumeData = [NSData dataWithContentsOfFile:resumePath];
    if (resumeData.length > 0 && OCResumeDataIsUsable(resumeData, urlString)) {
        OCInstallLog([NSString stringWithFormat:@"Download: Resuming part %@ from saved resume data (%@)",
                      [urlString lastPathComponent], OCFormatBytes((unsigned long long)resumeData.length)]);
        @try {
            task = [self.session downloadTaskWithResumeData:resumeData];
        } @catch (NSException *exception) {
            // Stale resume data throws instead of returning nil.
            // Log it, drop the blob, and start fresh — never crash.
            OCInstallLog([NSString stringWithFormat:@"Download: resume data threw %@ — starting part %@ fresh",
                          exception.name ?: @"?", [urlString lastPathComponent]]);
            task = nil;
        }
        if (!task) [[NSFileManager defaultManager] removeItemAtPath:resumePath error:nil];
    } else if (resumeData.length > 0) {
        OCInstallLog([NSString stringWithFormat:@"Download: saved resume data for part %@ failed validation — discarding it",
                      [urlString lastPathComponent]]);
        [[NSFileManager defaultManager] removeItemAtPath:resumePath error:nil];
    }
    if (!task) {
        NSURL *url = [NSURL URLWithString:urlString];
        if (!url) {
            if (completion) completion(NO, @"bad download URL");
            return;
        }
        @try {
            task = [self.session downloadTaskWithURL:url];
        } @catch (NSException *exception) {
            OCInstallLog([NSString stringWithFormat:@"Download: creating the task for part %@ threw %@",
                          [urlString lastPathComponent], exception.name ?: @"?"]);
            if (completion) completion(NO, @"could not start the download — try again");
            return;
        }
        if (!task) {
            if (completion) completion(NO, @"could not start the download — try again");
            return;
        }
    }
    // The destination rides on the task: a part that finished
    // while the app was dead is moved into place by the delegate
    // on relaunch with no pipeline running.
    task.taskDescription = dstPath;
    @synchronized (self) {
        self.task = task;
        self.currentURLString = urlString;
        self.currentDstPath = dstPath;
        self.currentPartName = [urlString lastPathComponent];
        self.progressBlock = progress;
        self.completionBlock = completion;
        self.received = 0;
        self.expected = 0;
        self.lastLoggedPercent = -1;
    }
    [task resume];
}

// Invoke the current waiter's completion exactly once, on the
// calling queue. Nil when no pipeline is waiting (a part that
// finished while the app was away): the file is already moved by
// then, and the next Install resumes from it.
- (void)completeCurrentWaiter:(BOOL)ok error:(NSString * _Nullable)error {
    void (^cb)(BOOL, NSString * _Nullable) = nil;
    @synchronized (self) {
        cb = self.completionBlock;
        self.completionBlock = nil;
        self.progressBlock = nil;
        self.task = nil;
    }
    if (cb) cb(ok, error);
}

#pragma mark - NSURLSessionDownloadDelegate

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
      didWriteData:(int64_t)bytesWritten
 totalBytesWritten:(int64_t)totalBytesWritten
totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    (void)session; (void)downloadTask; (void)bytesWritten;
    void (^pb)(double) = nil;
    @synchronized (self) {
        self.received = totalBytesWritten;
        self.expected = totalBytesExpectedToWrite;
        pb = self.progressBlock;
    }
    if (totalBytesExpectedToWrite > 0) {
        double f = (double)totalBytesWritten / (double)totalBytesExpectedToWrite;
        NSInteger pct = (NSInteger)(f * 100.0);
        @synchronized (self) {
            if (pct >= self.lastLoggedPercent + 10) {
                self.lastLoggedPercent = (pct / 10) * 10;
                OCInstallLog([NSString stringWithFormat:@"Download part %@: %ld%% · %@ of %@ · footprint %@",
                              self.currentPartName ?: @"?",
                              (long)pct,
                              OCFormatBytes((unsigned long long)totalBytesWritten),
                              OCFormatBytes((unsigned long long)totalBytesExpectedToWrite),
                              OCFormatBytes(OCCurrentFootprintBytes())]);
            }
        }
        if (pb) pb(f);
    }
}

- (void)URLSession:(NSURLSession *)session
      downloadTask:(NSURLSessionDownloadTask *)downloadTask
didFinishDownloadingToURL:(NSURL *)location {
    (void)session;
    NSString *dstPath = downloadTask.taskDescription;
    NSString *partName = dstPath.lastPathComponent ?: downloadTask.originalRequest.URL.lastPathComponent ?: @"?";
    if (!dstPath.length || !location) {
        [self completeCurrentWaiter:NO error:@"could not save the download"];
        return;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:dstPath error:nil];
    NSError *moveError = nil;
    BOOL moved = [fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:dstPath] error:&moveError];
    if (!moved) {
        OCInstallLog([NSString stringWithFormat:@"Download part %@: could not save the finished part: %@",
                      partName, moveError.localizedDescription ?: @"?"]);
        [self completeCurrentWaiter:NO error:@"could not save the download"];
        return;
    }
    // The part is on disk; its resume blob (if any) is now stale.
    [[NSFileManager defaultManager] removeItemAtPath:[self resumePathForDstPath:dstPath] error:nil];
    OCInstallLog([NSString stringWithFormat:@"Download part %@: finished, %@ received",
                  partName, OCFormatBytes((unsigned long long)self.received)]);
    [self completeCurrentWaiter:YES error:nil];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    (void)session;
    if (!error) return; // success is handled by didFinishDownloadingToURL
    NSString *dstPath = nil;
    NSString *urlString = nil;
    @synchronized (self) {
        dstPath = self.currentDstPath;
        urlString = self.currentURLString;
    }
    if (!dstPath.length) dstPath = task.taskDescription;
    if (!urlString.length) urlString = task.originalRequest.URL.absoluteString;
    NSString *partName = dstPath.lastPathComponent ?: urlString.lastPathComponent ?: @"?";
    // Save resume data so the next attempt continues mid-part
    // instead of from zero. It is validated before any use (see
    // OCResumeDataIsUsable), so a stale blob can never crash the
    // next Install.
    NSData *resumeData = error.userInfo[NSURLSessionDownloadTaskResumeData];
    if (resumeData.length > 0 && dstPath.length) {
        [resumeData writeToFile:[self resumePathForDstPath:dstPath] atomically:YES];
        OCInstallLog([NSString stringWithFormat:@"Download part %@: saved resume data (%@) — the next Install continues from %@",
                      partName, OCFormatBytes((unsigned long long)resumeData.length),
                      OCFormatBytes((unsigned long long)MAX(0, self.received))]);
    }
    if (OCErrorIsOutOfSpace(error)) {
        OCInstallLog([NSString stringWithFormat:@"Download part %@: failed, out of space at %@ of %@",
                      partName,
                      OCFormatBytes((unsigned long long)MAX(0, self.received)),
                      OCFormatBytes((unsigned long long)MAX(0, self.expected))]);
        [self completeCurrentWaiter:NO error:@"the phone ran out of free space while downloading — free some space and try again"];
        return;
    }
    OCInstallLog([NSString stringWithFormat:@"Download part %@: failed at %@ of %@: %@",
                  partName,
                  OCFormatBytes((unsigned long long)MAX(0, self.received)),
                  OCFormatBytes((unsigned long long)MAX(0, self.expected)),
                  error.localizedDescription ?: @"?"]);
    [self completeCurrentWaiter:NO error:@"download failed — check Wi-Fi and try again"];
}

- (void)URLSessionDidFinishEventsForBackgroundURLSession:(NSURLSession *)session {
    (void)session;
    void (^handler)(void) = nil;
    @synchronized (self) {
        handler = self.backgroundCompletion;
        self.backgroundCompletion = nil;
    }
    if (handler) {
        OCInstallLog(@"Background download events delivered");
        handler();
    }
}

@end

// Downloads one chunk to dstPath. Returns YES when the file is in
// place. Reports this chunk's 0..1 progress via progressBlock. The
// transfer itself runs in the background session's daemon (see
// OCChunkedDownload); this call only parks the calling thread until
// the delegate reports the part done or failed.
static BOOL DownloadChunk(NSString *urlString, NSString *dstPath, void (^progressBlock)(double)) {
    if (!urlString.length || !dstPath.length) return NO;
    __block BOOL ok = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [[OCChunkedDownload sharedDownload] downloadPartAtURL:urlString
                                                   toPath:dstPath
                                                 progress:progressBlock
                                               completion:^(BOOL success, NSString * _Nullable error) {
        (void)error;
        ok = success;
        dispatch_semaphore_signal(done);
    }];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return ok;
}

// Appends each chunk file to dstPath in order, streaming 1 MB at a
// time so memory stays flat. Returns NO (and removes a partial dst)
// on failure.
static BOOL AssembleChunks(NSArray<NSString *> *chunkPaths, NSString *dstPath) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:dstPath error:nil];
    if (![fm createFileAtPath:dstPath contents:nil attributes:nil]) return NO;
    NSFileHandle *out = [NSFileHandle fileHandleForWritingAtPath:dstPath];
    if (!out) return NO;
    BOOL ok = YES;
    for (NSString *chunkPath in chunkPaths) {
        NSFileHandle *in = [NSFileHandle fileHandleForReadingAtPath:chunkPath];
        if (!in) { ok = NO; break; }
        while (YES) {
            // @autoreleasepool per chunk, same as SHA256OfFile
            // above: without it the 1 MB autoreleased NSData from
            // every read accumulates in the install block's pool
            // for the whole 1.16 GB assembly.
            @autoreleasepool {
                NSData *data = [in readDataOfLength:1 << 20];
                if (data.length == 0) break;
                @try {
                    [out writeData:data];
                } @catch (NSException *exception) {
                    ok = NO;
                    break;
                }
            }
        }
        [in closeFile];
        if (!ok) break;
    }
    [out closeFile];
    if (!ok) [fm removeItemAtPath:dstPath error:nil];
    return ok;
}

@interface OCGuestInstall (Private)

+ (void)installGuestToOnQueue:(NSString *)rootfsPath
                     progress:(void (^)(double, NSString *))progress
                   completion:(void (^)(BOOL, NSString *))completion;
+ (NSDictionary *)verifiedRootfsFingerprint;
+ (BOOL)verifiedFingerprintMatchesPath:(NSString *)path attrs:(NSDictionary *)attrs;

@end

// Verified-image fingerprint: once the install pipeline has
// SHA-256'd the extracted image, the verdict is remembered in
// NSUserDefaults as the file's path, size, modification date AND
// the hash it verified as. guestInstalledAt — called on the boot
// path (KernGlue) and at install start/end — then answers from
// that fingerprint with a stat call instead of re-hashing 4.46 GB.
// The fingerprint only counts for the exact file it was recorded
// for: any size or mtime change voids it. The recorded hash is
// what tells an older release from the current one without
// hashing: a fingerprint hash that differs from kOCGuestImageSHA256
// means the image is an older release — an update is available,
// not a failure. (TermX c2f4ed5, same mechanism.)
static NSString *const kOCVerifiedRootfsKey = @"oc.verified-rootfs";

@implementation OCGuestInstall

// Cheap by design: exists + size + read-only bit, then the
// recorded fingerprint or the ext4 magic. NEVER a hash here —
// this runs on the boot path (KernGlue), and a full SHA-256 of
// 4.46 GB on every boot is the stall the fingerprint exists to
// avoid. A version difference is NOT a failure: an older release
// that is a valid ext4 image boots exactly like the current one,
// and the update is offered separately. Only a file that cannot
// be a guest image at all — wrong size, or not ext4 — is damaged.
+ (BOOL)guestInstalledAt:(NSString *)rootfsPath error:(NSString **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:rootfsPath error:nil];
    if (!attrs) {
        if (error) *error = @"guest image is not installed";
        return NO;
    }
    if (kOCGuestImageSize > 0 && [attrs fileSize] != (unsigned long long)kOCGuestImageSize) {
        if (error) *error = @"guest image is damaged (wrong size) — reinstall";
        return NO;
    }
    // This exact file was already hash-verified: the verdict
    // stands, whatever release it was verified as.
    if ([self verifiedFingerprintMatchesPath:rootfsPath attrs:attrs]) return YES;
    // Not yet verified by this build, or the file changed since it
    // was: a half-extracted file still carries write bits, so it
    // is not installed — and hashing it would only waste a second.
    if ([attrs filePosixPermissions] & 0222) {
        if (error) *error = @"guest image is not verified — reinstall";
        return NO;
    }
    // Read-only, no fingerprint: an image installed by an older
    // build, or an older release. If it is a real ext4 image it
    // boots; only a file that is not ext4 at all is damaged.
    if ([self imageLooksLikeExt4At:rootfsPath]) return YES;
    if (error) *error = @"guest image is damaged — reinstall";
    return NO;
}

+ (NSDictionary *)verifiedRootfsFingerprint {
    id fp = [[NSUserDefaults standardUserDefaults] objectForKey:kOCVerifiedRootfsKey];
    return [fp isKindOfClass:[NSDictionary class]] ? fp : nil;
}

+ (BOOL)verifiedFingerprintMatchesPath:(NSString *)path attrs:(NSDictionary *)attrs {
    NSDictionary *fp = [self verifiedRootfsFingerprint];
    if (!fp) return NO;
    if (![fp[@"path"] isEqualToString:path]) return NO;
    if ([fp[@"size"] unsignedLongLongValue] != [attrs fileSize]) return NO;
    NSDate *mtime = fp[@"mtime"];
    if (![mtime isKindOfClass:[NSDate class]]) return NO;
    return [mtime isEqualToDate:[attrs fileModificationDate]];
}

+ (void)recordVerifiedFingerprintForPath:(NSString *)path attrs:(NSDictionary *)attrs hash:(NSString *)hash {
    NSMutableDictionary *fp = [NSMutableDictionary dictionaryWithDictionary:
        @{@"path": path,
          @"size": @([attrs fileSize]),
          @"mtime": [attrs fileModificationDate]}];
    if ([hash isKindOfClass:[NSString class]] && hash.length) fp[@"sha256"] = hash;
    [[NSUserDefaults standardUserDefaults] setObject:fp forKey:kOCVerifiedRootfsKey];
}

// The hash this exact file was verified as, from its fingerprint —
// or nil when no fingerprint (or no hash field in it) answers for
// this file. Cheap: a stat plus a defaults read, never a hash.
+ (nullable NSString *)installedImageVerifiedHashAt:(NSString *)rootfsPath {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:rootfsPath error:nil];
    if (!attrs) return nil;
    if (![self verifiedFingerprintMatchesPath:rootfsPath attrs:attrs]) return nil;
    NSString *hash = [self verifiedRootfsFingerprint][@"sha256"];
    return [hash isKindOfClass:[NSString class]] ? hash : nil;
}

// Cheap: is the installed image already this build's release? Only
// the fingerprint's recorded hash can answer without hashing 4.46 GB.
+ (BOOL)installedImageIsCurrentReleaseAt:(NSString *)rootfsPath {
    NSString *hash = [self installedImageVerifiedHashAt:rootfsPath];
    return hash != nil && [hash isEqualToString:kOCGuestImageSHA256];
}

// The ext4 superblock magic 0xEF53 at offset 1080 (1024-byte boot
// sector + 56 bytes into the superblock), little-endian. A two-byte
// pread: the cheap proof a read-only image with no fingerprint is a
// real ext4 filesystem, not a truncated or foreign file.
+ (BOOL)imageLooksLikeExt4At:(NSString *)path {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return NO;
    @try {
        [handle seekToFileOffset:1080];
        NSData *magic = [handle readDataOfLength:2];
        [handle closeFile];
        if (magic.length != 2) return NO;
        const uint8_t *b = (const uint8_t *)magic.bytes;
        return b[0] == 0x53 && b[1] == 0xEF;
    } @catch (NSException *exception) {
        return NO;
    }
}

+ (nullable NSString *)SHA256OfImageAt:(NSString *)path {
    NSError *error = nil;
    return SHA256OfFile(path, &error);
}

// The pipeline's one-time verify: full SHA-256 of the extracted
// image, run once after extraction. On success the fingerprint is
// recorded (with the hash), so every later guestInstalledAt call
// is a stat. A failure here is a genuinely damaged fresh download,
// so the error says damaged — a version difference is not
// corruption, and this function only ever runs against the file
// the pipeline just extracted for this release.
+ (BOOL)guestImageHashValidAt:(NSString *)rootfsPath error:(NSString **)error {
    NSError *hashError = nil;
    NSString *hash = SHA256OfFile(rootfsPath, &hashError);
    if (!hash || ![hash isEqualToString:kOCGuestImageSHA256]) {
        if (error) *error = @"the guest image is damaged — reinstall";
        return NO;
    }
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:rootfsPath error:nil];
    if (attrs) [self recordVerifiedFingerprintForPath:rootfsPath attrs:attrs hash:hash];
    return YES;
}

// Streaming gunzip of src (.gz) to dst. Returns NO with *error set on
// failure; the caller checks the hashes. progress, when given, is
// called with the total bytes written so far (throttled by the
// caller); the extraction logs every 10% with bytes and footprint,
// so a kill mid-extraction leaves its exact position instead of
// silence. Stops cleanly when the background budget expires
// (s_extractionStopRequested, set by the install's expiration
// handler): a partial dst is deleted, the error says paused, and
// the verified .gz is kept so the next Install resumes at
// extraction instead of re-downloading.
+ (BOOL)gunzipFile:(NSString *)src to:(NSString *)dst progress:(void (^)(unsigned long long))progress error:(NSString **)error {
    gzFile gz = gzopen(src.UTF8String, "rb");
    if (!gz) {
        if (error) *error = @"could not open the downloaded archive";
        return NO;
    }
    FILE *out = fopen(dst.UTF8String, "wb");
    if (!out) {
        gzclose(gz);
        if (error) *error = @"could not write the guest image";
        return NO;
    }
    // 1 MiB stdio buffer, set before any I/O on the stream: the
    // default is the filesystem block size (4 KiB on APFS), which
    // turns a 4.46 GB extraction into ~1.1 M write() calls.
    setvbuf(out, NULL, _IOFBF, 1 << 20);
    // Heap buffer, never the stack: TermX's SIGBUS (commit d2b4f2e)
    // was a 1 MiB gunzip buffer on a 512 KiB GCD worker stack, so the
    // first gzread touched the guard page and died. 256 KiB heap.
    const size_t kGunzipBufferSize = 256 << 10;
    uint8_t *buffer = malloc(kGunzipBufferSize);
    if (!buffer) {
        fclose(out);
        gzclose(gz);
        if (error) *error = @"could not allocate the extraction buffer";
        return NO;
    }
    int n;
    BOOL ok = YES;
    BOOL stopped = NO;
    unsigned long long written = 0;
    while ((n = gzread(gz, buffer, (unsigned)kGunzipBufferSize)) > 0) {
        if (s_extractionStopRequested) { stopped = YES; ok = NO; break; }
        if (fwrite(buffer, 1, (size_t)n, out) != (size_t)n) { ok = NO; break; }
        written += (unsigned long long)n;
        if (progress) progress(written);
    }
    if (n < 0) ok = NO;
    free(buffer);
    fclose(out);
    gzclose(gz);
    if (!ok) {
        [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
        if (error) {
            *error = stopped ? @"Install paused — the verified archive is kept, tap Install to continue"
                             : @"the downloaded archive is corrupt";
        }
    }
    return ok;
}

+ (void)reconnectBackgroundSessionWithCompletionHandler:(void (^)(void))handler {
    [OCChunkedDownload reconnectBackgroundSessionWithCompletionHandler:handler];
}

+ (void)installGuestTo:(NSString *)rootfsPath
              progress:(void (^)(double, NSString *))progress
            completion:(void (^)(BOOL, NSString *))completion {
    // The installed check SHA-256s a 4.46 GB image: never on the main
    // thread (TermX 8c76d48). The whole install runs on a background
    // queue; progress and completion hop to the main queue themselves.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [self installGuestToOnQueue:rootfsPath progress:progress completion:completion];
    });
}

+ (void)installGuestToOnQueue:(NSString *)rootfsPath
                     progress:(void (^)(double, NSString *))progress
                   completion:(void (^)(BOOL, NSString *))completion {
    static BOOL s_installInProgress = NO;
    BOOL alreadyRunning = NO;
    @synchronized(self) {
        alreadyRunning = s_installInProgress;
        if (!alreadyRunning) s_installInProgress = YES;
    }
    if (alreadyRunning) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(NO, @"install already in progress");
        });
        return;
    }
    // Background-task assertion around the whole pipeline (TermX
    // 8c76d48): the hash/gunzip/verify steps take longer than a
    // background wake's budget, and a kill mid-pipeline used to leave
    // a partial image plus a fresh resume blob. Here there is no blob,
    // but verified chunks are still worth keeping: the assertion is
    // ended in finish, the single funnel every exit goes through.
    // The expiration handler stops the extraction cleanly instead
    // of leaving the app frozen mid-gunzip: see s_extractionStopRequested.
    s_extractionStopRequested = NO;
    __block UIBackgroundTaskIdentifier bgTask =
        [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
            // The background budget (~30 s) ran out mid-pipeline.
            // If the extraction is running, stop it cleanly here
            // instead of being frozen mid-gunzip and killed while
            // suspended with no log line: the gunzip loop checks
            // the flag per chunk, deletes the partial .new, and
            // the verified archive is kept, so the next Install
            // resumes at extraction instead of re-downloading.
            // Expiration only ends the assertion; the pipeline
            // keeps its verified chunks and the next Install
            // resumes from them.
            OCInstallLog(@"Background time expired during install — stopping cleanly, the verified archive is kept");
            s_extractionStopRequested = YES;
        }];
    void (^finish)(BOOL, NSString *) = ^(BOOL ok, NSString *error) {
        if (bgTask != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:bgTask];
            bgTask = UIBackgroundTaskInvalid;
        }
        @synchronized(self) { s_installInProgress = NO; }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(ok, error);
        });
    };

    // Skip only when the installed image is already this build's
    // release. An older valid image is NOT skipped: Install (and
    // Update) means "get the current image", and the pipeline swaps
    // it in only after the new one verifies. (TermX c2f4ed5.)
    if ([self installedImageIsCurrentReleaseAt:rootfsPath]) {
        finish(YES, nil);
        return;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *guestDir = [rootfsPath stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:guestDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *tmpDir = NSTemporaryDirectory();
    NSString *gzPath = [tmpDir stringByAppendingPathComponent:@"opencode-rootfs.ext4.gz"];
    unsigned long long gzSize = 0;
    for (NSInteger i = 0; i < kOCGuestImageChunkCount; i++) gzSize += (unsigned long long)kOCGuestImageChunkSizes[i];
    NSMutableArray<NSString *> *chunkPaths = [NSMutableArray arrayWithCapacity:(NSUInteger)kOCGuestImageChunkCount];
    for (NSInteger i = 0; i < kOCGuestImageChunkCount; i++) {
        [chunkPaths addObject:[tmpDir stringByAppendingPathComponent:kOCGuestImageChunkNames[i]]];
    }
    // The assembled .gz, once verified, is the resume point for the
    // whole install: a kill during extraction or verification must
    // cost a ~30 s re-extraction, never a 1.16 GB re-download. So
    // the archive is NOT deleted blindly here. If a verified .gz is
    // already on disk (a previous attempt got past assembly), the
    // download and the assembly are both skipped; if it is stale
    // or damaged it is deleted and the pipeline re-downloads.
    // (2026-11-25: the old code deleted the archive at install
    // start and the parts after assembly, so every kill during
    // extraction forced a full re-download — the crash loop.)
    BOOL haveVerifiedGz = FileHasSize(gzPath, (long long)gzSize) && FileHasHash(gzPath, kOCGuestImageGzSHA256);
    if (haveVerifiedGz) {
        OCInstallLog(@"Archive already downloaded and verified — skipping download and assembly");
        for (NSString *chunkPath in chunkPaths) {
            [fm removeItemAtPath:chunkPath error:nil];
            [fm removeItemAtPath:[chunkPath stringByAppendingString:@".resume"] error:nil];
        }
    } else {
        [fm removeItemAtPath:gzPath error:nil];
    }
    // The installed image is NOT deleted here: the pipeline
    // extracts to a side file and swaps it in only after the new
    // image is verified, so a failed or cancelled update leaves
    // the working image in place (see below).

    // Free-space gate (TermX Phase 1: a download that dies on a
    // full disk used to look like a network failure, and the user
    // was sent to check Wi-Fi). Peak disk use is the assembled .gz
    // plus the extracted image plus the old image (it stays until
    // the swap), plus margin. The parts are deleted after assembly,
    // so they do not add to the extraction peak. Fails cleanly with
    // the real numbers instead of dying mid-extraction.
    unsigned long long freeSpace = OCFreeSpaceAtPath(tmpDir);
    // The archive only needs downloading when it is not already
    // verified on disk (see above): its size is already counted
    // in freeSpace then, so it must not be added to the need.
    unsigned long long neededSpace = (haveVerifiedGz ? 0 : gzSize) + (unsigned long long)kOCGuestImageSize + (512ULL << 20);
    if ([fm fileExistsAtPath:rootfsPath]) neededSpace += (unsigned long long)kOCGuestImageSize;
    OCInstallLog([NSString stringWithFormat:@"Install: %@ free, %@ needed for the guest image",
                  OCFormatBytes(freeSpace), OCFormatBytes(neededSpace)]);
    if (freeSpace > 0 && freeSpace < neededSpace) {
        finish(NO, [NSString stringWithFormat:@"not enough free space — the install needs %@ free, this phone has %@",
                    OCFormatBytes(neededSpace), OCFormatBytes(freeSpace)]);
        return;
    }

    // Download each chunk in order. A chunk that is already on disk
    // with the right size and SHA-256 is kept: that is the resume.
    // Skipped entirely when a verified archive is already on disk
    // (haveVerifiedGz above): the loop condition keeps it from
    // running at all, and the assembly below is guarded the same way.
    for (NSInteger i = 0; i < kOCGuestImageChunkCount && !haveVerifiedGz; i++) {
        NSString *chunkPath = chunkPaths[(NSUInteger)i];
        if (FileHasSize(chunkPath, kOCGuestImageChunkSizes[i]) && FileHasHash(chunkPath, kOCGuestImageChunkSHA256[i])) {
            OCInstallLog([NSString stringWithFormat:@"Part %ld of %ld already downloaded and verified — keeping it",
                          (long)(i + 1), (long)kOCGuestImageChunkCount]);
            ReportProgress(progress, (double)i / (double)kOCGuestImageChunkCount * 0.6,
                           [NSString stringWithFormat:@"Part %ld of %ld already downloaded…", (long)(i + 1), (long)kOCGuestImageChunkCount]);
            continue;
        }
        [fm removeItemAtPath:chunkPath error:nil];
        NSString *chunkURL = [kOCGuestImageChunkBaseURL stringByAppendingString:chunkPath.lastPathComponent];
        BOOL chunkOK = NO;
        for (int attempt = 1; attempt <= 3 && !chunkOK; attempt++) {
            NSInteger chunkIndex = i;
            NSString *step = [NSString stringWithFormat:@"Downloading part %ld of %ld…", (long)(chunkIndex + 1), (long)kOCGuestImageChunkCount];
            OCInstallLog([NSString stringWithFormat:@"Downloading part %ld of %ld… (attempt %d)",
                          (long)(chunkIndex + 1), (long)kOCGuestImageChunkCount, attempt]);
            ReportProgress(progress, (double)chunkIndex / (double)kOCGuestImageChunkCount * 0.6, step);
            chunkOK = DownloadChunk(chunkURL, chunkPath, ^(double chunkFraction) {
                double overall = (double)chunkIndex + chunkFraction;
                ReportProgress(progress, overall / (double)kOCGuestImageChunkCount * 0.6, step);
            });
            if (chunkOK) {
                chunkOK = FileHasSize(chunkPath, kOCGuestImageChunkSizes[i]) && FileHasHash(chunkPath, kOCGuestImageChunkSHA256[i]);
                if (!chunkOK) {
                    OCInstallLog([NSString stringWithFormat:@"Part %ld of %ld failed verification — re-downloading it",
                                  (long)(i + 1), (long)kOCGuestImageChunkCount]);
                    [fm removeItemAtPath:chunkPath error:nil];
                } else {
                    OCInstallLog([NSString stringWithFormat:@"Part %ld of %ld downloaded and verified",
                                  (long)(i + 1), (long)kOCGuestImageChunkCount]);
                }
            }
        }
        if (!chunkOK) {
            finish(NO, [NSString stringWithFormat:@"could not download part %ld of %ld — check Wi-Fi and try again", (long)(i + 1), (long)kOCGuestImageChunkCount]);
            return;
        }
    }

    if (haveVerifiedGz) {
        ReportProgress(progress, 0.6, @"Archive ready…");
    } else {
        ReportProgress(progress, 0.6, @"Verifying the download…");
        if (!AssembleChunks(chunkPaths, gzPath) || !FileHasHash(gzPath, kOCGuestImageGzSHA256)) {
            [fm removeItemAtPath:gzPath error:nil];
            // The parts are kept (each passed its own SHA-256), so the next
            // Install only re-assembles instead of re-downloading.
            finish(NO, @"the download is damaged — try again");
            return;
        }
        // The .gz is verified: the parts are redundant now (a later
        // failure is in gunzip, where re-downloading is the correct
        // recovery anyway), so drop them before the 4.46 GB extraction
        // — that keeps the extraction peak at .gz + new image + old
        // image instead of adding 1.16 GB of parts to it.
        for (NSString *chunkPath in chunkPaths) {
            [fm removeItemAtPath:chunkPath error:nil];
            [fm removeItemAtPath:[chunkPath stringByAppendingString:@".resume"] error:nil];
        }
        OCInstallLog(@"Download verified — part files removed to free space for extraction");
    }
    ReportProgress(progress, 0.7, @"Extracting…");
    // Extract to a side file, not the live image: the installed
    // image keeps booting until the new one is verified, and a
    // failed update leaves it untouched instead of deleting a
    // working image and failing halfway (the 2026-11-23 lesson:
    // an update must never brick a setup that already works).
    // A stale .new from a killed earlier pipeline is dropped
    // first so a later free-space check stays honest.
    NSString *newPath = [rootfsPath stringByAppendingString:@".new"];
    [fm removeItemAtPath:newPath error:nil];
    OCInstallLog(@"Extracting the image — 4.46 GB, progress every 10%");
    __block NSInteger lastExtractLoggedPercent = 0;
    NSString *extractError = nil;
    if (![self gunzipFile:gzPath to:newPath progress:^(unsigned long long bytesWritten) {
        double f = (double)bytesWritten / (double)kOCGuestImageSize;
        NSInteger pct = (NSInteger)(f * 100.0);
        if (pct >= lastExtractLoggedPercent + 10) {
            lastExtractLoggedPercent = (pct / 10) * 10;
            OCInstallLog([NSString stringWithFormat:@"Extraction: %ld%% · %@ of %@ written · footprint %@",
                          (long)pct,
                          OCFormatBytes(bytesWritten),
                          OCFormatBytes((unsigned long long)kOCGuestImageSize),
                          OCFormatBytes(OCCurrentFootprintBytes())]);
            ReportProgress(progress, 0.7 + f * 0.25, @"Extracting…");
        }
    } error:&extractError]) {
        finish(NO, extractError);
        return;
    }
    OCInstallLog(@"Extraction finished — verifying the image…");
    // The verified .gz is NOT deleted here any more: it stays
    // until the swap below succeeds, so a kill during the verify
    // or the swap costs a re-extraction, never a re-download.
    ReportProgress(progress, 0.95, @"Verifying…");
    // The pipeline's own one-time verify, not guestInstalledAt:
    // the just-extracted file still carries write bits until the
    // chmod below, and guestInstalledAt treats that as unverified.
    NSString *verifyError = nil;
    if (![self guestImageHashValidAt:newPath error:&verifyError]) {
        [fm removeItemAtPath:newPath error:nil];
        finish(NO, verifyError ?: @"image verification failed");
        return;
    }
    // The runtime requires a read-only image: no write bits at all.
    NSDictionary *attrs = @{NSFilePosixPermissions : @(0444)};
    [fm setAttributes:attrs ofItemAtPath:newPath error:nil];
    // Swap only now that the new image is verified: the old image
    // is removed and the new one moved into its place (same
    // directory, so the move is a rename). The fingerprint was
    // recorded for the .new path by the verify above; re-record
    // it for the final path with the known-good hash, so the
    // cheap installed check answers from it from now on.
    [fm removeItemAtPath:rootfsPath error:nil];
    NSError *swapError = nil;
    if (![fm moveItemAtPath:newPath toPath:rootfsPath error:&swapError]) {
        [fm removeItemAtPath:newPath error:nil];
        finish(NO, @"could not install the new image — the old image is still in place");
        return;
    }
    NSDictionary *finalAttrs = [fm attributesOfItemAtPath:rootfsPath error:nil];
    if (finalAttrs) [self recordVerifiedFingerprintForPath:rootfsPath attrs:finalAttrs hash:kOCGuestImageSHA256];
    // Only now, with the new image swapped in and fingerprinted,
    // is the archive redundant: delete it.
    [fm removeItemAtPath:gzPath error:nil];
    OCInstallLog(@"Install complete — guest image ready");
    ReportProgress(progress, 1.0, @"Ready");
    finish(YES, nil);
}

@end
