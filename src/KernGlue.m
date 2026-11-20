// OCKernGlue - see KernGlue.h.
// SPDX-License-Identifier: GPL-2.0-or-later
#import "KernGlue.h"
#import "KernariumRuntime.h"
#import "OCEngine.h"
#import "OCGuestInstall.h"
#import "OCVsockBridge.h"
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <errno.h>

// Local typedef: the header declares the getter as a plain function,
// not as a function-pointer type.
typedef const kernarium_runtime_api *(*OCKernariumGetApi)(void);

// The Linux guest: 1024 MiB RAM and 2 vCPUs, as in TermX. Enough for
// a shell plus the OpenCode server, and leaves the process headroom
// the runtime's GPU budget wants.
static const uint32_t kGuestMemoryMiB = 1024;
static const uint32_t kGuestCPUs = 2;
// Writable space for one session, in GiB. The boot formats the overlay
// fresh every time, so this is session scratch, not storage.
static const uint64_t kOverlayGiB = 4;
static const NSUInteger kConsoleChunkBytes = 512;

static NSString *const kGlueErrorDomain = @"OCKernGlue";

static NSError *GlueError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:kGlueErrorDomain code:code
                         userInfo:@{NSLocalizedDescriptionKey: message ?: @"Guest failed"}];
}

// Forward declaration: the C console callback below runs before the
// class extension is visible in this file.
@interface OCKernGlue (ConsoleForward)
- (void)handleConsoleData:(NSData *)data;
@end

static void ConsoleOutput(void *context, const void *buffer, size_t length) {
    OCKernGlue *glue = (__bridge OCKernGlue *)context;
    if (!glue) return;
    NSData *data = [NSData dataWithBytes:buffer length:length];
    [glue handleConsoleData:data];
}

@interface OCKernGlue () {
    const kernarium_runtime_api *_api;
    BOOL _running;
    BOOL _booted;
    BOOL _booting;
    BOOL _hostRequestedStop;
    // Held for the whole run: the boot struct hands the runtime C
    // strings, and they must stay alive until run() returns. The
    // boot struct itself is an ivar for the same reason: run() runs
    // on a background thread after this method has returned, so a
    // stack-local struct would be gone by the time it is read.
    kernarium_runtime_boot _boot;
    NSString *_rootfsPath;
    NSString *_overlayPath;
    NSString *_sessionRecordPath;
    MTKView *_guestView;
    NSMutableArray<void (^)(BOOL, NSError * _Nullable)> *_bootWaiters;
    OCVsockBridge *_serverBridge;
    OCVsockBridge *_appBridge;
    dispatch_queue_t _consoleQueue;
}
- (void)handleConsoleData:(NSData *)data;
- (void)startBridges;
- (void)stopBridges;
@end

@implementation OCKernGlue

+ (instancetype)shared {
    static OCKernGlue *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[OCKernGlue alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _bootWaiters = [NSMutableArray array];
        _consoleQueue = dispatch_queue_create("com.spyboy.opencode.kernConsole", DISPATCH_QUEUE_SERIAL);
        // The runtime framework is deliberately NOT loaded here.
        // dlopen runs the framework's static initializers, and one
        // that dies under LiveContainer would kill the launch before
        // any screen appears. It loads on the first real Start
        // (ensureRuntimeLoaded), never at app launch; until then
        // _api is NULL and the engine honestly reports not-ready.
        [[OCEngine shared] appendEngineLogSync:@"Kernarium runtime load deferred until first Start"];
    }
    return self;
}

// Load the runtime framework on demand (first Start), and install
// the guest executor once it is up. Safe to call again: a loaded
// runtime returns YES at once. A failed load logs the exact reason
// (loadRuntime) and returns NO; the caller reports it honestly and
// never boots. Must not be called at app launch.
- (BOOL)ensureRuntimeLoaded {
    if (_api) return YES;
    _api = [self loadRuntime];
    if (!_api) return NO;
    [self installGuestExecutor];
    return YES;
}

// The framework is linked into the Mac-built IPA only, so resolve it
// at run time instead of linking the symbol: the Linux build (which
// has no framework) still compiles and links, and a build without
// the framework fails honestly at this point instead of at launch.
- (const kernarium_runtime_api *)loadRuntime {
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *frameworkBinary = [[bundle pathForResource:@"KRuntime_6_18_4K" ofType:@"framework"]
        stringByAppendingPathComponent:@"KRuntime_6_18_4K"];
    if (!frameworkBinary.length) {
        // LiveContainer and other hosts can move the bundle: fall
        // back to the executable-relative Frameworks directory.
        NSString *exeDir = [[bundle executablePath] stringByDeletingLastPathComponent];
        frameworkBinary = [[[exeDir stringByAppendingPathComponent:@"Frameworks"]
            stringByAppendingPathComponent:@"KRuntime_6_18_4K.framework"]
            stringByAppendingPathComponent:@"KRuntime_6_18_4K"];
    }
    if (!frameworkBinary.length) {
        [[OCEngine shared] appendEngineLogSync:@"Kernarium runtime did not load: framework path not found in bundle"];
        return NULL;
    }
    if (![[NSFileManager defaultManager] fileExistsAtPath:frameworkBinary]) {
        [[OCEngine shared] appendEngineLogSync:@"Kernarium runtime did not load: KRuntime_6_18_4K.framework is not in this build"];
        return NULL;
    }
    void *handle = dlopen(frameworkBinary.UTF8String, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        const char *err = dlerror();
        [[OCEngine shared] appendEngineLogSync:[NSString stringWithFormat:@"Kernarium runtime did not load: dlopen failed: %s", err ? err : "unknown error"]];
        return NULL;
    }
    OCKernariumGetApi getApi =
        (OCKernariumGetApi)dlsym(handle, "kernarium_runtime_get_api_v28");
    if (!getApi) {
        [[OCEngine shared] appendEngineLogSync:@"Kernarium runtime did not load: kernarium_runtime_get_api_v28 not found in framework"];
        return NULL;
    }
    const kernarium_runtime_api *api = getApi();
    if (!api || api->abi_version != KERNARIUM_RUNTIME_API_VERSION) {
        [[OCEngine shared] appendEngineLogSync:[NSString stringWithFormat:@"Kernarium runtime did not load: ABI version mismatch (got %u, want %u)", api ? (unsigned)api->abi_version : 0, (unsigned)KERNARIUM_RUNTIME_API_VERSION]];
        return NULL;
    }
    [[OCEngine shared] appendEngineLogSync:@"Kernarium runtime loaded"];
    return api;
}

- (BOOL)runtimeLoaded { return _api != NULL; }
- (BOOL)booted { return _booted; }

- (NSString *)guestDirectory {
    return [[[OCEngine shared] engineDirectory] stringByAppendingPathComponent:@"guest"];
}

- (NSString *)guestImagePath {
    return [[self guestDirectory] stringByAppendingPathComponent:kOCGuestImageName];
}

- (MTKView *)guestView {
    if (!_guestView) {
        // run() refuses a null view: the guest framebuffer needs a
        // Metal view even though this app never shows it. The view
        // is full-screen and lives behind the tab bar.
        _guestView = [[MTKView alloc] initWithFrame:[UIScreen mainScreen].bounds];
        _guestView.hidden = NO;
    }
    return _guestView;
}

- (void)installGuestExecutor {
    if (!_api) {
        [[OCEngine shared] appendEngineLogSync:@"Guest executor not installed: Kernarium runtime did not load"];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [OCEngine shared].guestExecutor = ^(NSString *command, NSString *workingDirectory,
                                        void (^completion)(NSString * _Nullable, NSInteger)) {
        (void)workingDirectory;
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_booted) {
            if (completion) completion(nil, 1);
            return;
        }
        // Console send, not process spawn: there is no exit code to
        // report. The ack means "typed at the console", nothing more.
        [strongSelf sendConsoleText:command];
        if (completion) completion(@"", 0);
    };
    [[OCEngine shared] appendEngineLogSync:@"Guest executor installed (Kernarium console)"];
}

// Create the sparse overlay file the boot formats fresh on ubd1.
// The path must name no spaces, quotes, commas or colons (the runtime
// names it on the kernel command line); NSTemporaryDirectory is safe.
- (BOOL)createOverlayWithError:(NSString **)error {
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"opencode-overlay.ext4"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:path error:nil];
    int fd = open(path.UTF8String, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) {
        if (error) *error = @"could not create the overlay disk";
        return NO;
    }
    off_t size = (off_t)kOverlayGiB << 30;
    BOOL ok = ftruncate(fd, size) == 0;
    close(fd);
    if (!ok && error) *error = @"could not size the overlay disk";
    _overlayPath = path;
    return ok;
}

- (void)finishBootWithSuccess:(BOOL)ok error:(nullable NSError *)error {
    NSArray<void (^)(BOOL, NSError * _Nullable)> *waiters = [_bootWaiters copy];
    [_bootWaiters removeAllObjects];
    _booting = NO;
    dispatch_async(dispatch_get_main_queue(), ^{
        for (void (^w)(BOOL, NSError * _Nullable) in waiters) w(ok, error);
    });
}

- (void)bootWithCompletion:(void (^)(BOOL, NSError * _Nullable))completion {
    if (_booted) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(YES, nil); });
        return;
    }
    if (completion) [_bootWaiters addObject:[completion copy]];
    if (_booting) return;
    if (!_api && ![self ensureRuntimeLoaded]) {
        [self finishBootWithSuccess:NO error:GlueError(1, @"The Kernarium runtime framework did not load in this build")];
        return;
    }
    NSString *installError = nil;
    if (![OCGuestInstall guestInstalledAt:[self guestImagePath] error:&installError]) {
        [self finishBootWithSuccess:NO error:GlueError(2, installError ?: @"Guest image is not installed — run first-launch setup first")];
        return;
    }
    NSString *overlayError = nil;
    if (![self createOverlayWithError:&overlayError]) {
        [self finishBootWithSuccess:NO error:GlueError(3, overlayError ?: @"Could not create the overlay disk")];
        return;
    }
    _booting = YES;
    _hostRequestedStop = NO;
    // The bridge claims 127.0.0.1:4096 before the guest boots, so
    // health checks fail fast with connection-refused instead of
    // hanging while the server is not up yet.
    [self startBridges];
    // Memory check first: the runtime says whether the process is
    // likely to be killed for the guest size we ask for.
    kernarium_runtime_gpu_budget budget;
    memset(&budget, 0, sizeof(budget));
    budget.struct_size = (uint32_t)sizeof(budget);
    if (_api->plan_gpu_budget) {
        _api->plan_gpu_budget(kGuestMemoryMiB, kGuestCPUs, 0, 0, 0, &budget);
        if (budget.short_of_floor) {
            [[OCEngine shared] appendEngineLogSync:@"Warning: low memory headroom for the guest — booting anyway"];
        }
    }
    _api->set_console_output_callback(ConsoleOutput, (__bridge void *)self);
    MTKView *view = self.guestView;
    // The guest framebuffer view is created and parked here, on the
    // first real boot — never at app launch. run() needs a valid
    // Metal view, and parking it behind the tab bar keeps the same
    // end state the launch-time park used to produce, just later.
    // bootWithCompletion runs on the main thread, so this UIKit
    // work is on the right thread.
    [self parkGuestView];
    CGFloat scale = [UIScreen mainScreen].scale;
    _rootfsPath = [self guestImagePath];
    _sessionRecordPath = [[self guestDirectory] stringByAppendingPathComponent:@"session.json"];
    memset(&_boot, 0, sizeof(_boot));
    _boot.struct_size = (uint32_t)sizeof(_boot);
    _boot.width = (uint32_t)(view.bounds.size.width * scale);
    _boot.height = (uint32_t)(view.bounds.size.height * scale);
    _boot.dots_per_inch = 160;
    _boot.guest_memory_mib = kGuestMemoryMiB;
    _boot.guest_processor_count = kGuestCPUs;
    _boot.rootfs_path = _rootfsPath.UTF8String;
    _boot.overlay_path = _overlayPath.UTF8String;
    _boot.session_record_path = _sessionRecordPath.UTF8String;
    _boot.use_jit = 0; // gadget (interpreter) engine: no JIT, no debugger
    _running = YES;
    [[OCEngine shared] appendEngineLogSync:@"Guest boot started (Kernarium, Debian 13)"];
    // run() blocks until the guest stops, so it owns its own thread.
    // The boot struct lives in an ivar (see above); the C strings
    // point into NSStrings this object holds, so every pointer stays
    // valid until run() returns.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        int result = strongSelf->_api->run(view, &strongSelf->_boot);
        strongSelf->_running = NO;
        strongSelf->_booted = NO;
        [strongSelf stopBridges];
        if (result == 0) {
            [[OCEngine shared] appendEngineLogSync:@"Guest powered off"];
            [strongSelf finishBootWithSuccess:NO error:GlueError(4, @"Guest powered off")];
        } else if (result == KERNARIUM_RUNTIME_RESULT_RESTART_LOOP) {
            [strongSelf finishBootWithSuccess:NO error:GlueError(5, @"Guest kept restarting — see the console log")];
        } else if (strongSelf->_hostRequestedStop) {
            // A host stop returns an error from run(), not 0. That
            // is a clean stop, not a failure.
            [[OCEngine shared] appendEngineLogSync:@"Guest stopped by the app"];
            [strongSelf finishBootWithSuccess:NO error:GlueError(6, @"Guest stopped")];
        } else {
            [[OCEngine shared] appendEngineLogSync:[NSString stringWithFormat:@"Guest run failed (%d)", result]];
            [strongSelf finishBootWithSuccess:NO error:GlueError(7, [NSString stringWithFormat:@"Guest run failed (%d)", result])];
        }
    });
}

- (void)startBridges {
    if (!_api) return;
    __weak typeof(self) weakSelf = self;
    OCVsockConnectBlock connect = ^int(uint32_t port, uint32_t timeoutMs) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_api || !strongSelf->_api->connect_vsock) return -ENODEV;
        return strongSelf->_api->connect_vsock(port, timeoutMs);
    };
    _serverBridge = [[OCVsockBridge alloc] initWithConnectVsock:connect];
    NSError *error = nil;
    if (![_serverBridge startOnLocalPort:4096 vsockPort:4096 error:&error]) {
        [[OCEngine shared] appendEngineLogSync:[NSString stringWithFormat:@"Server bridge failed: %@", error.localizedDescription]];
    }
    _appBridge = [[OCVsockBridge alloc] initWithConnectVsock:connect];
    if (![_appBridge startOnLocalPort:8000 vsockPort:8000 error:&error]) {
        [[OCEngine shared] appendEngineLogSync:[NSString stringWithFormat:@"App bridge failed: %@", error.localizedDescription]];
    }
}

- (void)stopBridges {
    [_serverBridge stop];
    _serverBridge = nil;
    [_appBridge stop];
    _appBridge = nil;
}

- (void)sendConsoleText:(NSString *)text {
    if (!_api || !_running || !text.length) return;
    NSString *line = [text hasSuffix:@"\n"] ? text : [text stringByAppendingString:@"\n"];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) return;
    // Small chunks on a serial queue: a long bootstrap typed at once
    // can overflow the tty input buffer and lose its tail.
    __weak typeof(self) weakSelf = self;
    dispatch_async(_consoleQueue, ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_running) return;
        NSUInteger offset = 0;
        while (offset < data.length) {
            NSUInteger chunk = MIN(kConsoleChunkBytes, data.length - offset);
            NSData *part = [data subdataWithRange:NSMakeRange(offset, chunk)];
            (void)strongSelf->_api->send_console_input(part.bytes, part.length);
            offset += chunk;
            if (offset < data.length) [NSThread sleepForTimeInterval:0.05];
        }
    });
}

- (void)handleConsoleData:(NSData *)data {
    if (!data.length) return;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) return;
    // The bootstrap types the password with echo off, so it should
    // never appear here — but redact it anyway before anything is
    // logged or parsed.
    NSString *redact = self.consoleRedactString;
    if (redact.length && [text containsString:redact]) {
        text = [text stringByReplacingOccurrencesOfString:redact withString:@"****"];
    }
    if ([text containsString:@"UML_BOOT_ERROR:"]) {
        [[OCEngine shared] appendEngineLogSync:[NSString stringWithFormat:@"Guest boot error: %@", text]];
        [self finishBootWithSuccess:NO error:GlueError(8, @"Guest boot failed — see the console log")];
        return;
    }
    if (_booting && !_booted) {
        if ([text containsString:@"UML_BOOT_SWITCH_ROOT:/sbin/init"]) {
            [[OCEngine shared] appendEngineLogSync:@"Guest init running — waiting for the login prompt"];
        }
        // A Linux guest has no boot_completed signal: "up" is the
        // `login: ` prompt on the console.
        if ([text containsString:@"login: "]) {
            _booted = YES;
            [[OCEngine shared] appendEngineLogSync:@"Guest up (login prompt seen)"];
            [self finishBootWithSuccess:YES error:nil];
        }
    }
    [[OCEngine shared] handleGuestConsoleText:text];
}

- (void)stopGuest {
    if (!_api || !_running) {
        [self stopBridges];
        return;
    }
    _hostRequestedStop = YES;
    _booted = NO;
    // Settle first, best effort, off the main thread: ask the guest
    // to write its filesystems back before it is stopped. This only
    // flushes the overlay file; nothing survives the next boot.
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_api) return;
        if (strongSelf->_api->sync) {
            kernarium_runtime_settle settle;
            memset(&settle, 0, sizeof(settle));
            settle.struct_size = (uint32_t)sizeof(settle);
            (void)strongSelf->_api->sync(&settle);
        }
        if (strongSelf->_api->request_stop) strongSelf->_api->request_stop();
        [strongSelf stopBridges];
    });
}

- (void)syncGuestWithCompletion:(void (^)(BOOL))completion {
    if (!_api || !_running || !_api->sync) {
        if (completion) completion(NO);
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_api || !strongSelf->_api->sync) {
            if (completion) completion(NO);
            return;
        }
        kernarium_runtime_settle settle;
        memset(&settle, 0, sizeof(settle));
        settle.struct_size = (uint32_t)sizeof(settle);
        (void)strongSelf->_api->sync(&settle);
        BOOL confirmed = settle.guest_storage == KERNARIUM_RUNTIME_GUEST_STORAGE_CONFIRMED;
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(confirmed); });
    });
}

- (void)setGpuHold:(BOOL)held {
    if (!_api || !_running || !_api->set_gpu_hold) return;
    (void)_api->set_gpu_hold(held ? 1 : 0);
}

- (void)sendTouchSlot:(uint32_t)slot x:(uint32_t)x y:(uint32_t)y pressed:(BOOL)pressed {
    if (!_api || !_running || !_api->send_touch) return;
    _api->send_touch(slot, x, y, pressed ? 1 : 0);
}

- (void)sendKeyCode:(uint16_t)code pressed:(BOOL)pressed {
    if (!_api || !_running || !_api->send_key) return;
    _api->send_key(code, pressed ? 1 : 0);
}

- (void)sendKeyboardUsage:(uint32_t)usage pressed:(BOOL)pressed {
    if (!_api || !_running || !_api->send_keyboard_usage) return;
    (void)_api->send_keyboard_usage(usage, pressed ? 1 : 0);
}

- (void)parkGuestView {
    MTKView *view = self.guestView;
    if (!view) return;
    UIWindow *window = [UIApplication sharedApplication].keyWindow;
    if (!window) window = [UIApplication sharedApplication].windows.firstObject;
    if (!window) return;
    view.frame = window.bounds;
    [window insertSubview:view atIndex:0];
}

@end
