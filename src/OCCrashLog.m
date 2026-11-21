// OCCrashLog - see the header. Only async-signal-safe calls run in
// the signal handler: write(), open(), read(), lseek(), close(),
// time(). The uncaught-exception handler is not signal context, so
// snprintf and ObjC are fine there; the runtime aborts right after
// it returns, which the SIGABRT handler also records.
//
// EARLY LOG (constructor, before main()): logging used to start in
// main(), so a death before main() left NO file at all and nothing
// to diagnose it with. A __attribute__((constructor)) in this file
// now writes a "DYLD OK" marker the instant dyld loads the binary,
// to Documents/Engine/engine.log AND to Documents/BOOT.txt at the
// top of Documents (visible in the file browser without opening
// folders), with fallbacks to Documents/engine.log and tmp/BOOT.txt.
// main() then appends "--- App launch ---" to BOOT.txt and records
// what the constructor achieved in engine.log. Device reading:
//   no BOOT.txt and no engine.log  = died in dyld / the loader,
//     before any app code ran (only the iOS .ips report can say why);
//   DYLD OK line only              = dyld loaded the binary, died
//     between the constructor and main();
//   DYLD OK + "--- App launch ---" = main() ran; the Launch step
//     markers in engine.log say how far didFinishLaunching got.
#import "OCCrashLog.h"
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import <string.h>
#import <time.h>
#import <stdio.h>
#import <limits.h>
#import <stdlib.h>
#import <sys/stat.h>
#import <sys/types.h>
#import <mach-o/dyld.h>

static int OCCrashLogFd = -1;
static volatile sig_atomic_t OCCrashLogInHandler = 0;
// Paths fixed at install time as plain C strings, so the signal
// handler needs no ObjC and no allocation. CRASH.txt lives at the
// top of Documents; engine.log is Documents/Engine/engine.log.
static char OCCrashLogCrashPath[1024];
static char OCCrashLogEnginePath[1024];

// === BEGIN EARLY LOG (pure C; runs in a constructor before main) ===
// State the constructor leaves for main(): whether it ran, what it
// managed to write, and the first BOOT.txt / engine.log paths it
// wrote, so main() can append to the same files. Everything here is
// best-effort and allocation-free: a logging failure must never
// crash the launch it is trying to record.
static volatile sig_atomic_t OCCrashLogConstructorRan = 0;
static char OCCrashLogEarlyStatus[256];
static char OCCrashLogEarlyBootPath[1024];
static char OCCrashLogEarlyEnginePath[1024];

// mkdir -p for a directory path. Failures are ignored: the open()
// that follows is the real test.
static void OCCrashLogEarlyMkdirP(const char *dir) {
    if (!dir || !*dir) return;
    char buf[1024];
    size_t len = strlen(dir);
    if (len == 0 || len >= sizeof(buf)) return;
    memcpy(buf, dir, len + 1);
    for (char *p = buf + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            mkdir(buf, 0755);
            *p = '/';
        }
    }
    mkdir(buf, 0755);
}

// Write one line to path (flags: O_APPEND to append, O_TRUNC to
// replace). fsync before close, so a SIGKILL a millisecond later
// cannot lose it. Returns 1 on success.
static int OCCrashLogEarlyWriteFile(const char *path, const char *line, int flags) {
    if (!path || !*path || !line) return 0;
    int fd = open(path, flags, 0644);
    if (fd < 0) return 0;
    size_t left = strlen(line);
    const char *p = line;
    int ok = 1;
    while (left > 0) {
        ssize_t w = write(fd, p, left);
        if (w <= 0) { ok = 0; break; }
        p += w;
        left -= (size_t)w;
    }
    if (ok) fsync(fd);
    close(fd);
    return ok;
}

// Try one container root: write the DYLD line to engine.log and
// BOOT.txt under it. Bitmask of what succeeded: 1 = Engine/engine.log,
// 2 = BOOT.txt, 4 = Documents/engine.log fallback, 8 = tmp/BOOT.txt.
// Records the first successful BOOT.txt / engine.log paths.
static int OCCrashLogEarlyTryRoot(const char *root, const char *line) {
    if (!root || !*root) return 0;
    char path[1024];
    int got = 0;
    // Documents/Engine/engine.log (create the dir first).
    if (snprintf(path, sizeof(path), "%s/Documents/Engine", root) < (int)sizeof(path)) {
        OCCrashLogEarlyMkdirP(path);
        if (snprintf(path, sizeof(path), "%s/Documents/Engine/engine.log", root) < (int)sizeof(path)) {
            if (OCCrashLogEarlyWriteFile(path, line, O_WRONLY | O_CREAT | O_APPEND)) {
                got |= 1;
                if (OCCrashLogEarlyEnginePath[0] == '\0')
                    snprintf(OCCrashLogEarlyEnginePath, sizeof(OCCrashLogEarlyEnginePath), "%s", path);
            } else if (snprintf(path, sizeof(path), "%s/Documents/engine.log", root) < (int)sizeof(path)) {
                // Fallback: the Engine dir could not be created/used.
                if (OCCrashLogEarlyWriteFile(path, line, O_WRONLY | O_CREAT | O_APPEND)) got |= 4;
            }
        }
    }
    // Documents/BOOT.txt, truncated: it reflects the latest launch.
    if (snprintf(path, sizeof(path), "%s/Documents/BOOT.txt", root) < (int)sizeof(path)) {
        if (OCCrashLogEarlyWriteFile(path, line, O_WRONLY | O_CREAT | O_TRUNC)) {
            got |= 2;
            if (OCCrashLogEarlyBootPath[0] == '\0')
                snprintf(OCCrashLogEarlyBootPath, sizeof(OCCrashLogEarlyBootPath), "%s", path);
        }
    }
    // tmp/BOOT.txt, last fallback inside the same container.
    if (snprintf(path, sizeof(path), "%s/tmp", root) < (int)sizeof(path)) {
        OCCrashLogEarlyMkdirP(path);
    }
    if (snprintf(path, sizeof(path), "%s/tmp/BOOT.txt", root) < (int)sizeof(path)) {
        if (OCCrashLogEarlyWriteFile(path, line, O_WRONLY | O_CREAT | O_TRUNC)) got |= 8;
    }
    return got;
}

// Runs the instant dyld loads the binary, before main(). Pure C:
// no ObjC, no allocation, only getenv / _NSGetExecutablePath /
// mkdir / open / write / fsync / close. Two candidate container
// roots are tried (they are the same directory on a normal install;
// trying both covers a LiveContainer layout where they differ):
// $HOME, and the parent of the .app bundle from the executable path.
__attribute__((constructor))
static void OCCrashLogEarlyConstructor(void) {
    OCCrashLogConstructorRan = 1;
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    char line[256];
    int len = snprintf(line, sizeof(line),
        "[%02d:%02d:%02d] DYLD OK pid=%d binary loaded (constructor ran before main)\n",
        tmv.tm_hour, tmv.tm_min, tmv.tm_sec, (int)getpid());
    if (len <= 0) return;
    // stderr too: a host (e.g. LiveContainer) may capture it.
    fprintf(stderr, "%s", line);
    const char *home = getenv("HOME");
    int gotHome = 0, gotExe = 0;
    if (home && *home) gotHome = OCCrashLogEarlyTryRoot(home, line);
    // Second root: parent of the .app bundle, from the exe path.
    char exe[1024];
    uint32_t exeSize = sizeof(exe);
    if (_NSGetExecutablePath(exe, &exeSize) == 0) {
        char *slash = strrchr(exe, '/');
        if (slash) {
            *slash = '\0'; // strip the binary name
            slash = strrchr(exe, '/');
            if (slash) {
                *slash = '\0'; // strip the .app bundle name
                if (!home || strcmp(exe, home) != 0) gotExe = OCCrashLogEarlyTryRoot(exe, line);
            }
        }
    }
    int wroteEngine = ((gotHome | gotExe) & 5) != 0;   // 1 = Engine/engine.log, 4 = Documents/engine.log
    int wroteBoot = ((gotHome | gotExe) & 10) != 0;     // 2 = Documents/BOOT.txt, 8 = tmp/BOOT.txt
    if (wroteEngine && wroteBoot) {
        snprintf(OCCrashLogEarlyStatus, sizeof(OCCrashLogEarlyStatus),
            "Early log: constructor wrote DYLD OK marker to engine.log and BOOT.txt");
    } else if (wroteEngine) {
        snprintf(OCCrashLogEarlyStatus, sizeof(OCCrashLogEarlyStatus),
            "Early log: constructor wrote DYLD OK marker to engine.log only (BOOT.txt write failed)");
    } else if (wroteBoot) {
        snprintf(OCCrashLogEarlyStatus, sizeof(OCCrashLogEarlyStatus),
            "Early log: constructor wrote DYLD OK marker to BOOT.txt only (engine.log write failed)");
    } else {
        snprintf(OCCrashLogEarlyStatus, sizeof(OCCrashLogEarlyStatus),
            "Early log: constructor ran but could NOT write any log file (HOME=%s)",
            (home && *home) ? home : "(unset)");
    }
}
// === END EARLY LOG ===

static void OCCrashLogWriteRaw(const char *bytes, size_t len) {
    if (OCCrashLogFd < 0 || !bytes || len == 0) return;
    // One fd, O_APPEND: appends stay whole against the engine log's
    // own appends from the other thread.
    const char *p = bytes;
    size_t left = len;
    while (left > 0) {
        ssize_t w = write(OCCrashLogFd, p, left);
        if (w <= 0) return;
        p += w;
        left -= (size_t)w;
    }
}

// Append a decimal number to the buffer. Returns the new position.
static size_t OCCrashLogAppendNumber(char *buf, size_t pos, size_t cap, long long value) {
    char tmp[24];
    size_t digits = 0;
    long long v = value;
    if (v == 0) {
        tmp[digits++] = '0';
    } else {
        while (v > 0 && digits < sizeof(tmp)) {
            tmp[digits++] = (char)('0' + (v % 10));
            v /= 10;
        }
    }
    while (digits > 0 && pos + 1 < cap) buf[pos++] = tmp[--digits];
    return pos;
}

// Write a timestamped marker line ("[HH:MM:SS] <text>\n") to the
// engine-log fd. Normal context only (uses localtime_r/snprintf).
static void OCCrashLogWriteMarker(const char *text) {
    if (OCCrashLogFd < 0 || !text) return;
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    char line[128];
    int len = snprintf(line, sizeof(line), "[%02d:%02d:%02d] %s\n",
                       tmv.tm_hour, tmv.tm_min, tmv.tm_sec, text);
    if (len > 0) OCCrashLogWriteRaw(line, (size_t)len);
}

// Write Documents/CRASH.txt (overwritten on each crash): the title
// line, then the last ~2 KB of the engine log, starting at a line
// boundary. Signal-safe: open/read/lseek/write/close only, stack
// buffers only. Best effort throughout: any failure just leaves a
// shorter CRASH.txt.
static void OCCrashLogWriteCrashFile(const char *title, size_t titleLen) {
    if (OCCrashLogCrashPath[0] == '\0') return;
    int fd = open(OCCrashLogCrashPath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    const char *p = title;
    size_t left = titleLen;
    while (left > 0) {
        ssize_t w = write(fd, p, left);
        if (w <= 0) break;
        p += w;
        left -= (size_t)w;
    }
    const char *header = "Last engine log lines:\n";
    size_t hleft = strlen(header);
    p = header;
    while (hleft > 0) {
        ssize_t w = write(fd, p, hleft);
        if (w <= 0) break;
        p += w;
        hleft -= (size_t)w;
    }
    if (OCCrashLogEnginePath[0] != '\0') {
        int efd = open(OCCrashLogEnginePath, O_RDONLY);
        if (efd >= 0) {
            off_t end = lseek(efd, 0, SEEK_END);
            if (end > 0) {
                off_t want = end > 2048 ? 2048 : end;
                off_t start = end - want;
                if (lseek(efd, start, SEEK_SET) == start) {
                    char buf[2048];
                    size_t got = 0;
                    while (got < (size_t)want) {
                        ssize_t n = read(efd, buf + got, (size_t)want - got);
                        if (n <= 0) break;
                        got += (size_t)n;
                    }
                    size_t off = 0;
                    if (start > 0) {
                        // Skip a partial first line.
                        while (off < got && buf[off] != '\n') off++;
                        if (off < got) off++;
                    }
                    p = buf + off;
                    left = got - off;
                    while (left > 0) {
                        ssize_t w = write(fd, p, left);
                        if (w <= 0) break;
                        p += w;
                        left -= (size_t)w;
                    }
                }
            }
            close(efd);
        }
    }
    close(fd);
}

static void OCCrashLogSignalHandler(int signo) {
    if (OCCrashLogInHandler) {
        // Already dying in the handler: do not recurse, just die
        // the normal way.
        signal(signo, SIG_DFL);
        raise(signo);
        return;
    }
    OCCrashLogInHandler = 1;
    const char *name = "UNKNOWN";
    switch (signo) {
        case SIGSEGV: name = "SIGSEGV"; break;
        case SIGABRT: name = "SIGABRT"; break;
        case SIGBUS: name = "SIGBUS"; break;
        case SIGILL: name = "SIGILL"; break;
    }
    // "CRASH <name> t=<epoch seconds>\n", built by hand.
    char buf[128];
    size_t pos = 0;
    const char *prefix = "CRASH ";
    while (*prefix && pos + 1 < sizeof(buf)) buf[pos++] = *prefix++;
    while (*name && pos + 1 < sizeof(buf)) buf[pos++] = *name++;
    const char *mid = " t=";
    while (*mid && pos + 1 < sizeof(buf)) buf[pos++] = *mid++;
    pos = OCCrashLogAppendNumber(buf, pos, sizeof(buf), (long long)time(NULL));
    if (pos + 1 < sizeof(buf)) buf[pos++] = '\n';
    OCCrashLogWriteRaw(buf, pos);
    OCCrashLogWriteCrashFile(buf, pos);
    // Let the crash proceed normally so iOS still writes its report.
    signal(signo, SIG_DFL);
    raise(signo);
}

static void OCCrashLogUncaughtException(NSException *exception) {
    if (OCCrashLogFd < 0) return;
    const char *name = "?";
    const char *reason = "?";
    if (exception.name) name = exception.name.UTF8String ?: "?";
    if (exception.reason) reason = exception.reason.UTF8String ?: "?";
    char buf[512];
    int len = snprintf(buf, sizeof(buf), "CRASH uncaught exception %s: %s t=%lld\n",
                       name, reason, (long long)time(NULL));
    if (len > 0) {
        size_t n = (size_t)len < sizeof(buf) ? (size_t)len : sizeof(buf) - 1;
        OCCrashLogWriteRaw(buf, n);
        OCCrashLogWriteCrashFile(buf, n);
    }
}

// Previous-run check (normal context, Foundation is fine). Reads
// the last 64 KB of the engine log: a CRASH line already explains
// the run's end. Otherwise, anything after the last CLEAN SHUTDOWN
// marker means the process did work after its last clean shutdown
// and then ended without one (jetsam / SIGKILL leave no trace), so
// append the unclean-end line. A log that ends exactly at a marker
// is clean; a missing or empty log is a first launch, not a crash.
static void OCCrashLogCheckPreviousRun(NSString *logPath) {
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:logPath];
    if (!fh) return;
    unsigned long long size = [fh seekToEndOfFile];
    if (size == 0) { [fh closeFile]; return; }
    unsigned long long window = size > 65536 ? 65536 : size;
    [fh seekToFileOffset:size - window];
    NSData *tailData = [fh readDataToEndOfFile];
    [fh closeFile];
    NSString *text = [[NSString alloc] initWithData:tailData encoding:NSUTF8StringEncoding];
    if (!text.length) return;
    if ([text containsString:@"CRASH "]) return;
    NSString *rest = text;
    NSRange marker = [text rangeOfString:@"CLEAN SHUTDOWN" options:NSBackwardsSearch];
    if (marker.location != NSNotFound) {
        NSUInteger after = NSMaxRange(marker);
        rest = after < text.length ? [text substringFromIndex:after] : @"";
    }
    NSString *trimmed = [rest stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!trimmed.length) return;
    OCCrashLogWriteMarker("Previous run ended without shutdown (likely killed by iOS, e.g. jetsam; no signal handler runs for SIGKILL)");
}

void OCCrashLogInstall(NSString *logPath) {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    if (!logPath.length) return;
    NSString *dir = [logPath stringByDeletingLastPathComponent];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    int fd = open(logPath.UTF8String, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    OCCrashLogFd = fd;
    // Paths for the signal handler (plain C strings, bounded).
    snprintf(OCCrashLogEnginePath, sizeof(OCCrashLogEnginePath), "%s", logPath.UTF8String ?: "");
    NSString *documents = [[dir stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"CRASH.txt"];
    snprintf(OCCrashLogCrashPath, sizeof(OCCrashLogCrashPath), "%s", documents.UTF8String ?: "");
    NSSetUncaughtExceptionHandler(&OCCrashLogUncaughtException);
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = &OCCrashLogSignalHandler;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags = 0;
    sigaction(SIGSEGV, &sa, NULL);
    sigaction(SIGABRT, &sa, NULL);
    sigaction(SIGBUS, &sa, NULL);
    sigaction(SIGILL, &sa, NULL);
}

// Append one timestamped marker line to an arbitrary path (best
// effort, own fd, fsync before close). Used for BOOT.txt; the
// engine log itself goes through the shared fd above.
static void OCCrashLogAppendMarkerToPath(const char *path, const char *text) {
    if (!path || !*path || !text) return;
    int fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return;
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    char line[128];
    int len = snprintf(line, sizeof(line), "[%02d:%02d:%02d] %s\n",
                       tmv.tm_hour, tmv.tm_min, tmv.tm_sec, text);
    if (len > 0) {
        const char *p = line;
        size_t left = (size_t)len;
        while (left > 0) {
            ssize_t w = write(fd, p, left);
            if (w <= 0) break;
            p += w;
            left -= (size_t)w;
        }
        fsync(fd);
    }
    close(fd);
}

void OCCrashLogInstallEarly(void) {
    NSArray *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *docDir = docs.firstObject;
    if (!docDir.length) return;
    NSString *logPath = [[docDir stringByAppendingPathComponent:@"Engine"] stringByAppendingPathComponent:@"engine.log"];
    OCCrashLogInstall(logPath);
    OCCrashLogCheckPreviousRun(logPath);
    OCCrashLogWriteMarker("--- App launch ---");
    // What the constructor achieved (or that it never ran): without
    // this line, a missing DYLD OK marker is ambiguous between "the
    // constructor never ran" and "it ran but could not write".
    if (OCCrashLogConstructorRan) {
        OCCrashLogWriteMarker(OCCrashLogEarlyStatus);
    } else {
        OCCrashLogWriteMarker("Early log: WARNING constructor did not run before main()");
    }
    // Keep BOOT.txt in step: append the launch line to the BOOT.txt
    // the constructor wrote (same file it truncated) and to the
    // canonical Documents/BOOT.txt, in case they differ.
    NSString *bootPath = [docDir stringByAppendingPathComponent:@"BOOT.txt"];
    OCCrashLogAppendMarkerToPath(bootPath.UTF8String, "--- App launch ---");
    if (OCCrashLogEarlyBootPath[0] != '\0' &&
        strcmp(OCCrashLogEarlyBootPath, bootPath.UTF8String ?: "") != 0) {
        OCCrashLogAppendMarkerToPath(OCCrashLogEarlyBootPath, "--- App launch ---");
    }
    // If the constructor wrote engine.log somewhere other than the
    // canonical path (a different container root), say so plainly:
    // the user must look at THAT file, not this one, for the DYLD line.
    if (OCCrashLogEarlyEnginePath[0] != '\0' &&
        strcmp(OCCrashLogEarlyEnginePath, logPath.UTF8String ?: "") != 0) {
        char buf[1100];
        snprintf(buf, sizeof(buf), "Early log: constructor wrote engine.log to %s (not the canonical path)", OCCrashLogEarlyEnginePath);
        OCCrashLogWriteMarker(buf);
    }
}

void OCCrashLogMarkCleanShutdown(void) {
    OCCrashLogWriteMarker("CLEAN SHUTDOWN");
}

void OCCrashLogMarkForeground(void) {
    OCCrashLogWriteMarker("--- Foreground ---");
}
