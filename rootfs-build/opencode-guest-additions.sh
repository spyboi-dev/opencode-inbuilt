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
#   - Desktop UI mode: Xorg + openbox + the real OpenCode Linux
#     desktop app (arm64 .deb), started by opencode-desktop.service
#     (see rootfs-build/opencode-desktop.service). The service is
#     DISABLED by default: the console bootstrap starts it in
#     Desktop UI mode and stops it in CLI mode.
#   - vsock proxy units (opencode-vsock-proxy*.service): socat
#     VSOCK-LISTEN -> TCP 127.0.0.1, the guest half of the bridge.
#
# The desktop .deb asset name is the one the OpenCode 2 line
# publishes (opencode-desktop-linux-arm64.deb, verified against the
# v2.3.0 release assets; the desktop release can lag the CLI, so the
# build fails loudly here instead of shipping a guest without it).
# SPDX-License-Identifier: GPL-2.0-or-later
set -e
export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8

NODE_VERSION=22.23.5
OPENCODE_VERSION=2.3.0

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

echo "== Node $NODE_VERSION (official arm64 tarball)"
cd /tmp
curl -fsSL -o node.tar.gz "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-arm64.tar.gz"
tar -xzf node.tar.gz -C /usr/local --strip-components=1
rm -f node.tar.gz
node --version

echo "== OpenCode $OPENCODE_VERSION (release binary)"
cd /tmp
curl -fsSL -o opencode.tar.gz "https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/opencode-linux-arm64.tar.gz"
tar -xzf opencode.tar.gz -C /usr/local/bin opencode
chmod +x /usr/local/bin/opencode
rm -f opencode.tar.gz
opencode --version

echo "== bun (npm -g)"
npm install -g bun
bun --version

echo "== Desktop UI mode: Xorg + openbox + OpenCode desktop app"
apt_install_retry xorg openbox libgtk-3-0 libnss3 libasound2 libxss1 libxtst6
cd /tmp
curl -fsSL -o opencode-desktop.deb "https://github.com/anomalyco/opencode/releases/download/v${OPENCODE_VERSION}/opencode-desktop-linux-arm64.deb"
apt-get install -y ./opencode-desktop.deb || (apt-get install -f -y && dpkg -i opencode-desktop.deb)
rm -f opencode-desktop.deb
command -v opencode-desktop || ls /usr/bin/opencode* /opt/OpenCode* 2>/dev/null || true

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
export DISPLAY=:0
export XDG_RUNTIME_DIR=/run/user/1000
mkdir -p "$XDG_RUNTIME_DIR"
chown termux:termux "$XDG_RUNTIME_DIR" 2>/dev/null || true
Xorg :0 -noreset -nolisten tcp &
X_PID=$!
for _ in $(seq 1 30); do [ -S /tmp/.X11-unix/X0 ] && break; sleep 1; done
sudo -u termux openbox --sm-disable &
sudo -u termux opencode-desktop &
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

echo "== versions"
node --version
opencode --version
git --version
python3 --version
jq --version
rg --version
socat -V | head -1
echo "OPENCODE GUEST ADDITIONS DONE"
