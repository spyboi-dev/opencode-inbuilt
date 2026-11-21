#!/bin/bash
# Extract the finished TermX Debian image into a plain directory so
# the OpenCode additions can run inside it (chroot) before the image
# is repacked. The vendor image is never modified; the work copy
# lives in rootfs-build/work/rootfs/.
#
# No loop mounts: this VM has no loop devices (no /dev/loop* and the
# loop module is not loadable), so extraction is debugfs rdump.
# rdump drops setuid/setgid/sticky bits (the image's /usr/bin/sudo
# is 4755 but lands as 0755), so fixup-rdump-modes.py re-applies
# every entry's exact mode and numeric uid:gid from the image, and
# fails loudly if any image entry is missing from the extraction.
# The image holds no device nodes (its /dev/null is a regular file;
# devtmpfs covers /dev at boot), so nothing needs mknod.
#
# Everything runs on the home disk: /tmp is a 512 MB tmpfs and a
# 1.7 GB extraction fills it. Run with sudo so the extracted files
# keep the image's numeric owners.
# SPDX-License-Identifier: GPL-2.0-or-later
set -e
cd "$(dirname "$0")"
# Paths from the script's own location, not $HOME: under sudo $HOME
# is /root, which would point at a nonexistent vendor image.
WS="$(cd "$PWD/../.." && pwd)"
SRC="$WS/kernarium-termux/vendor/termx-debian-trixie-arm64.ext4"
WORK="$PWD/work"
ROOTFS="$WORK/rootfs"

[ -f "$SRC" ] || { echo "FATAL: TermX image not found: $SRC" >&2; exit 1; }
mkdir -p "$WORK" "$ROOTFS"
if [ -d "$ROOTFS/bin" ] && [ -f "$ROOTFS/sbin/init" ]; then
  echo "== rootfs already extracted at $ROOTFS, skipping"
  du -sh "$ROOTFS"
  exit 0
fi

echo "== rdump $SRC -> $ROOTFS (home disk, not /tmp)"
sudo debugfs -R "rdump / $ROOTFS" "$SRC" 2>&1 | grep -v "^debugfs " || true
[ -d "$ROOTFS/bin" ] || { echo "FATAL: rdump produced no rootfs" >&2; exit 1; }

echo "== fix up modes/owners from the image (rdump drops setuid etc.)"
sudo python3 "$PWD/fixup-rdump-modes.py" "$SRC" "$ROOTFS"

echo "== spot checks"
ls -l "$ROOTFS/usr/bin/sudo" "$ROOTFS/usr/bin/passwd" | awk '{print $1, $3, $4, $9}'
stat -c "%a %u:%g %n" "$ROOTFS/home/termux" "$ROOTFS/sbin/init"
du -sh "$ROOTFS"
echo "EXTRACT DONE"
