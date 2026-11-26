#!/bin/bash
# OpenCode guest additions (SLIM). Runs INSIDE the arm64 Debian chroot,
# after the TermX slim rootfs is copied to work/rootfs-slim (cp -a +
# fixup-rdump-modes.py against termx-debian-trixie-arm64-slim.ext4).
# Bakes into the image everything the OpenCode engine needs, because
# the Kernarium overlay is wiped every boot: nothing the server needs
# may be downloaded at first launch.
#
# Base: TermX slim (termx-debian-trixie-arm64-slim.ext4) — 173
# packages, 500 MB used — NOT the full TermX image. The slim base's
# user is `termx` and its hostname is `iphone`; the OpenCode app
# expects user `termux` and host `termx` (the console prompt the app
# watches for is "termux@termx", and the bootstrap writes to
# /home/termux), so this script renames the user and the hostname
# FIRST, before anything else.
#
#   - Node 22 LTS arm64 v22.23.5 (official .tar.gz: the guest has
#     gzip but no xz, so no .tar.xz)
#   - OpenCode 2.3.0 release binary (anomalyco/opencode, NOT npm:
#     opencode-ai is the 1.x line and has no 2.3.0)
#   - gh, jq, ripgrep, socat, git, python3 (apt; the slim base has
#     neither git nor python3)
#   - bun (npm -g)
#   - vsock proxy units (opencode-vsock-proxy*.service): socat
#     VSOCK-LISTEN -> TCP 127.0.0.1, the guest half of the bridge.
#   - localhost bridge (tx-vsock-bridge, from the Termx-Kernel fork):
#     vsock 5999 -> guest 127.0.0.1, the guest half of the host
#     LocalhostProxy. The binary is prebuilt on the host
#     (aarch64-linux-gnu-gcc -static -O2, stripped) and copied into
#     /tmp/guest-dl/ by build-opencode-image.sh; its SHA-256 is pinned
#     below. (The slim base already ships a byte-identical bridge;
#     this reinstalls the fork's canonical copy and service file.)
#
# NO desktop stack: the desktop UI is gone (CLI build dceea4c). No
# Xorg, no openbox, no Mesa, no fonts, no Electron .deb. That is the
# whole point of this slim image.
#
# Downloads: each archive is SHA-256 pinned below. The image build
# pre-downloads them on the host into /tmp/guest-dl/ and this script
# uses the local copy when it is present and matches; otherwise it
# downloads with curl (and still verifies the hash, failing loudly
# on mismatch instead of shipping a guest without the app).
# SPDX-License-Identifier: GPL-2.0-or-later
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8

NODE_VERSION=22.23.5
OPENCODE_VERSION=2.3.0
NODE_TARBALL="node-v${NODE_VERSION}-linux-arm64.tar.gz"
NODE_SHA256="8bd3dc69eee8f3f226315a80d7d1d4faccf217a4c8fae500168ac2e38f3bdba3"
CLI_TARBALL="opencode-linux-arm64.tar.gz"
CLI_SHA256="3207fb5cdec448d479242c0f1a14f4f7bdfcad3a79209b5eb8f9003725e93711"
BRIDGE_BIN="tx-vsock-bridge"
BRIDGE_SHA256="bdd381e0cc8d7ca2ccf9feef6843cbeaaba54e437215c8d286f405f3d4ba9fb4"

# Fetch a file into /tmp, from the pre-downloaded host copy when
# present, else by curl. Verifies the SHA-256 either way; a
# mismatch is fatal, so a bad download can never silently ship.
fetch_verified() {
  local name="$1" url="$2" sha="$3"
  local dest="/tmp/$name"
  if [ -f "/tmp/guest-dl/$name" ]; then
    echo "using pre-downloaded /tmp/guest-dl/$name"
    cp "/tmp/guest-dl/$name" "$dest"
  else
    echo "downloading $url"
    curl -fsSL -o "$dest" "$url"
  fi
  echo "$sha  $dest" | sha256sum -c - || {
    echo "SHA-256 mismatch for $name (expected $sha)" >&2
    return 1
  }
}

apt_install_retry() {
  local i
  for i in 1 2 3; do
    echo "apt-get install (attempt $i/3)"
    if apt-get install -o Acquire::Queue-Mode=access -y --no-install-recommends "$@"; then
      return 0
    fi
    echo "apt-get install failed (attempt $i/3), retrying in 15s..."
    sleep 15
  done
  echo "apt-get install still failing after 3 attempts" >&2
  return 1
}

echo "== rename slim user termx -> termux, hostname iphone -> termx"
# The slim base ships user `termx` (home /home/termx) and hostname
# `iphone`; the app expects user `termux`, home /home/termux, host
# `termx` (the console prompt it watches for is "termux@termx", and
# the bootstrap writes the service config and diagnostics to
# /home/termux). Rename every user record, move the home dir, fix
# the autologin drop-in and the sudoers file, then set the hostname.
sed -i 's|^termx:x:1000:1000::/home/termx:/bin/bash$|termux:x:1000:1000::/home/termux:/bin/bash|' /etc/passwd
sed -i 's/^termx:x:1000:$/termux:x:1000:/' /etc/group
sed -i 's/:termx$/:termux/' /etc/group
sed -i 's/^termx:/termux:/' /etc/shadow
sed -i 's/^termx:/termux:/' /etc/gshadow
sed -i 's/^termx:/termux:/' /etc/subuid /etc/subgid
mv /etc/sudoers.d/termx /etc/sudoers.d/termux
sed -i 's/^termx /termux /' /etc/sudoers.d/termux
sed -i 's/--autologin termx/--autologin termux/' /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf
mv /home/termx /home/termux
echo termx > /etc/hostname
sed -i 's/^127.0.1.1 iphone$/127.0.1.1 termx/' /etc/hosts
# Prove the rename before anything else depends on it.
grep -q '^termux:x:1000:1000::/home/termux:/bin/bash$' /etc/passwd || { echo "FATAL: passwd rename failed" >&2; exit 1; }
[ -d /home/termux ] || { echo "FATAL: /home/termux missing after rename" >&2; exit 1; }
grep -q -- '--autologin termux' /etc/systemd/system/serial-getty@ttyS0.service.d/autologin.conf || { echo "FATAL: autologin rename failed" >&2; exit 1; }
[ "$(cat /etc/hostname)" = termx ] || { echo "FATAL: hostname rename failed" >&2; exit 1; }
id termux
echo "rename done: user termux, home /home/termux, host termx"

echo "== apt update"
apt-get update -o Acquire::Queue-Mode=access || apt-get update -o Acquire::Queue-Mode=access

echo "== tools: gh jq ripgrep socat git python3"
# The slim base has neither git nor python3; the agent shells out to
# git and the diagnostics use python3, so both are installed here.
apt_install_retry gh jq ripgrep socat git python3
# The whole vsock bridge depends on socat's VSOCK-LISTEN. Trixie's
# socat has it, but prove it here instead of finding out on device.
socat -hh 2>&1 | grep -q "VSOCK-LISTEN" || {
  echo "FATAL: socat in this image has no VSOCK-LISTEN support" >&2
  exit 1
}
echo "socat VSOCK-LISTEN confirmed"

echo "== Node $NODE_VERSION (official arm64 tarball)"
cd /tmp
fetch_verified "$NODE_TARBALL" "https://nodejs.org/dist/v${NODE_VERSION}/$NODE_TARBALL" "$NODE_SHA256"
tar -xzf "$NODE_TARBALL" -C /usr/local --strip-components=1
rm -f "$NODE_TARBALL"
node --version

echo "== OpenCode $OPENCODE_VERSION (release binary)"
cd /tmp
fetch_verified "$CLI_TARBALL" "https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/$CLI_TARBALL" "$CLI_SHA256"
tar -xzf "$CLI_TARBALL" -C /usr/local/bin opencode
chmod +x /usr/local/bin/opencode
rm -f "$CLI_TARBALL"
opencode --version

echo "== bun (npm -g)"
npm install -g bun
bun --version

echo "== vsock proxy + localhost bridge systemd units"
# The unit files are written here (not copied in) so this script is
# self-contained inside the chroot.
cat > /etc/systemd/system/opencode-vsock-proxy.service <<'EOF'
[Unit]
Description=OpenCode vsock proxy (server port 4096)
After=network.target
[Service]
ExecStart=/usr/bin/socat VSOCK-LISTEN:4096,fork TCP:127.0.0.1:4096
Restart=on-failure
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
cat > /etc/systemd/system/opencode-vsock-proxy-8000.service <<'EOF'
[Unit]
Description=OpenCode vsock proxy (app.py port 8000)
After=network.target
[Service]
ExecStart=/usr/bin/socat VSOCK-LISTEN:8000,fork TCP:127.0.0.1:8000
Restart=on-failure
RestartSec=2
[Install]
WantedBy=multi-user.target
EOF
# Localhost bridge: the guest half of the host LocalhostProxy.
# The binary is prebuilt on the host (fork source, static) and the
# service file is the fork's own file; both are copied into
# /tmp/guest-dl/ by build-opencode-image.sh. Verify the binary's
# SHA-256 before installing; a mismatch is fatal.
[ -f "/tmp/guest-dl/$BRIDGE_BIN" ] || { echo "FATAL: /tmp/guest-dl/$BRIDGE_BIN not found" >&2; exit 1; }
echo "$BRIDGE_SHA256  /tmp/guest-dl/$BRIDGE_BIN" | sha256sum -c - || { echo "FATAL: tx-vsock-bridge SHA-256 mismatch" >&2; exit 1; }
install -m 0755 "/tmp/guest-dl/$BRIDGE_BIN" /usr/local/bin/tx-vsock-bridge
[ -f /tmp/guest-dl/tx-vsock-bridge.service ] || { echo "FATAL: tx-vsock-bridge.service not found in /tmp/guest-dl" >&2; exit 1; }
install -m 0644 /tmp/guest-dl/tx-vsock-bridge.service /etc/systemd/system/tx-vsock-bridge.service
systemctl enable opencode-vsock-proxy.service opencode-vsock-proxy-8000.service tx-vsock-bridge.service

echo "== project dir (restored by the persistence sync; empty until then)"
mkdir -p /root/Projects

echo "== verify the new units parse and are enabled"
systemd-analyze verify opencode-vsock-proxy.service opencode-vsock-proxy-8000.service tx-vsock-bridge.service || echo "systemd-analyze verify reported issues (see above)"
systemctl is-enabled opencode-vsock-proxy.service opencode-vsock-proxy-8000.service tx-vsock-bridge.service

echo "== versions"
node --version
opencode --version
git --version
python3 --version
jq --version
rg --version
socat -V | head -1
ls -l /usr/local/bin/tx-vsock-bridge
echo "OPENCODE GUEST ADDITIONS DONE"
