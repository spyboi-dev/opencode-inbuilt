// OCGuestInstall - see OCGuestInstall.h.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "OCGuestInstall.h"
#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIKit.h>
#import <zlib.h>

// Guest image published 2026-11-21 as release rootfs-20261120
// (opencode-debian-trixie-arm64.ext4.gz, 1,159,150,314 bytes).
// Hashes from rootfs-build/SHA256SUMS. The app refuses an image whose
// hash does not match.
//
// Chunked delivery: the 1.16 GB .gz is split into 12 ~100 MiB parts
// (rootfs-build/CHUNKS-SHA256SUMS). The app downloads each part,
// verifies its SHA-256, and only then reassembles the .gz and verifies
// the whole archive hash. A part that fails verification is deleted
// and re-downloaded; already-verified parts are kept, so a killed
// Install resumes at the first missing part instead of restarting
// from zero.
//
// No NSURLSession resume data is used anywhere in this file, by
// design: TermX's resume fix (commit 8c76d48) showed that
// downloadTaskWithResumeData: THROWS NSInvalidArgumentException on a
// stale blob instead of returning nil, so a stale resume file made
// every Install tap crash in under a second. Per-part resume (keep
// verified parts, re-download only the failed one) gives the same
// benefit with no blob that can go stale. Task creation is still
// wrapped in @try/@catch, and the whole install runs on a background
// queue: the installed check SHA-256s a 4.46 GB image and must never
// run on the main thread.
NSString *const kOCGuestImageChunkBaseURL =
    @"https://github.com/spyboi-dev/opencode-inbuilt/releases/download/rootfs-20261120/";
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

static NSString *SHA256OfFile(NSString *path, NSError **outError) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) {
        if (outError) *outError = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileReadNoSuchFileError userInfo:nil];
        return nil;
    }
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    while (YES) {
        NSData *chunk = [handle readDataOfLength:1 << 20];
        if (chunk.length == 0) break;
        CC_SHA256_Update(&ctx, chunk.bytes, (CC_LONG)chunk.length);
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
    return attrs && [attrs fileSize] == expected;
}

// Progress is always reported on the main queue (the interface
// contract in OCGuestInstall.h); the install itself runs on a
// background queue.
static void ReportProgress(void (^progress)(double, NSString *), double fraction, NSString *step) {
    if (!progress) return;
    dispatch_async(dispatch_get_main_queue(), ^{ progress(fraction, step); });
}

// Downloads one chunk to dstPath. Returns YES when the file is in
// place. Reports this chunk's 0..1 progress via progressBlock. Task
// creation is wrapped in @try/@catch (TermX 8c76d48: session calls can
// throw); a nil task or an error is a clean NO, never a crash. No
// resume data is used: a failed chunk is simply re-downloaded.
static BOOL DownloadChunk(NSString *urlString, NSString *dstPath, void (^progressBlock)(double)) {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return NO;
    __block BOOL ok = NO;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURLSessionDownloadTask *task = nil;
    @try {
        task = [[NSURLSession sharedSession] downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
            (void)response;
            if (!error && location) {
                NSFileManager *fm = [NSFileManager defaultManager];
                [fm removeItemAtPath:dstPath error:nil];
                NSError *moveError = nil;
                ok = [fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:dstPath] error:&moveError];
            }
            dispatch_semaphore_signal(done);
        }];
    } @catch (NSException *exception) {
        return NO;
    }
    if (!task) return NO;
    [task resume];
    // Wait for the handler, polling byte counts for progress.
    while (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)))) {
        int64_t received = task.countOfBytesReceived;
        int64_t expected = task.countOfBytesExpectedToReceive;
        if (progressBlock && expected > 0) progressBlock((double)received / (double)expected);
    }
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
            NSData *data = [in readDataOfLength:1 << 20];
            if (data.length == 0) break;
            @try {
                [out writeData:data];
            } @catch (NSException *exception) {
                ok = NO;
                break;
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

@end

@implementation OCGuestInstall

+ (BOOL)guestInstalledAt:(NSString *)rootfsPath error:(NSString **)error {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *attrs = [fm attributesOfItemAtPath:rootfsPath error:nil];
    if (!attrs) {
        if (error) *error = @"guest image is not installed";
        return NO;
    }
    if (kOCGuestImageSize > 0 && [attrs fileSize] != kOCGuestImageSize) {
        if (error) *error = @"guest image has the wrong size — reinstall";
        return NO;
    }
    if (!FileHasHash(rootfsPath, kOCGuestImageSHA256)) {
        if (error) *error = @"guest image hash mismatch — reinstall";
        return NO;
    }
    return YES;
}

// Streaming gunzip of src (.gz) to dst. Returns NO with *error set on
// failure; the caller checks the hashes.
+ (BOOL)gunzipFile:(NSString *)src to:(NSString *)dst error:(NSString **)error {
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
    while ((n = gzread(gz, buffer, (unsigned)kGunzipBufferSize)) > 0) {
        if (fwrite(buffer, 1, (size_t)n, out) != (size_t)n) { ok = NO; break; }
    }
    if (n < 0) ok = NO;
    free(buffer);
    fclose(out);
    gzclose(gz);
    if (!ok) {
        [[NSFileManager defaultManager] removeItemAtPath:dst error:nil];
        if (error) *error = @"the downloaded archive is corrupt";
    }
    return ok;
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
    __block UIBackgroundTaskIdentifier bgTask =
        [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:^{
            // Expiration only ends the assertion; the pipeline keeps
            // its verified chunks and the next Install resumes from
            // them.
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

    NSString *error = nil;
    if ([self guestInstalledAt:rootfsPath error:&error]) {
        finish(YES, nil);
        return;
    }
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *guestDir = [rootfsPath stringByDeletingLastPathComponent];
    [fm createDirectoryAtPath:guestDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *tmpDir = NSTemporaryDirectory();
    NSString *gzPath = [tmpDir stringByAppendingPathComponent:@"opencode-rootfs.ext4.gz"];
    [fm removeItemAtPath:gzPath error:nil];
    [fm removeItemAtPath:rootfsPath error:nil];

    // Download each chunk in order. A chunk that is already on disk
    // with the right size and SHA-256 is kept: that is the resume.
    NSMutableArray<NSString *> *chunkPaths = [NSMutableArray arrayWithCapacity:(NSUInteger)kOCGuestImageChunkCount];
    for (NSInteger i = 0; i < kOCGuestImageChunkCount; i++) {
        NSString *name = kOCGuestImageChunkNames[i];
        NSString *chunkPath = [tmpDir stringByAppendingPathComponent:name];
        [chunkPaths addObject:chunkPath];
        if (FileHasSize(chunkPath, kOCGuestImageChunkSizes[i]) && FileHasHash(chunkPath, kOCGuestImageChunkSHA256[i])) {
            ReportProgress(progress, (double)i / (double)kOCGuestImageChunkCount * 0.6,
                           [NSString stringWithFormat:@"Part %ld of %ld already downloaded…", (long)(i + 1), (long)kOCGuestImageChunkCount]);
            continue;
        }
        [fm removeItemAtPath:chunkPath error:nil];
        NSString *chunkURL = [kOCGuestImageChunkBaseURL stringByAppendingString:name];
        BOOL chunkOK = NO;
        for (int attempt = 1; attempt <= 3 && !chunkOK; attempt++) {
            NSInteger chunkIndex = i;
            NSString *step = [NSString stringWithFormat:@"Downloading guest image part %ld of %ld…", (long)(chunkIndex + 1), (long)kOCGuestImageChunkCount];
            ReportProgress(progress, (double)chunkIndex / (double)kOCGuestImageChunkCount * 0.6, step);
            chunkOK = DownloadChunk(chunkURL, chunkPath, ^(double chunkFraction) {
                double overall = (double)chunkIndex + chunkFraction;
                ReportProgress(progress, overall / (double)kOCGuestImageChunkCount * 0.6, step);
            });
            if (chunkOK) {
                chunkOK = FileHasSize(chunkPath, kOCGuestImageChunkSizes[i]) && FileHasHash(chunkPath, kOCGuestImageChunkSHA256[i]);
                if (!chunkOK) [fm removeItemAtPath:chunkPath error:nil];
            }
        }
        if (!chunkOK) {
            finish(NO, [NSString stringWithFormat:@"could not download part %ld of %ld — check Wi-Fi and try again", (long)(i + 1), (long)kOCGuestImageChunkCount]);
            return;
        }
    }

    ReportProgress(progress, 0.6, @"Verifying the download…");
    if (!AssembleChunks(chunkPaths, gzPath) || !FileHasHash(gzPath, kOCGuestImageGzSHA256)) {
        [fm removeItemAtPath:gzPath error:nil];
        // The parts are kept (each passed its own SHA-256), so the next
        // Install only re-assembles instead of re-downloading.
        finish(NO, @"download hash mismatch — the parts may be corrupt, try again");
        return;
    }
    ReportProgress(progress, 0.7, @"Extracting the image…");
    NSString *extractError = nil;
    if (![self gunzipFile:gzPath to:rootfsPath error:&extractError]) {
        finish(NO, extractError);
        return;
    }
    [fm removeItemAtPath:gzPath error:nil];
    ReportProgress(progress, 0.95, @"Verifying the image…");
    NSString *verifyError = nil;
    if (![self guestInstalledAt:rootfsPath error:&verifyError]) {
        [fm removeItemAtPath:rootfsPath error:nil];
        finish(NO, verifyError ?: @"image verification failed");
        return;
    }
    // The runtime requires a read-only image: no write bits at all.
    NSDictionary *attrs = @{NSFilePosixPermissions : @(0444)};
    [fm setAttributes:attrs ofItemAtPath:rootfsPath error:nil];
    ReportProgress(progress, 1.0, @"Guest ready");
    finish(YES, nil);
}

@end
