// OCKernGlue - minimal ObjC boot glue for the embedded Kernarium
// runtime (KRuntime_6_18_4K), replacing CoreGlue (LinuxRunner).
//
// This file is compiled into the app by every build on this branch,
// but the runtime itself is loaded at run time with dlopen, on the
// FIRST Start — never at app launch (a framework whose static
// initializers die under LiveContainer would otherwise kill the
// launch before any screen appears). The framework only exists in
// the Mac-built IPA (build-kernarium.sh), never on this Linux VM.
// When the framework is absent the glue reports that honestly and
// OCEngine.guestCoreLinked stays NO.
//
// What it does, with no Swift and no Kernarium UI:
//
//   1. Loads exactly one runtime framework and resolves only
//      kernarium_runtime_get_api_v28() (public C API v43).
//   2. Boots the Debian guest the way TermX does: plan_gpu_budget(),
//      set_console_output_callback(), fill kernarium_runtime_boot
//      (rootfs + fresh 4 GiB overlay, use_jit = 0), then run() on a
//      background thread (it blocks until the guest stops). The
//      guest is "up" when the console shows `login: `; there is no
//      other boot-completed signal. A hidden full-screen MTKView is
//      mandatory (run() refuses a null view); AppDelegate puts it
//      behind the tab bar, never shown.
//   3. Starts the host half of the vsock bridge (OCVsockBridge)
//      before boot: 127.0.0.1:4096 -> guest vsock 4096 (the OpenCode
//      server) and 127.0.0.1:8000 -> guest vsock 8000 (app.py).
//   4. Provides the guest executor OCEngine expects, redefined for a
//      runtime that has no executor: the block types a command at the
//      autologin shell over the serial console and acks once it was
//      sent. The ack is NOT an exit code and NOT a spawn
//      acknowledgement: there is no per-command exit code over the
//      console, and OCEngine.startServe does not depend on it — it
//      waits for the guest's own `server listening` line instead.
//   5. Feeds every console line to OCEngine (PROGRESS / ERROR /
//      `server listening` parsing lives there). The server password
//      is never left in that transcript: the bootstrap types it with
//      echo off, and the glue redacts it from console output as well.
//
// Deliberately NOT carried over: the LinuxRunner fakefs root, the
// .deb first-launch setup, the exchange bind mount (no shared folder
// exists in the public Kernarium API), and any guest executor with
// exit codes. Guest writes vanish on every reboot (overlay formatted
// fresh); see KERNARIUM-ENGINE.md, "PERSISTENCE-TODO".
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>
#import <MetalKit/MetalKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface OCKernGlue : NSObject

+ (instancetype)shared;

// YES once the runtime framework loaded and the API getter resolved.
@property (nonatomic, readonly) BOOL runtimeLoaded;

// YES once the guest reached the `login: ` prompt. NO before boot,
// and NO again after a stop or a failed run.
@property (nonatomic, readonly) BOOL booted;

// The guest framebuffer view run() needs. Created lazily, full
// screen; AppDelegate inserts it behind the tab bar. Never shown.
@property (nonatomic, readonly, nullable) MTKView *guestView;

// Load the runtime framework on demand (first Start) and install
// the guest executor once it is up. Returns YES when the runtime is
// loaded (or was already). A failed load logs the exact reason and
// returns NO. Never call at app launch: that is what this exists
// to avoid.
- (BOOL)ensureRuntimeLoaded;

// Registers the guest executor on [OCEngine shared], which makes
// OCEngine.guestCoreLinked become YES. Called by
// ensureRuntimeLoaded on the first Start, not at app launch.
// No-op (with a log line) when the runtime framework did not load.
- (void)installGuestExecutor;

// Boots the guest. Safe to call again: a second call while booting
// queues its completion behind the first, and a call after boot
// completes immediately with YES. Runs off the main thread;
// completion is always called on the main queue.
- (void)bootWithCompletion:(void (^)(BOOL ok, NSError * _Nullable error))completion;

// Types text at the guest console (autologin shell). A trailing
// newline is added when missing. Sent in small chunks so a long
// bootstrap cannot overflow the tty input buffer. No-op when the
// guest is not running.
- (void)sendConsoleText:(NSString *)text;

// The exact string to redact from console output before it is
// logged or parsed (the server password while the bootstrap types
// it). Set by OCEngine before sending the bootstrap.
@property (nonatomic, copy, nullable) NSString *consoleRedactString;

// Stops the guest (request_stop + bridge stop). A host stop returns
// an error from run(), not 0: that is treated as a clean stop, not a
// failure. Note the upstream contract: after a host stop the guest
// cannot be released, so a later boot in the same process may be
// refused until the app is relaunched (see KERNARIUM-ENGINE.md).
- (void)stopGuest;

// Best-effort guest storage settle (runtime sync()): asks the guest
// to write its filesystems back and flushes the host files. The
// completion says whether the guest confirmed. This settles the
// overlay file only; it does NOT make anything persist across boots
// (the overlay is formatted fresh on the next boot).
- (void)syncGuestWithCompletion:(void (^)(BOOL confirmed))completion;

// Hold (background) / release (foreground) the guest's GPU requests.
- (void)setGpuHold:(BOOL)held;

// Guest input, for the Desktop UI mode: the guest display is a
// touchscreen (slots 0..<10, coordinates 0..32767 on both axes) plus
// a keyboard. No-ops when the guest is not running.
- (void)sendTouchSlot:(uint32_t)slot x:(uint32_t)x y:(uint32_t)y pressed:(BOOL)pressed;
- (void)sendKeyCode:(uint16_t)code pressed:(BOOL)pressed;
- (void)sendKeyboardUsage:(uint32_t)usage pressed:(BOOL)pressed;

// Park the guest framebuffer view behind the app's window (where it
// lives while the desktop is not on screen). The desktop screen
// moves it into its own view while visible and parks it again on
// leaving, so run() always has the same view.
- (void)parkGuestView;

// Host directories the guest uses.
- (NSString *)guestDirectory; // Documents/Engine/guest
- (NSString *)guestImagePath; // Documents/Engine/guest/opencode-debian-trixie-arm64.ext4

@end

NS_ASSUME_NONNULL_END
