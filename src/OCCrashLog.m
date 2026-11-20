// OCCrashLog - see the header. Only async-signal-safe calls run in
// the signal handler: write(), time(), and hand-rolled string work
// on a stack buffer. The uncaught-exception handler is not signal
// context, so snprintf and ObjC are fine there; the runtime aborts
// right after it returns, which the SIGABRT handler also records.
#import "OCCrashLog.h"
#import <signal.h>
#import <unistd.h>
#import <fcntl.h>
#import <string.h>
#import <time.h>
#import <stdio.h>

static int OCCrashLogFd = -1;
static volatile sig_atomic_t OCCrashLogInHandler = 0;

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
    }
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
