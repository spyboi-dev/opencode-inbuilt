# OpenCode guest image additions

`opencode-guest-additions.sh` runs INSIDE the arm64 Debian chroot,
after TermX's `rootfs-build/configure-rootfs.sh`. It bakes in
everything the Kernarium engine needs (the overlay is wiped every
boot, so the server must never download at first launch):

- Node 22.23.5, OpenCode CLI 2.3.0, `gh jq ripgrep socat`, `bun`
- Desktop UI mode: Xorg + openbox + the real OpenCode Linux desktop
  app (arm64 `.deb`), with `opencode-desktop.service` (disabled by
  default; the console bootstrap starts it in Desktop UI mode) and
  the `opencode-vsock-proxy*.service` units (guest half of the
  host<->guest bridge)

The unit files and the session script are written by the script
itself (heredocs), so it is self-contained inside the chroot. Run it
from the same chroot session as `configure-rootfs.sh`, before the
image is packed, then record the `.ext4.gz` SHA-256 in
`src/OCGuestInstall.m` (`kOCGuestImageGzSHA256` /
`kOCGuestImageSHA256`) and publish the archive at the URL there.

Status 2026-11-20: the TermX image build is unfinished (apt fetches
failing through the VM proxy, hashes still TODO), so this script has
not run yet and no image exists. The app refuses to boot until the
hashes are real.
