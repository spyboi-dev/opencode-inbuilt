// OCCoreGlue - minimal ObjC boot glue for the embedded LinuxRunner core.
// See CoreGlue.h for the design. Every core function used here was
// verified by reading the LinuxRunner 1.1.2 sources (commit f96a2a6f);
// anything that could not be verified is marked UNVERIFIED below.
#import "CoreGlue.h"
#import "OCEngine.h"

#import <resolv.h>
#import <netdb.h>
#import <string.h>
#import <unistd.h>

#define ISH_INTERNAL
#include "fs/fake.h"      // fakefs_bind_mount (needs ISH_INTERNAL)
#include "fs/tty.h"       // pty_open_fake, tty_release, struct tty_driver
#include "fs/devices.h"   // TTY_*_MAJOR, DEV_*_MINOR
#include "fs/dev.h"       // dev_make
#include "fs/fd.h"        // struct fd, fd_close
#include "fs/sock.h"      // sock_tmp_prefix
#include "fs/path.h"      // AT_PWD
#include "kernel/fs.h"    // fakefs, do_mount, generic_*, procfs/sysfs/devptsfs
#include "kernel/init.h"  // mount_root, become_first_process, create_stdio, ...
#include "kernel/calls.h" // do_execve
#include "kernel/task.h"  // task_start, task_discard_unstarted, current, exit_hook
#include "kernel/errno.h" // _EEXIST and the other guest errnos
#include "misc.h"         // IS_ERR
#include "debug.h"        // die_handler
#include "tools/fakefs.h" // fakefs_import
#include "app/LinuxRunner/DebianBootstrap.h" // lr_debian_bootstrap

static NSString *const kGlueErrorDomain = @"OCCoreGlue";
static NSString *const kGuestRootName = @"root";
static NSString *const kExchangeName = @"exchange";
static NSString *const kRootTarName = @"debian-root.tar.gz";
static NSString *const kBootInitPath = @"/usr/lib/linuxrunner/init.sh";
static const NSTimeInterval kSpawnAckGraceSeconds = 1.0; // see CoreGlue.h

// ---------------------------------------------------------------------------
// Per-command guest run. All fields except `output` are touched only on
// the glue's serial queue; `output` is appended from the tty write
// callback, which runs on the guest task's host thread, so it has its
// own lock.
// ---------------------------------------------------------------------------
@class OCGuestRun;

@interface OCCoreGlue ()
@property (nonatomic, strong) dispatch_queue_t serialQueue;
@property (nonatomic, assign) BOOL bootedFlag;
@property (nonatomic, assign) BOOL bootInProgress;
@property (nonatomic, strong) NSMutableArray<void (^)(BOOL, NSError * _Nullable)> *pendingBootCompletions;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, OCGuestRun *> *runsByPid;
- (void)handleGuestExit:(pid_t)pid code:(int)code;
@end

@interface OCGuestRun : NSObject
@property (nonatomic, assign) pid_t pid;
@property (nonatomic, strong) NSMutableData *output;
@property (nonatomic, strong) NSLock *outputLock;
@property (nonatomic, copy, nullable) void (^completion)(NSString * _Nullable output, NSInteger exitCode);
@property (nonatomic, assign) BOOL exited;
@property (nonatomic, assign) NSInteger exitCode;
@property (nonatomic, assign) BOOL acknowledged; // completion already fired
@property (nonatomic, assign) struct tty *tty;   // master side; kernel-owned
- (void)appendOutput:(const void *)buf length:(size_t)len;
- (NSString *)outputString;
@end

@implementation OCGuestRun
- (instancetype)init {
    if ((self = [super init])) {
        _output = [NSMutableData data];
        _outputLock = [[NSLock alloc] init];
        _exitCode = -1;
    }
    return self;
}
- (void)appendOutput:(const void *)buf length:(size_t)len {
    if (!buf || !len) return;
    [self.outputLock lock];
    [self.output appendBytes:buf length:len];
    [self.outputLock unlock];
}
- (NSString *)outputString {
    [self.outputLock lock];
    NSData *data = [self.output copy];
    [self.outputLock unlock];
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!s) s = [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    return s ?: @"";
}
@end

// ---------------------------------------------------------------------------
// TTY drivers. The pty driver feeds guest output into the run's buffer;
// the console driver discards init's console output (init.sh logs to
// /var/log/linuxrunner-initialize.log inside the guest instead).
// fs/tty.c null-checks init/cleanup but NOT write, so write must exist.
// ---------------------------------------------------------------------------
static int oc_pty_write(struct tty *tty, const void *buf, size_t len, bool blocking) {
    (void)blocking;
    OCGuestRun *run = (__bridge OCGuestRun *)tty->data;
    if (run) [run appendOutput:buf length:len];
    return (int)len;
}
static void oc_pty_cleanup(struct tty *tty) { tty->data = NULL; }
static const struct tty_driver_ops oc_pty_ops = {
    .init = NULL,
    .open = NULL,
    .close = NULL,
    .write = oc_pty_write,
    .ioctl = NULL,
    .cleanup = oc_pty_cleanup,
    .set_termios = NULL,
};
static struct tty_driver oc_pty_driver = { .ops = &oc_pty_ops };

static int oc_console_write(struct tty *tty, const void *buf, size_t len, bool blocking) {
    (void)tty; (void)buf; (void)blocking;
    return (int)len;
}
static const struct tty_driver_ops oc_console_ops = {
    .init = NULL,
    .open = NULL,
    .close = NULL,
    .write = oc_console_write,
    .ioctl = NULL,
    .cleanup = NULL,
    .set_termios = NULL,
};
DEFINE_TTY_DRIVER(oc_console_driver, &oc_console_ops, TTY_CONSOLE_MAJOR, 64);

// ---------------------------------------------------------------------------
// Exit / die hooks. exit_hook runs on the exiting task's host thread
// with the kernel's pids_lock held (kernel/exit.c), so it must do no
// kernel calls at all: it only hands the pid and code to the serial
// queue and returns. final_status is the RAW exit code
// (kernel/exit.c:166,212: group_exit_code or leader->exit_code).
// ---------------------------------------------------------------------------
static void oc_exit_hook(struct task *task, int code) {
    pid_t pid = task->pid;
    OCCoreGlue *glue = [OCCoreGlue shared];
    dispatch_async(glue.serialQueue, ^{ [glue handleGuestExit:pid code:code]; });
}
static void oc_die_handler(const char *msg) {
    NSLog(@"[CoreGlue] guest died: %s", msg ? msg : "(no message)");
}

@implementation OCCoreGlue

+ (instancetype)shared {
    static OCCoreGlue *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[OCCoreGlue alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _serialQueue = dispatch_queue_create("com.spyboy.opencode.coreglue", DISPATCH_QUEUE_SERIAL);
        _pendingBootCompletions = [NSMutableArray array];
        _runsByPid = [NSMutableDictionary dictionary];
    }
    return self;
}

- (BOOL)booted { return self.bootedFlag; }
- (dispatch_queue_t)serialQueue { return _serialQueue; }

- (NSString *)engineDirectory {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"Engine"];
}
- (NSString *)guestRootDirectory { return [[self engineDirectory] stringByAppendingPathComponent:kGuestRootName]; }
- (NSString *)exchangeDirectory { return [[self engineDirectory] stringByAppendingPathComponent:kExchangeName]; }

- (void)installGuestExecutor {
    __weak typeof(self) weakSelf = self;
    [OCEngine shared].guestExecutor = ^(NSString *command, NSString *workingDirectory,
                                         void (^completion)(NSString * _Nullable, NSInteger)) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { completion(nil, -1); return; }
        [strongSelf runCommand:command workingDirectory:workingDirectory completion:completion];
    };
}

#pragma mark - Errors

+ (NSError *)errorWithCode:(NSInteger)code message:(NSString *)message {
    return [NSError errorWithDomain:kGlueErrorDomain code:code
                         userInfo:@{NSLocalizedDescriptionKey: message ?: @"Guest core error"}];
}

#pragma mark - Boot

- (void)bootWithPackagePaths:(NSArray<NSString *> *)packagePaths
                  completion:(void (^)(BOOL, NSError * _Nullable))completion {
    // The whole boot sequence (mount_root through task_start) runs in
    // one block on the serial queue, because `current` is thread-local
    // (kernel/task.h: `__thread struct task *current`) and every step
    // from become_first_process to task_start must see the same one.
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.serialQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.bootedFlag) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(YES, nil); });
            return;
        }
        [strongSelf.pendingBootCompletions addObject:[completion copy]];
        if (strongSelf.bootInProgress) return; // queued behind the running boot
        strongSelf.bootInProgress = YES;
        [strongSelf bootNowWithPackagePaths:packagePaths];
    });
}

- (void)finishBootWithSuccess:(BOOL)ok error:(nullable NSError *)error {
    NSArray *completions = [self.pendingBootCompletions copy];
    [self.pendingBootCompletions removeAllObjects];
    self.bootInProgress = NO;
    self.bootedFlag = ok;
    dispatch_async(dispatch_get_main_queue(), ^{
        for (void (^c)(BOOL, NSError * _Nullable) in completions) c(ok, error);
    });
}

// Runs on the serial queue. Must stay on this one thread until
// task_start returns: see bootWithPackagePaths.
- (void)bootNowWithPackagePaths:(NSArray<NSString *> *)packagePaths {
    NSString *rootDir = self.guestRootDirectory;
    NSString *dataDir = [rootDir stringByAppendingPathComponent:@"data"];
    NSString *metaDb = [rootDir stringByAppendingPathComponent:@"meta.db"];
    NSFileManager *fm = [NSFileManager defaultManager];

    // First boot only: build the rootfs from the cached .debs.
    // fakefs_import() does mkdir(root) and fails with EEXIST if the
    // root already exists (tools/fakefs.c), so this is strictly
    // one-shot; a root that already exists is left alone.
    if (![fm fileExistsAtPath:metaDb]) {
        if (!packagePaths.count) {
            [self finishBootWithSuccess:NO
                                  error:[OCCoreGlue errorWithCode:1
                                                          message:@"No Debian packages cached; run first-launch setup first"]];
            return;
        }
        NSString *tarPath = [[self engineDirectory] stringByAppendingPathComponent:kRootTarName];
        const char **cPaths = calloc(packagePaths.count, sizeof(char *));
        if (!cPaths) {
            [self finishBootWithSuccess:NO error:[OCCoreGlue errorWithCode:1 message:@"Out of memory"]];
            return;
        }
        for (NSUInteger i = 0; i < packagePaths.count; i++) cPaths[i] = packagePaths[i].UTF8String;
        char bootstrapError[2048] = {0};
        // progress is NULL: lr_debian_bootstrap null-checks it
        // (DebianBootstrap.c: `options && options->progress && ...`).
        int br = lr_debian_bootstrap(cPaths, packagePaths.count, tarPath.UTF8String,
                                     NULL, NULL, bootstrapError, sizeof bootstrapError);
        free(cPaths);
        if (br != 0) {
            [fm removeItemAtPath:tarPath error:nil];
            NSString *msg = [NSString stringWithFormat:@"Debian bootstrap failed (%d): %s",
                             br, bootstrapError[0] ? bootstrapError : "unknown error"];
            [self finishBootWithSuccess:NO error:[OCCoreGlue errorWithCode:1 message:msg]];
            return;
        }
        struct fakefsify_error importError = {0};
        // A zeroed progress struct is the documented no-progress call:
        // the fakefsify tool itself passes `(struct progress) {}`.
        bool imported = fakefs_import(tarPath.UTF8String, rootDir.UTF8String,
                                      &importError, (struct progress){0});
        [fm removeItemAtPath:tarPath error:nil];
        if (!imported) {
            // A half-imported root would mount corrupt, so remove it:
            // the next boot retries the import from scratch.
            [fm removeItemAtPath:rootDir error:nil];
            NSString *detail = importError.message ? [NSString stringWithUTF8String:importError.message] : @"unknown error";
            free(importError.message);
            NSString *msg = [NSString stringWithFormat:@"Rootfs import failed (%d): %@", importError.code, detail];
            [self finishBootWithSuccess:NO error:[OCCoreGlue errorWithCode:2 message:msg]];
            return;
        }
    }

    // Mount the fakefs root. mount_root() is realpath + do_mount
    // (kernel/init.c:44).
    int err = mount_root(&fakefs, dataDir.fileSystemRepresentation);
    if (err < 0) {
        [self finishBootWithSuccess:NO
                              error:[OCCoreGlue errorWithCode:3
                                                      message:[NSString stringWithFormat:@"mount_root failed (%d)", err]]];
        return;
    }

    // Exchange bind mount (RuntimeBridge prepareExchange, minus Swift):
    // a host dir the guest sees at /home/mobile/Downloads.
    NSError *dirError = nil;
    [fm createDirectoryAtPath:self.exchangeDirectory withIntermediateDirectories:YES attributes:nil error:&dirError];
    if (dirError) {
        [self finishBootWithSuccess:NO error:[OCCoreGlue errorWithCode:4 message:@"Cannot create the exchange directory"]];
        return;
    }
    err = generic_mkdirat(AT_PWD, "/home", 0755);
    if (err < 0 && err != _EEXIST) {
        [self finishBootWithSuccess:NO error:[OCCoreGlue errorWithCode:4 message:@"Cannot create /home in the guest"]];
        return;
    }
    err = generic_mkdirat(AT_PWD, "/home/mobile", 0755);
    if (err < 0 && err != _EEXIST) {
        [self finishBootWithSuccess:NO error:[OCCoreGlue errorWithCode:4 message:@"Cannot create /home/mobile in the guest"]];
        return;
    }
    err = fakefs_bind_mount("/home/mobile/Downloads", self.exchangeDirectory.fileSystemRepresentation, false);
    if (err != 0) {
        [self finishBootWithSuccess:NO
                              error:[OCCoreGlue errorWithCode:4
                                                      message:[NSString stringWithFormat:@"Exchange bind mount failed (%d)", err]]];
        return;
    }

    // First process + runtime dirs (AppDelegate boot order).
    err = become_first_process();
    if (err < 0) {
        [self finishBootWithSuccess:NO error:[OCCoreGlue errorWithCode:5 message:@"become_first_process failed"]];
        return;
    }
    err = prepare_guest_runtime_dirs();
    if (err < 0) {
        [self finishBootWithSuccess:NO error:[OCCoreGlue errorWithCode:5 message:@"prepare_guest_runtime_dirs failed"]];
        return;
    }
    // FsInitialize() is intentionally skipped: on a fresh Debian root
    // /ish/version does not exist, so its version block never runs,
    // and FsApplyOverlay() no-ops when RootfsPatch.bundle is absent
    // (app/CurrentRoot.m). There is nothing for it to do here.

    // Device nodes (subset of AppDelegate's list: no clipboard,
    // location, BLE/MIDI or GPU devices — opencode needs none of them).
    static const struct { const char *path; int major; int minor; } kDevices[] = {
        {"/dev/tty1", TTY_CONSOLE_MAJOR, 1}, {"/dev/tty2", TTY_CONSOLE_MAJOR, 2},
        {"/dev/tty3", TTY_CONSOLE_MAJOR, 3}, {"/dev/tty4", TTY_CONSOLE_MAJOR, 4},
        {"/dev/tty5", TTY_CONSOLE_MAJOR, 5}, {"/dev/tty6", TTY_CONSOLE_MAJOR, 6},
        {"/dev/tty7", TTY_CONSOLE_MAJOR, 7},
        {"/dev/tty", TTY_ALTERNATE_MAJOR, DEV_TTY_MINOR},
        {"/dev/console", TTY_ALTERNATE_MAJOR, DEV_CONSOLE_MINOR},
        {"/dev/ptmx", TTY_ALTERNATE_MAJOR, DEV_PTMX_MINOR},
        {"/dev/null", MEM_MAJOR, DEV_NULL_MINOR},
        {"/dev/zero", MEM_MAJOR, DEV_ZERO_MINOR},
        {"/dev/full", MEM_MAJOR, DEV_FULL_MINOR},
        {"/dev/random", MEM_MAJOR, DEV_RANDOM_MINOR},
        {"/dev/urandom", MEM_MAJOR, DEV_URANDOM_MINOR},
    };
    for (size_t i = 0; i < sizeof kDevices / sizeof kDevices[0]; i++) {
        // Return values ignored, as in AppDelegate: the nodes already
        // exist on a rebooted root.
        (void)generic_mknodat(AT_PWD, kDevices[i].path, S_IFCHR | 0666,
                              dev_make(kDevices[i].major, kDevices[i].minor));
    }
    (void)generic_mkdirat(AT_PWD, "/dev/pts", 0755);
    (void)generic_mkdirat(AT_PWD, "/mnt", 0755);
    (void)generic_setattrat(AT_PWD, "/", (struct attr){.type = attr_mode, .mode = 0755}, false);

    // /proc, /sys and /dev/pts. devpts must succeed: the executor's
    // PTYs live there.
    err = do_mount(&procfs, "proc", "/proc", "", 0);
    if (err < 0) { [self finishBootWithSuccess:NO error:[OCCoreGlue errorWithCode:7 message:@"Cannot mount /proc"]]; return; }
    err = do_mount(&sysfs, "sysfs", "/sys", "", 0);
    if (err < 0) { [self finishBootWithSuccess:NO error:[OCCoreGlue errorWithCode:7 message:@"Cannot mount /sys"]]; return; }
    err = do_mount(&devptsfs, "devpts", "/dev/pts", "", 0);
    if (err < 0) { [self finishBootWithSuccess:NO error:[OCCoreGlue errorWithCode:7 message:@"Cannot mount /dev/pts"]]; return; }

    [self configureDns];

    // AF_UNIX host backing paths must fit sun_path (104 bytes):
    // AppDelegate's /var + one-letter-prefix trick, verbatim.
    NSString *tmp = NSTemporaryDirectory();
    if ([tmp hasPrefix:@"/private/var/"]) tmp = [tmp substringFromIndex:@"/private".length];
    sock_tmp_prefix = strdup([tmp stringByAppendingString:@"s"].UTF8String);

    // Console stdio for init. The console driver discards output;
    // init.sh logs to /var/log/linuxrunner-initialize.log instead.
    tty_drivers[TTY_CONSOLE_MAJOR] = &oc_console_driver;
    set_console_device(TTY_CONSOLE_MAJOR, 1);
    err = create_stdio("/dev/console", TTY_CONSOLE_MAJOR, 1);
    if (err < 0) {
        [self finishBootWithSuccess:NO error:[OCCoreGlue errorWithCode:9 message:@"Cannot open the guest console"]];
        return;
    }

    exit_hook = oc_exit_hook;
    die_handler = oc_die_handler;

    // Boot command for Debian (AppDelegate): init.sh runs
    // initialize-debian.sh (dpkg --configure -a, ca-certificates)
    // and then idles as PID 1.
    char argv[4096];
    if (![OCCoreGlue packCommand:@[@"/bin/sh", kBootInitPath] into:argv size:sizeof argv]) {
        [self finishBootWithSuccess:NO error:[OCCoreGlue errorWithCode:10 message:@"Boot command is too long"]];
        return;
    }
    static const char envp[] =
        "TERM=xterm-256color\0"
        "HOME=/root\0"
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0"
        "PYTHONMALLOC=malloc\0";
    err = do_execve("/bin/sh", 2, argv, envp);
    if (err < 0) {
        task_discard_unstarted(current);
        current = NULL;
        [self finishBootWithSuccess:NO
                              error:[OCCoreGlue errorWithCode:10
                                                      message:[NSString stringWithFormat:@"Guest init exec failed (%d)", err]]];
        return;
    }
    err = task_start(current);
    if (err < 0) {
        task_discard_unstarted(current);
        current = NULL;
        [self finishBootWithSuccess:NO
                              error:[OCCoreGlue errorWithCode:11
                                                      message:[NSString stringWithFormat:@"Guest init start failed (%d)", err]]];
        return;
    }
    current = NULL; // the guest owns the init task now
    NSLog(@"[CoreGlue] guest booted (Debian, interpreter, JITless)");
    [self finishBootWithSuccess:YES error:nil];
}

// Minimal configureDns, following AppDelegate's: read the host
// resolver and write /etc/resolv.conf into the guest, falling back
// to 1.1.1.1. The /etc/hosts alias edit (configureGuestHostAlias) is
// skipped: it only maps the host name for sudo, which opencode
// never uses. Runs on the boot thread, with current == init.
- (void)configureDns {
    struct __res_state res;
    BOOL resolverInitialized = (res_ninit(&res) == 0);
    NSMutableString *resolvConf = [NSMutableString new];
    if (resolverInitialized && res.dnsrch[0] != NULL) {
        [resolvConf appendString:@"search"];
        for (int i = 0; res.dnsrch[i] != NULL; i++) {
            [resolvConf appendFormat:@" %s", res.dnsrch[i]];
        }
        [resolvConf appendString:@"\n"];
    }
    union res_sockaddr_union servers[NI_MAXSERV];
    int serversFound = (resolverInitialized && res.nscount > 0)
        ? res_getservers(&res, servers, NI_MAXSERV) : 0;
    char address[NI_MAXHOST];
    int nameserversWritten = 0;
    for (int i = 0; i < serversFound; i++) {
        union res_sockaddr_union s = servers[i];
        if (s.sin.sin_len == 0) continue;
        int nerr = getnameinfo((struct sockaddr *)&s.sin, s.sin.sin_len,
                               address, sizeof address, NULL, 0, NI_NUMERICHOST);
        if (nerr != 0 || address[0] == '\0') continue;
        [resolvConf appendFormat:@"nameserver %s\n", address];
        nameserversWritten++;
    }
    if (resolverInitialized) res_nclose(&res);
    if (nameserversWritten == 0) {
        NSLog(@"[CoreGlue] no system nameservers found, falling back to 1.1.1.1");
        [resolvConf appendString:@"nameserver 1.1.1.1\n"];
    }
    current = pid_get_task(1);
    struct fd *fd = generic_open("/etc/resolv.conf", O_WRONLY_ | O_CREAT_ | O_TRUNC_, 0666);
    if (!IS_ERR(fd)) {
        NSData *bytes = [resolvConf dataUsingEncoding:NSUTF8StringEncoding];
        if (bytes) fd->ops->write(fd, bytes.bytes, bytes.length);
        fd_close(fd);
    }
}

#pragma mark - Executor

// Packs a command array into the flat NUL-joined buffer do_execve
// expects (Terminal convertCommand, verbatim logic).
+ (BOOL)packCommand:(NSArray<NSString *> *)command into:(char *)argv size:(size_t)maxSize {
    char *p = argv;
    for (NSString *cmd in command) {
        const char *c = cmd.UTF8String;
        while (p < argv + maxSize - 1 && (*p++ = *c++)) ;
        *p = '\0';
    }
    *++p = '\0';
    return (size_t)(p - argv) <= maxSize;
}

- (void)runCommand:(NSString *)command
  workingDirectory:(NSString *)workingDirectory
        completion:(void (^)(NSString * _Nullable, NSInteger))completion {
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.serialQueue, ^{
        [weakSelf spawnCommand:command workingDirectory:workingDirectory completion:completion];
    });
}

// Runs on the serial queue, on one thread: become_new_init_child
// through task_start must all see the same thread-local `current`.
- (void)spawnCommand:(NSString *)command
    workingDirectory:(NSString *)workingDirectory
          completion:(void (^)(NSString * _Nullable, NSInteger))completion {
    if (!self.bootedFlag) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@"Guest is not booted", -1); });
        return;
    }
    OCGuestRun *run = [[OCGuestRun alloc] init];
    run.completion = completion;

    int err = become_new_init_child();
    if (err < 0) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@"Cannot create a guest process", err); });
        return;
    }
    struct tty *tty = pty_open_fake(&oc_pty_driver);
    if (IS_ERR(tty)) {
        task_discard_unstarted(current);
        current = NULL;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@"Cannot open a guest terminal", (NSInteger)PTR_ERR(tty)); });
        return;
    }
    run.tty = tty;
    tty->data = (__bridge void *)run; // unretained; the registry holds the run
    NSString *stdioFile = [NSString stringWithFormat:@"/dev/pts/%d", tty->num];
    err = create_stdio(stdioFile.fileSystemRepresentation, TTY_PSEUDO_SLAVE_MAJOR, tty->num);
    tty_release(tty);
    if (err < 0) {
        task_discard_unstarted(current);
        current = NULL;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@"Cannot attach guest stdio", err); });
        return;
    }

    // Working directory inside the guest. "$HOME" expands to /root;
    // a missing directory is created first, so "$HOME/Projects"
    // (which OCEngine passes) works on a fresh root.
    NSString *dir = workingDirectory ?: @"";
    if ([dir hasPrefix:@"$HOME"]) dir = [@"/root" stringByAppendingString:[dir substringFromIndex:5]];
    if (dir.length) {
        [self mkdirGuestPath:dir];
        struct fd *directory = generic_open(dir.UTF8String, O_RDONLY_ | O_DIRECTORY_, 0);
        if (!IS_ERR(directory)) fs_chdir(current->fs, directory);
    }

    char argv[4096];
    if (![OCCoreGlue packCommand:@[@"/bin/sh", @"-c", command] into:argv size:sizeof argv]) {
        task_discard_unstarted(current);
        current = NULL;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@"Command is too long", -1); });
        return;
    }
    static const char envp[] =
        "TERM=xterm-256color\0"
        "HOME=/root\0"
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\0"
        "PYTHONMALLOC=malloc\0";
    err = do_execve("/bin/sh", 3, argv, envp);
    if (err < 0) {
        task_discard_unstarted(current);
        current = NULL;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@"Guest exec failed", err); });
        return;
    }
    run.pid = current->pid;
    self.runsByPid[@(run.pid)] = run;
    err = task_start(current);
    if (err < 0) {
        [self.runsByPid removeObjectForKey:@(run.pid)];
        task_discard_unstarted(current);
        current = NULL;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(@"Guest start failed", err); });
        return;
    }
    current = NULL; // the guest owns the task now

    // Grace period (see CoreGlue.h): if the process exits quickly,
    // report its real exit code; if it is still running after a
    // second, acknowledge the spawn with 0 and let the health
    // checks watch it from then on.
    __weak typeof(self) weakSelf = self;
    __weak OCGuestRun *weakRun = run;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kSpawnAckGraceSeconds * NSEC_PER_SEC)),
                   self.serialQueue, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        __strong OCGuestRun *strongRun = weakRun;
        if (!strongSelf || !strongRun) return;
        if (strongRun.acknowledged) return;
        strongRun.acknowledged = YES;
        void (^c)(NSString * _Nullable, NSInteger) = strongRun.completion;
        strongRun.completion = nil;
        if (strongRun.exited) {
            NSString *out = strongRun.outputString;
            NSInteger code = strongRun.exitCode;
            [strongSelf.runsByPid removeObjectForKey:@(strongRun.pid)];
            dispatch_async(dispatch_get_main_queue(), ^{ c(out, code); });
        } else {
            // Still running: spawn acknowledged. The run stays
            // registered so a later exit is logged, not completed.
            dispatch_async(dispatch_get_main_queue(), ^{ c(@"", 0); });
        }
    });
}

- (void)handleGuestExit:(pid_t)pid code:(int)code {
    // Runs on the serial queue (dispatched by oc_exit_hook).
    if (pid == 1) {
        self.bootedFlag = NO;
        NSLog(@"[CoreGlue] guest init (pid 1) exited with code %d; guest is down", code);
        return;
    }
    OCGuestRun *run = self.runsByPid[@(pid)];
    if (!run) return; // not one of ours (a child of init, a daemon, ...)
    if (run.acknowledged) {
        // Spawn was already acknowledged; the health checks own the
        // outcome from here. Just forget the run.
        NSLog(@"[CoreGlue] guest process %d exited with code %d", (int)pid, code);
        [self.runsByPid removeObjectForKey:@(pid)];
        return;
    }
    run.exited = YES;
    run.exitCode = code;
    // The grace-period block fires the completion; it is already
    // scheduled, so there is nothing else to do here.
}

// mkdir -p inside the guest, ignoring components that already exist.
- (void)mkdirGuestPath:(NSString *)path {
    if (![path hasPrefix:@"/"]) return;
    NSArray<NSString *> *parts = [path componentsSeparatedByString:@"/"];
    NSMutableString *prefix = [NSMutableString string];
    for (NSString *part in parts) {
        if (!part.length) continue;
        [prefix appendFormat:@"/%@", part];
        (void)generic_mkdirat(AT_PWD, prefix.UTF8String, 0755);
    }
}

@end
