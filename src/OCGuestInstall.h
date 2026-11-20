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
// The image is NOT published yet and the hashes below are still TODO
// placeholders: until rootfs-build finishes and the release is
// published, first-launch setup refuses the image with a hash
// mismatch instead of booting something unverified. See
// KERNARIUM-ENGINE.md, "Build status".
// SPDX-License-Identifier: GPL-2.0-or-later
#import <Foundation/Foundation.h>

extern NSString *const kOCGuestImageURL;      // .ext4.gz download URL
extern NSString *const kOCGuestImageName;     // opencode-debian-trixie-arm64.ext4
extern NSString *const kOCGuestImageGzSHA256; // SHA-256 of the .ext4.gz
extern NSString *const kOCGuestImageSHA256;   // SHA-256 of the extracted .ext4
extern const long long kOCGuestImageSize;     // bytes of the extracted image

@interface OCGuestInstall : NSObject

// True when rootfsPath exists, has the expected size, and hashes to
// kOCGuestImageSHA256.
+ (BOOL)guestInstalledAt:(NSString *)rootfsPath error:(NSString **)error;

// Download + verify + extract the image to rootfsPath.
// Calls progress(0..1, step) on the main queue.
+ (void)installGuestTo:(NSString *)rootfsPath
              progress:(void (^)(double fraction, NSString *step))progress
            completion:(void (^)(BOOL ok, NSString *error))completion;

@end
