// OCGuestInstall: fetch the prebuilt Debian guest image for the
// Kernarium engine and place it where the runtime boots it from.
//
// The image is a plain ext4 file, built from Debian trixie arm64 with
// Node 22, OpenCode 2.3.0 and the agent tools baked in (see
// rootfs-build/opencode-guest-additions.sh). The runtime requires the
// file to carry NO write permission bits, so the install chmods it
// 0444. It is delivered gzipped; both the archive and the extracted
// image are checked against their SHA-256. If the image is already in
// place with the right hash, no download happens at all.
//
// The image is published as release rootfs-20261120, delivered in 12
// verified ~100 MiB parts (rootfs-build/CHUNKS-SHA256SUMS): the app
// downloads each part, verifies its SHA-256, reassembles the .gz and
// verifies the whole archive hash before extracting. A part that
// fails verification is re-downloaded, never a corrupt image. See
// DESKTOP-UI.md.
//
// A version difference is an update, not a failure (TermX c2f4ed5,
// same mechanism here): an installed image from an older release
// boots as-is, and the new one is offered as an Update. Only a file
// that cannot be a guest image at all (wrong size, not ext4, or a
// fresh download that fails its hash) is damaged. The install
// pipeline extracts to a side file and swaps it in only after the
// new image verifies, so a failed update leaves the working image
// in place.
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const kOCGuestImageChunkBaseURL; // release download base URL; chunk name appended
extern NSString *const kOCGuestImageName;     // opencode-debian-trixie-arm64.ext4
extern NSString *const kOCGuestImageGzSHA256; // SHA-256 of the .ext4.gz
extern NSString *const kOCGuestImageSHA256;   // SHA-256 of the extracted .ext4
extern const long long kOCGuestImageSize;     // bytes of the extracted image

@interface OCGuestInstall : NSObject

// True when rootfsPath holds a valid guest image: it exists, has
// the expected size, is read-only, and either matches the recorded
// verified fingerprint (whatever release it was verified as) or
// passes the ext4 superblock-magic check. A version difference is
// NOT a failure: an older release boots as-is. Only a file that
// cannot be a guest image at all (wrong size, not ext4) is
// damaged. Never hashes the file: this runs on the boot path
// (KernGlue) and a 4.46 GB hash there would stall every launch.
+ (BOOL)guestInstalledAt:(NSString *)rootfsPath error:(NSString * _Nullable * _Nullable)error;

// Cheap: is the installed image already this build's release?
// Only the fingerprint's recorded hash can answer without
// hashing 4.46 GB.
+ (BOOL)installedImageIsCurrentReleaseAt:(NSString *)rootfsPath;

// The hash this exact file was verified as, from its fingerprint
// — nil when no fingerprint (or no hash field in it) answers for
// this file.
+ (nullable NSString *)installedImageVerifiedHashAt:(NSString *)rootfsPath;

// Full SHA-256 of the file, or nil when it cannot be read. The
// launch update check uses this (not guestImageHashValidAt:) so a
// mismatching hash can still be recorded in the fingerprint —
// "different hash" is how the next launch knows the image is an
// older release without hashing 4.46 GB again.
+ (nullable NSString *)SHA256OfImageAt:(NSString *)path;

// Record the verified fingerprint (path, size, mtime, hash) for a
// file. The fingerprint only counts for the exact file it was
// recorded for: any size or mtime change voids it.
+ (void)recordVerifiedFingerprintForPath:(NSString *)path attrs:(NSDictionary *)attrs hash:(NSString *)hash;

// The ext4 superblock magic (0xEF53 at offset 1080), little-endian.
// A two-byte pread: the cheap proof a read-only image with no
// fingerprint is a real ext4 filesystem, not a truncated or
// foreign file.
+ (BOOL)imageLooksLikeExt4At:(NSString *)path;

// Full SHA-256 of the file against kOCGuestImageSHA256; records
// the fingerprint (with the hash) on success. A failure here is a
// genuinely damaged fresh download, so the error says damaged —
// a version difference is not corruption, and this only ever runs
// against the file the pipeline just extracted for this release.
+ (BOOL)guestImageHashValidAt:(NSString *)rootfsPath error:(NSString * _Nullable * _Nullable)error;

// Download + verify + extract the image to rootfsPath.
// Calls progress(0..1, step) on the main queue.
+ (void)installGuestTo:(NSString *)rootfsPath
              progress:(void (^ _Nullable)(double fraction, NSString *step))progress
            completion:(void (^ _Nullable)(BOOL ok, NSString * _Nullable error))completion;

// Re-attach to the background download session after the system
// relaunched the app for background URL events: creates the
// session (if needed) so the daemon delivers its pending events,
// and holds the system completion handler until the session has
// delivered them all. Called from the AppDelegate background
// handler. The download itself runs in the daemon (see
// OCGuestInstall.m, OCChunkedDownload), not in the app process.
+ (void)reconnectBackgroundSessionWithCompletionHandler:(void (^)(void))handler;

@end

NS_ASSUME_NONNULL_END
