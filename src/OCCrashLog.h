// OCCrashLog - best-effort crash recorder.
//
// Installs an uncaught-exception handler and fatal-signal handlers
// (SIGSEGV, SIGABRT, SIGBUS, SIGILL) that append one line to the
// engine log file (Documents/Engine/engine.log). The signal path
// uses only write() on a fd opened at install time: no ObjC, no
// allocation, no locks, so it can run while the process is dying.
// After writing, the default handler is restored and the signal
// re-raised, so iOS still produces its normal crash report; this
// line is only the in-app breadcrumb that survives a relaunch.
// Never crashes the app from the logging code itself: if the fd is
// not open, every function is a no-op.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Install the handlers for the log at logPath. Creates the parent
// directory if needed. Safe to call twice; the second call is a no-op.
void OCCrashLogInstall(NSString *logPath);

NS_ASSUME_NONNULL_END
