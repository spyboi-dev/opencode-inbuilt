// OCCoreGlue - minimal ObjC boot glue for the embedded LinuxRunner core.
//
// This file is ONLY compiled into the app by the macOS core build
// (build-core.sh, .github/workflows/build-core.yml). The Linux build
// (build.sh) does not compile it, and the app keeps working without it:
// OCEngine.guestCoreLinked stays NO and the Engine tab says so.
//
// What it does, with no Swift and no LinuxRunner UI:
//
//   1. First boot: turns the cached, SHA-verified Debian .debs
//      (downloaded by OCEngine's first-launch setup) into a fakefs
//      guest root, using the core's own tools:
//      lr_debian_bootstrap() (.debs -> guest tar) then
//      fakefs_import() (guest tar -> root dir + meta.db).
//      This runs once; a root that already exists is left alone.
//   2. Boots the guest the way LinuxRunner's AppDelegate does, minus
//      the Swift parts: mount_root(), become_first_process(),
//      prepare_guest_runtime_dirs(), the /dev nodes, proc/sys/devpts
//      mounts, a minimal configureDns(), console stdio, then
//      do_execve("/bin/sh /usr/lib/linuxrunner/init.sh") and
//      task_start(current). The init script runs
//      initialize-debian.sh (dpkg --configure -a) and then idles as
//      PID 1, exactly as in LinuxRunner.
//   3. Provides the guest executor OCEngine expects: run a command in
//      a fresh guest process on a PTY and report its exit code, the
//      same way TerminalViewController spawns a session
//      (become_new_init_child + pty_open_fake + create_stdio +
//      do_execve + task_start), with exit reported by exit_hook.
//
// Deliberately NOT carried over from AppDelegate's boot: the Swift
// Roots / UserPreferences / RuntimeBridge layer, the iosfs host-FS
// bridge, clipboard / location / BLE / MIDI devices, the GPU device,
// the gdb debug server, and the host-alias /etc/hosts edit. None of
// those is needed to run `opencode serve` in the guest; the guest
// reaches the host only through the exchange bind mount
// (/home/mobile/Downloads -> Documents/Engine/exchange) and through
// the server port the app talks to.
//
// Executor completion semantics (this matters for OCEngine):
// the completion fires with the process exit code when the process
// exits, OR with 0 once the process is confirmed still running 1
// second after spawn (a "spawn acknowledgement"). The serve process
// is long-lived, so OCEngine's startEngine depends on the second
// case: without it Start would wait forever for a process that is
// supposed to keep running. A process that dies inside that first
// second reports its real exit code instead, so a missing binary or
// a bad command fails fast. A later death is observed by OCEngine's
// health checks (3 strikes -> restart), the same as in LinuxRunner.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OCCoreGlue : NSObject

+ (instancetype)shared;

// YES once the guest init task is running. NO before boot, and NO
// again if init dies.
@property (nonatomic, readonly) BOOL booted;

// Registers the guest executor on [OCEngine shared], which makes
// OCEngine.guestCoreLinked become YES. Call once at app launch.
// Safe to call before boot; commands run after boot only.
- (void)installGuestExecutor;

// Boots the guest. First boot builds the Debian rootfs from the
// given .deb paths (host paths, already SHA-verified by OCEngine's
// setup) and then mounts and starts init; later boots just mount
// and start. Safe to call again: a second call while booting queues
// its completion behind the first, and a call after boot completes
// immediately with YES. Runs off the main thread; completion is
// always called on the main queue.
- (void)bootWithPackagePaths:(NSArray<NSString *> *)packagePaths
                  completion:(void (^)(BOOL ok, NSError * _Nullable error))completion;

// Runs one command inside the guest, as OCEngine's guestExecutor
// expects: /bin/sh -c <command> in a fresh guest process, with
// workingDirectory resolved inside the guest ("$HOME" expands to
// "/root"; a missing directory is created). See the header comment
// for the completion semantics. Completion is on the main queue.
- (void)runCommand:(NSString *)command
  workingDirectory:(NSString *)workingDirectory
        completion:(void (^)(NSString * _Nullable output, NSInteger exitCode))completion;

// Host directories the guest uses. The root holds meta.db + data/
// (the fakefs database); the exchange dir is bind-mounted into the
// guest at /home/mobile/Downloads.
- (NSString *)guestRootDirectory;  // Documents/Engine/root
- (NSString *)exchangeDirectory;   // Documents/Engine/exchange

@end

NS_ASSUME_NONNULL_END
