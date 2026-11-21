#!/bin/bash
# Build the OpenCode guest image: run opencode-guest-additions.sh
# inside the extracted TermX rootfs (arm64 chroot under
# qemu-aarch64-static), then pack it as
# opencode-debian-trixie-arm64.ext4 (+ .gz + SHA256SUMS).
#
# Everything happens in this one invocation: mounts do not persist
# between exec calls in this environment, so the binfmt setup, the
# bind mounts, the chroot run and the unmounts are all here.
# Run with sudo (mounts + chroot need root).
#
# Inputs (all verified before the chroot runs):
#   rootfs-build/work/rootfs/      (from extract-termx-image.sh)
#   rootfs-build/opencode-guest-additions.sh
#   rootfs-build/scratch/          (Node + CLI tarballs + desktop .deb,
#                                   SHA-256 verified on download)
# Outputs (rootfs-build/, git-ignored build artifacts):
#   opencode-debian-trixie-arm64.ext4(.gz), SHA256SUMS
# SPDX-License-Identifier: GPL-2.0-or-later
set -e
cd "$(dirname "$0")"
ROOTFS="$PWD/work/rootfs"
ADDITIONS="$PWD/opencode-guest-additions.sh"
SCRATCH="$PWD/scratch"
IMG="$PWD/opencode-debian-trixie-arm64.ext4"
LOG="$PWD/build-opencode-image.log"
exec > >(tee -a "$LOG") 2>&1
echo "=== OpenCode guest image build started $(date -u +%FT%TZ) ==="

# ---- prerequisites
[ -d "$ROOTFS/bin" ] || { echo "FATAL: extracted rootfs not found, run extract-termx-image.sh first" >&2; exit 1; }
[ -f "$ADDITIONS" ] || { echo "FATAL: $ADDITIONS not found" >&2; exit 1; }
[ -x /usr/bin/qemu-aarch64-static ] || { echo "FATAL: /usr/bin/qemu-aarch64-static not found (apt-get install qemu-user-static)" >&2; exit 1; }
for f in node-v22.23.5-linux-arm64.tar.gz opencode-linux-arm64.tar.gz opencode-desktop-linux-arm64.deb; do
  [ -f "$SCRATCH/$f" ] || { echo "FATAL: pre-downloaded $f not found in $SCRATCH" >&2; exit 1; }
done
echo "8bd3dc69eee8f3f226315a80d7d1d4faccf217a4c8fae500168ac2e38f3bdba3  $SCRATCH/node-v22.23.5-linux-arm64.tar.gz" | sha256sum -c -
echo "3207fb5cdec448d479242c0f1a14f4f7bdfcad3a79209b5eb8f9003725e93711  $SCRATCH/opencode-linux-arm64.tar.gz" | sha256sum -c -
echo "d3645cb1402517c00f1979e835ab37b53d16b9812480b3443b08f65394a79db1  $SCRATCH/opencode-desktop-linux-arm64.deb" | sha256sum -c -
echo "== all three archives verified against the release SHAs"

# ---- binfmt (same pattern as TermX build-rootfs.sh: register the
# packaged handler VERBATIM, never printf %b it)
mkdir -p /proc/sys/fs/binfmt_misc
mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc 2>/dev/null || true
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
  cat /usr/lib/binfmt.d/qemu-aarch64.conf > /proc/sys/fs/binfmt_misc/register
fi
cp /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/"
chroot "$ROOTFS" /bin/uname -m | grep -q aarch64 || {
  echo "FATAL: qemu-aarch64 binfmt is not working" >&2; exit 1; }
echo "== binfmt qemu-aarch64 OK (chroot uname -m = aarch64)"

# ---- mounts + files into the chroot
mount -t proc proc "$ROOTFS/proc" 2>/dev/null || true
mount -t sysfs sys "$ROOTFS/sys" 2>/dev/null || true
mount --bind /dev "$ROOTFS/dev" 2>/dev/null || true
mount -t devpts devpts "$ROOTFS/dev/pts" 2>/dev/null || true
cleanup_mounts() {
  umount "$ROOTFS/dev/pts" 2>/dev/null || true
  umount "$ROOTFS/dev" 2>/dev/null || true
  umount "$ROOTFS/sys" 2>/dev/null || true
  umount "$ROOTFS/proc" 2>/dev/null || true
}
trap cleanup_mounts EXIT
cp "$ADDITIONS" "$ROOTFS/root/opencode-guest-additions.sh"
chmod +x "$ROOTFS/root/opencode-guest-additions.sh"
mkdir -p "$ROOTFS/tmp/guest-dl"
cp "$SCRATCH/node-v22.23.5-linux-arm64.tar.gz" "$SCRATCH/opencode-linux-arm64.tar.gz" "$SCRATCH/opencode-desktop-linux-arm64.deb" "$ROOTFS/tmp/guest-dl/"
# /etc/resolv.conf in the image is a symlink to systemd-resolved's
# stub (dangling while resolved is not running). Swap in the host's
# file for the build, restore the symlink afterwards.
if [ -L "$ROOTFS/etc/resolv.conf" ]; then
  RESOLV_LINK=$(readlink "$ROOTFS/etc/resolv.conf")
  rm -f "$ROOTFS/etc/resolv.conf"
  cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
  RESOLV_WAS_LINK=1
fi
# The VM egress proxy resolves to an IPv6 address that works and an
# IPv4 pool that is dead from inside this chroot (apt under qemu
# picks IPv4). Pin the hostname to its IPv6 address, exactly as
# TermX's configure-rootfs.sh does; the pin is removed below and
# never ships in the image.
PROXY6=$(getent ahosts hatch-egress-proxy 2>/dev/null | awk '$1 ~ /:/ {print $1; exit}')
if [ -z "$PROXY6" ]; then
  PROXY6=$(awk '$1 == "nameserver" && $2 ~ /:/ {print $2; exit}' /etc/resolv.conf)
fi
HOSTS_PINNED=0
if [ -n "$PROXY6" ] && ! grep -q hatch-egress-proxy "$ROOTFS/etc/hosts"; then
  echo "$PROXY6 hatch-egress-proxy" >> "$ROOTFS/etc/hosts"
  HOSTS_PINNED=1
  echo "pinned hatch-egress-proxy to $PROXY6 in chroot /etc/hosts"
fi
if [ -n "$PROXY6" ] && [ -n "$http_proxy" ]; then
  PROXY6URL="${http_proxy/hatch-egress-proxy/[$PROXY6]}"
  export http_proxy="$PROXY6URL" https_proxy="$PROXY6URL" \
    HTTP_PROXY="$PROXY6URL" HTTPS_PROXY="$PROXY6URL" \
    ALL_PROXY="$PROXY6URL" all_proxy="$PROXY6URL"
  echo "chroot proxy pinned to IPv6 literal [$PROXY6]"
fi

# ---- run the additions inside the chroot
echo "== running opencode-guest-additions.sh in chroot"
chroot "$ROOTFS" /bin/bash /root/opencode-guest-additions.sh
echo "== additions done, cleaning up the chroot"
chroot "$ROOTFS" /bin/bash -c "apt-get clean; rm -rf /var/cache/apt/archives/*.deb /tmp/guest-dl /tmp/*.tar.gz /tmp/*.deb /root/opencode-guest-additions.sh /usr/bin/qemu-aarch64-static" || true
rm -f "$ROOTFS/root/opencode-guest-additions.sh" "$ROOTFS/usr/bin/qemu-aarch64-static"
rm -rf "$ROOTFS/tmp/guest-dl"
if [ "$HOSTS_PINNED" = 1 ]; then
  sed -i '/hatch-egress-proxy/d' "$ROOTFS/etc/hosts"
  echo "removed proxy pin from chroot /etc/hosts"
fi
if [ "$RESOLV_WAS_LINK" = 1 ]; then
  rm -f "$ROOTFS/etc/resolv.conf"
  ln -sf "$RESOLV_LINK" "$ROOTFS/etc/resolv.conf"
  echo "restored /etc/resolv.conf symlink -> $RESOLV_LINK"
fi
cleanup_mounts
trap - EXIT

# ---- pack the image (same sizing rule as TermX: used + 40%)
echo "== rootfs size"
du -sh "$ROOTFS"
USED_MB=$(du -sm "$ROOTFS" | cut -f1)
IMG_MB=$(( (USED_MB * 14 / 10 + 15) / 16 * 16 ))
[ "$IMG_MB" -lt 1024 ] && IMG_MB=1024
BLOCKS=$(( IMG_MB * 1024 ))
echo "== building ext4 image: ${IMG_MB} MiB ($BLOCKS 1K blocks)"
rm -f "$IMG"
mke2fs -t ext4 -L opencode-root -m 0 -d "$ROOTFS" "$IMG" "$BLOCKS"

echo "== e2fsck"
e2fsck -fn "$IMG"

echo "== debugfs spot checks"
debugfs -R "ls -l /usr/local/bin" "$IMG" 2>/dev/null
debugfs -R "ls -l /opt/OpenCode" "$IMG" 2>/dev/null | head -8
debugfs -R "ls -l /etc/systemd/system" "$IMG" 2>/dev/null | grep -i opencode
debugfs -R "stat /sbin/init" "$IMG" 2>/dev/null | head -3

echo "== permissions: image must be read-only (no write bits) for the runtime"
chmod 444 "$IMG"

echo "== gzip + hashes"
rm -f "$IMG.gz"
gzip -9 -k "$IMG"
ls -lh "$IMG" "$IMG.gz"
sha256sum "$IMG" "$IMG.gz" | tee "$PWD/SHA256SUMS"

echo "=== OpenCode guest image build finished $(date -u +%FT%TZ) ==="
