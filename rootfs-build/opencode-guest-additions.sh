#!/bin/bash
# OpenCode guest additions. Runs INSIDE the arm64 Debian chroot, AFTER
# TermX's rootfs-build/configure-rootfs.sh (same pattern as that file).
# Bakes into the image everything the OpenCode engine needs, because
# the Kernarium overlay is wiped every boot: nothing the server needs
# may be downloaded at first launch.
#
#   - Node 22 LTS arm64 v22.23.5 (official .tar.gz: the guest has
#     gzip but no xz, so no .tar.xz)
#   - OpenCode 2.3.0 release binary (anomalyco/opencode, NOT npm:
#     opencode-ai is the 1.x line and has no 2.3.0)
#   - gh, jq, ripgrep, socat (apt)
#   - bun (npm -g)
#   - Desktop UI mode: Xorg + openbox + Mesa/Virgl + the real
#     OpenCode Linux desktop app (official arm64 .deb, v2.3.0),
#     started by opencode-desktop.service (see below). The service
#     is DISABLED by default: the console bootstrap starts it in
#     Desktop UI mode and stops it in CLI mode.
#   - vsock proxy units (opencode-vsock-proxy*.service): socat
#     VSOCK-LISTEN -> TCP 127.0.0.1, the guest half of the bridge.
#
# The desktop .deb is the official OpenCode 2.3.0 Linux arm64 asset
# (opencode-desktop-linux-arm64.deb, 239,644,012 bytes, SHA-256
# d3645cb1402517c00f1979e835ab37b53d16b9812480b3443b08f65394a79db1,
# verified against the v2.3.0 release SHA256SUMS). The app binary
# inside it is /opt/OpenCode/ai.opencode (Electron); there is NO
# /usr/bin/opencode-desktop. The desktop app carries its own CLI
# copy at /opt/OpenCode/resources/opencode-cli and runs, or joins,
# the OpenCode 2 background service on port 4096 — so the console
# bootstrap starts the CLI server FIRST and the desktop app joins
# that same server (same sessions as the native iOS UI).
#
# Display stack: the base TermX image has NO mesa, NO Xorg, NO
# fonts. This script adds them all (xorg + modesetting driver +
# Mesa DRI/EGL/GBM + a font), because the desktop app cannot show
# anything without them. The guest kernel exposes the Virtio-GPU;
# guest Mesa talks Virgl to it.
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
DESKTOP_DEB="opencode-desktop-linux-arm64.deb"
DESKTOP_SHA256="d3645cb1402517c00f1979e835ab37b53d16b9812480b3443b08f65394a79db1"

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

echo "== apt update"
apt-get update -o Acquire::Queue-Mode=access || apt-get update -o Acquire::Queue-Mode=access

echo "== tools: gh jq ripgrep socat"
apt_install_retry gh jq ripgrep socat
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

echo "== Desktop UI mode: Xorg + openbox + Mesa/Virgl + fonts + Electron deps"
# xorg alone is not enough with --no-install-recommends: the Mesa
# DRI drivers, the modesetting video driver and the fonts are
# Recommends, so they are named explicitly. The rest is the desktop
# .deb's own Depends plus the Electron runtime libraries it needs
# beyond them (libdrm/libgbm/libxkbcommon and the X/atk/pango set).
apt_install_retry \
  xorg xserver-xorg-video-modesetting \
  libgl1-mesa-dri libglx-mesa0 libegl-mesa0 libgbm1 libdrm2 mesa-utils \
  fonts-dejavu-core \
  openbox \
  libgtk-3-0 libnotify4 libnss3 libxss1 libxtst6 libatspi2.0-0 libuuid1 \
  libsecret-1-0 xdg-utils libasound2 libxkbcommon0 libxcomposite1 \
  libxdamage1 libxrandr2 libatk1.0-0 libatk-bridge2.0-0 libcups2 \
  libdbus-1-3 libexpat1 libxcb1 libxext6 libxfixes3 libpango-1.0-0 \
  libcairo2

echo "== OpenCode desktop app $OPENCODE_VERSION (official arm64 .deb)"
cd /tmp
fetch_verified "$DESKTOP_DEB" "https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/$DESKTOP_DEB" "$DESKTOP_SHA256"
apt-get install -y ./$DESKTOP_DEB || (apt-get install -f -y && dpkg -i ./$DESKTOP_DEB)
rm -f $DESKTOP_DEB
# Fail loudly if the install did not land the real binary. The
# binary is /opt/OpenCode/ai.opencode; there is no opencode-desktop
# on PATH, and the old session script + bootstrap polled for it.
[ -x /opt/OpenCode/ai.opencode ] || {
  echo "FATAL: /opt/OpenCode/ai.opencode missing after .deb install" >&2
  exit 1
}
ls -l /opt/OpenCode/ai.opencode
[ -x /opt/OpenCode/resources/opencode-cli ] && echo "bundled CLI present: /opt/OpenCode/resources/opencode-cli"

echo "== vsock proxy + desktop systemd units"
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
cat > /etc/systemd/system/opencode-desktop.service <<'EOF'
[Unit]
Description=OpenCode desktop app session (Desktop UI mode)
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/opencode-desktop-session.sh
Restart=no
[Install]
WantedBy=multi-user.target
EOF
cat > /usr/local/bin/opencode-desktop-session.sh <<'EOF'
#!/bin/bash
# Desktop UI mode session: X on :0, openbox, then the real OpenCode
# desktop app. Started by opencode-desktop.service, which the console
# bootstrap starts in Desktop UI mode only. Prints DESKTOP READY to
# its own stdout (journal); the bootstrap's poll loop watches for the
# process + the X socket instead, and prints the marker the app
# watches for to the console.
#
# The CLI server is already running by the time this starts (the
# bootstrap starts it first); the desktop app joins that same server
# on 127.0.0.1:4096, so its sessions are the native UI's sessions.
export DISPLAY=:0
export XDG_RUNTIME_DIR=/run/user/1000
mkdir -p "$XDG_RUNTIME_DIR"
chown termux:termux "$XDG_RUNTIME_DIR" 2>/dev/null || true
# -ac: no X access control. Single-user guest, no TCP listener
# (-nolisten tcp), so the termux clients need no cookie file.
Xorg :0 -ac -noreset -nolisten tcp &
X_PID=$!
for _ in $(seq 1 30); do [ -S /tmp/.X11-unix/X0 ] && break; sleep 1; done
# sudo -u does not reliably keep DISPLAY, so pass the environment
# explicitly. The binary is /opt/OpenCode/ai.opencode (Electron).
# --no-sandbox: Electron's setuid sandbox cannot work in this
# guest. --disable-dev-shm-usage: /dev/shm is small in a 1024 MiB
# guest and Chromium uses it hard.
sudo -u termux env DISPLAY=:0 XDG_RUNTIME_DIR=/run/user/1000 openbox --sm-disable &
sudo -u termux env DISPLAY=:0 XDG_RUNTIME_DIR=/run/user/1000 HOME=/home/termux /opt/OpenCode/ai.opencode --no-sandbox --disable-dev-shm-usage &
APP_PID=$!
echo "DESKTOP READY (pid $APP_PID, X pid $X_PID)"
wait $APP_PID
kill $X_PID 2>/dev/null || true
EOF
chmod +x /usr/local/bin/opencode-desktop-session.sh
systemctl enable opencode-vsock-proxy.service opencode-vsock-proxy-8000.service
# opencode-desktop.service stays DISABLED: the console bootstrap
# starts it in Desktop UI mode only.
systemctl disable opencode-desktop.service || true

echo "== project dir (restored by the persistence sync; empty until then)"
mkdir -p /root/Projects

echo "== verify the new units parse"
systemd-analyze verify opencode-vsock-proxy.service opencode-vsock-proxy-8000.service opencode-desktop.service || echo "systemd-analyze verify reported issues (see above)"

echo "== versions"
node --version
opencode --version
git --version
python3 --version
jq --version
rg --version
socat -V | head -1
Xorg -version 2>&1 | head -1 || true
openbox --version | head -1
ls -l /opt/OpenCode/ai.opencode
echo "OPENCODE GUEST ADDITIONS DONE"
