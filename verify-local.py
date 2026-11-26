#!/usr/bin/env python3
"""Independent host verification for a LOCALLY built OpenCode Kernarium IPA.
Reads the IPA zip directly (no extraction to /tmp, no otool — otool on
this Linux VM cannot parse these Mach-O binaries). Checks the binary
header, load commands, code-signature page hashes, embedded
frameworks, icons, and the marker strings the workflow + the build
require. Exits non-zero on any FAIL.
Usage: verify-local.py <ipa-path> [build-id] [expected-sdk, default 26.5.0]
"""
import hashlib
import plistlib
import re
import struct
import sys
import zipfile

IPA = sys.argv[1]
BUILD_ID = sys.argv[2] if len(sys.argv) > 2 else "dev"
EXPECTED_SDK = sys.argv[3] if len(sys.argv) > 3 else "26.5.0"
fails = []


def check(name, ok, detail=""):
    print(f"{'PASS' if ok else 'FAIL'}  {name}  {detail}")
    if not ok:
        fails.append(name)


z = zipfile.ZipFile(IPA)
names = z.namelist()
app_dir = next(n for n in names if n.startswith("Payload/") and ".app/" in n)
app_dir = app_dir[: app_dir.index(".app/") + 5]
print(f"app dir: {app_dir}")
binary = z.read(app_dir + "OpenCode")
print(f"binary bytes: {len(binary)}")

# --- Mach-O 64-bit header ---
(magic, cputype, _sub, filetype, ncmds, _sizeofcmds, _flags,
 _res) = struct.unpack("<8I", binary[:32])
check("magic 0xfeedfacf", magic == 0xFEEDFACF, f"{magic:#x}")
check("cputype arm64", cputype == 0x0100000C, f"{cputype:#x}")
check("filetype MH_EXECUTE", filetype == 2, f"{filetype}")
print(f"ncmds: {ncmds}")

segments = []
entryoff = None
minos = sdk = None
sig_off = sig_size = None
dylib_names = []
off = 32
for _ in range(ncmds):
    cmd, cmdsize = struct.unpack("<2I", binary[off:off + 8])
    if cmd == 0x19:  # LC_SEGMENT_64
        segname = binary[off + 8:off + 24].rstrip(b"\0").decode()
        segments.append(segname)
    elif cmd == 0x80000028:  # LC_MAIN
        entryoff, _stack = struct.unpack("<2Q", binary[off + 8:off + 24])
    elif cmd == 0x32:  # LC_BUILD_VERSION
        _plat, minos, sdk, _nt = struct.unpack("<4I", binary[off + 8:off + 24])
    elif cmd == 0x1D:  # LC_CODE_SIGNATURE
        sig_off, sig_size = struct.unpack("<2I", binary[off + 8:off + 16])
    elif cmd in (0x0C, 0x18, 0x1F, 0x80000022, 0x80000023):  # dylib loads
        nameoff = struct.unpack("<I", binary[off + 8:off + 12])[0]
        end = binary.index(b"\0", off + nameoff)
        dylib_names.append(binary[off + nameoff:end].decode(errors="replace"))
    off += cmdsize
print(f"segments ({len(segments)}): {segments}")
print(f"dylib load names: {dylib_names}")
check("5 segments", len(segments) == 5, str(len(segments)))
check("LC_MAIN entryoff 0x4000", entryoff == 0x4000, f"{entryoff:#x}" if entryoff is not None else "missing")


def ver(v):
    return f"{v >> 16}.{(v >> 8) & 0xFF}.{v & 0xFF}"


check("MinOS 15.0.0", minos is not None and ver(minos) == "15.0.0",
      ver(minos) if minos is not None else "missing")
check(f"SDK {EXPECTED_SDK}", sdk is not None and ver(sdk) == EXPECTED_SDK,
      ver(sdk) if sdk is not None else "missing")

# --- zero Kernarium load commands ---
fws = ["KRuntime_6_18_4K", "KosmicKrisp", "MesaEGL", "MesaGallium"]
bad = [n for n in dylib_names if any(f in n for f in fws)]
check("zero Kernarium load commands", not bad, str(bad))

# --- code signature: verify every SHA-256 page hash ---
assert sig_off is not None and sig_size is not None, "no LC_CODE_SIGNATURE"
sig = binary[sig_off:sig_off + sig_size]
smagic, slen, count = struct.unpack(">3I", sig[:12])
check("superblob magic", smagic == 0xFADE0CC0, f"{smagic:#x}")
cd_off = None
for i in range(count):
    typ, o = struct.unpack(">2I", sig[12 + i * 8:20 + i * 8])
    if typ == 0:
        cd_off = o
assert cd_off is not None, "no CodeDirectory (slot 0)"
cd = sig[cd_off:]
cmagic, clen, _ver, _flags, hash_off, _ident, n_special, n_code, code_limit = \
    struct.unpack(">9I", cd[:36])
hash_size, hash_type, _plat, page_bits = struct.unpack(">4B", cd[36:40])
check("CodeDirectory magic", cmagic == 0xFADE0C02, f"{cmagic:#x}")
check("hash type SHA-256", hash_type == 2 and hash_size == 32,
      f"type={hash_type} size={hash_size}")
page_size = 1 << page_bits
print(f"code slots: {n_code} special: {n_special} codeLimit: {code_limit} "
      f"pageSize: {page_size}")
ok_pages = 0
for i in range(n_code):
    start = i * page_size
    end = min(start + page_size, code_limit)
    # Hash array: code-slot hashes come first (page i at index i);
    # the special-slot hashes follow them. (The "special first"
    # reading fails 0/130 on this binary; page 0's hash sits at
    # array offset 0, verified directly.)
    want = cd[hash_off + i * hash_size:
              hash_off + (i + 1) * hash_size]
    got = hashlib.sha256(binary[start:end]).digest()
    if got == want:
        ok_pages += 1
check("code signature page hashes", ok_pages == n_code,
      f"{ok_pages}/{n_code}")

# --- embedded frameworks + icons ---
fw_dirs = sorted({n.split("/")[3] for n in names
                  if n.startswith(app_dir + "Frameworks/")
                  and ".framework/" in n})
print(f"embedded frameworks: {fw_dirs}")
for f in fws:
    check(f"framework embedded: {f}", f"{f}.framework" in fw_dirs)
icons = sorted(n.split("/")[-1] for n in names
               if n.startswith(app_dir) and n.endswith(".png"))
print(f"app PNGs: {icons}")
check("AppIcon1024.png present", "AppIcon1024.png" in icons)
check("OpenCodeLogo.png present", "OpenCodeLogo.png" in icons)
check("4+ icon PNGs", len([i for i in icons if i.startswith("AppIcon")]) >= 4,
      str(len([i for i in icons if i.startswith("AppIcon")])))

# --- Info.plist ---
info = plistlib.loads(z.read(app_dir + "Info.plist"))
print(f"bundle: {info.get('CFBundleIdentifier')} "
      f"version {info.get('CFBundleShortVersionString')}")

# --- strings (substring search, like grep -q: a marker is usually
# inside a longer literal, e.g. 'Launch step 1/7: ...') ---
runs = [m.group(0).decode() for m in re.finditer(rb"[ -~]{4,}", binary)]
# NSString literals containing a non-ASCII char (e.g. the em dash)
# are emitted as UTF-16 in __TEXT,__ustring: also pull those runs.
runs += [m.group(0).decode("utf-16-le")
         for m in re.finditer(rb"(?:[\x20-\x7e]\x00){4,}", binary)]
blob = "\n".join(runs)
strings = set(runs)
markers = ["DYLD OK", "BOOT.txt", "Calling UIApplicationMain",
           "AppDelegate +initialize", "AppDelegate -init done",
           "Scene config requested", "Window attached to scene",
           "Window attached to scene (poll)", "App became active",
           "Continue to app", BUILD_ID,
           "68dfee689d778c4628a5b91d4afc274b7b0910dddc41234a20904ef1a1cd434e",
           "70d25c189d42b62ee39e0e2366eff854bb925c17ed4491ee653b15092f045358",
           "opencode-debian-trixie-arm64.ext4.gz.part00",
           "opencode-debian-trixie-arm64.ext4.gz.part04"]
for m in markers:
    check(f"string present: {m[:40]}", m in blob)
for i in range(1, 8):
    check(f"string present: Launch step {i}/7", f"Launch step {i}/7" in blob)
check("no TODO-FILL", "TODO-FILL" not in blob)
check("no BUILD-NOTE", "BUILD-NOTE" not in blob)
# The `systemctl stop opencode-desktop` line is gone: on 977334d
# the shell never got past it (systemctl can block on D-Bus for
# up to 90 s), so X never started. Only the source comment may
# mention it; the binary must not contain the command.
check("no 'systemctl stop opencode-desktop' command", "systemctl stop opencode-desktop" not in blob)
# New behaviour in this build
new_strings = ["Retrying in 60s", "Automatic retry: starting engine",
               "duplicate install ignored",
               "Auto-start: retrying after a failed start",
               "it tries again by itself",
               "Not installed yet",
               "Show terminal",
               # TermX auto-start/update port (2026-11-23)
               "Update available",
               "Image update check",
               "Booting installed image as-is",
               "Auto-start held",
               "the download is damaged",
               "guest image is damaged",
               # Background-session download (2026-11-24)
               "Background URL session",
               "Download part",
               "footprint",
               "not enough free space",
               "Resuming part",
               "MEMORY WARNING during download",
               "Download verified",
               # Extraction crash fix (2026-11-25)
               "Archive already downloaded and verified",
               "Extraction:",
               "Extraction finished",
               "Background time expired during install",
               "Install paused",
               "Install complete",
               # Guest boot -1 fix (2026-11-25)
               "Canonicalized boot paths",
               "Boot paths:",
               "Boot pre-flight:",
               # Server-first bootstrap (2026-11-25)
               "server listening",
               "Server listening",
               "Server probe:",
               "Server probe failed:",
               "Starting server...",
               "Starting terminal...",
               "Server on 4096 confirmed",
               "CLI READY",
               "cli diagnostics",
               "Active VT:",
               "Could not load chats",
               # Chat opens the terminal (2026-11-26): the desktop
               # is gone, the CLI TUI is the in-app UI; tapping a
               # chat opens the Terminal view.
               "Terminal view shown:",
               # Diagnostics via server (2026-11-25): the console
               # drops output once the TUI takes over, so the
               # diagnostics come over HTTP instead. The snapshot
               # names the server and the TUI, not Xorg.
               "DIAG ",
               "UML_GPU_DISPLAY_ACTIVITY_LOG",
               "display-activity.log",
               "Display log (runtime)",
               "cli-diag.txt",
               "Guest diagnostics (via server)",
               "fetchGuestDiagnosticsIfNeeded",
               # Two-phase bootstrap (2026-11-25): the 977334d logs
               # prove the whole 5 KB bootstrap typed at once
               # overflows the tty input buffer while the shell is
               # blocked in the curl loop, so the middle is dropped
               # (the shell never got past `systemctl stop`, the
               # desktop never started, no diagnostics file).
               # Phase 2 goes only after the server probe first
               # succeeds, and the diagnostics are a script
               # refreshed every 10 s.
               "cliBootstrap",
               "CLI launch started",
               "diag-snapshot.sh",
               "diag-loop.sh",
               "Guest diagnostics not available via server yet (attempt ",
               # Server-file delivery of the CLI bootstrap
               # (df597d2 logs: typing the 4.5 KB script dropped
               # bytes even into an idle shell — the diag-snapshot
               # heredoc opener was lost, the fbdev.conf heredoc
               # was mangled, and the ai.opencode line split
               # mid-flag so `gpu` exited 127). The script is
               # written through the server's file API and only
               # the one-line `sh` is typed; console typing is
               # the fallback if the write fails.
               "cli-bootstrap.sh",
               "experimental/fs/write",
               "CLI bootstrap write failed",
               "sh /tmp/cli-bootstrap.sh",
               # Repeated diagnostics fetching (25bb172 logs: the
               # only fetched block was the first snapshot, taken
               # before the TUI started, and the later snapshots
               # naming the TUI's fate were never read). The fetch
               # now repeats every 10 s and logs a block only
               # when its content changed.
               "lastGuestDiagnosticsText",
               "Guest diagnostics (via server) [fetch ",
               "DIAG loop:",
               "DIAG tui:",
               "DIAG server:",
               "/home/termux/cli-diag.txt",
               # CLI TUI (2026-11-26): the desktop is gone. The
               # TUI runs on tty1 (the framebuffer VT the Terminal
               # view shows), sized from `stty size` on tty1
               # (161x174 on the 1290x2796 framebuffer, fallback
               # if narrow), and adopts the already-running serve
               # through the service registration, same as the
               # desktop did. Phase 1 is typed only after the
               # autologin shell prompt ("termux@termx") is seen
               # on the serial console (ttyS0) — typing it into
               # getty eats it as login attempts (dceea4c).
               "Shell prompt seen on the guest console",
               "Phase 1 sent (shell prompt seen)",
               "no shell prompt on the guest console after 30 s",
               "setsid",
               "getty@tty1",
               "Terminal size:",
               "CLI ready (from guest console)",
               "ERROR CLI did not start",
               "CLI exited",
               "Terminal ready",
               # Termx-Kernel fork adoption (2026-11-26): the app
               # runs the fork framework (API 46) and starts the
               # general localhost proxy next to the two vsock
               # bridges. The guest bridge is not in the image
               # yet, so the proxy is dormant: it listens, the
               # auto-mirror gives up after a few failed polls
               # with one log line, and nothing crashes or spams.
               "Localhost proxy: listening on 127.0.0.1 for ports",
               "Localhost proxy: stopped",
               "Localhost proxy: guest bridge not answering",
               "Localhost ports",
               "restartLocalhostProxy",
               # Fetch fix (2026-11-25): the e001c27
               # "Failed to fetch" error page is a client
               # fetching its OWN sidecar. A plain serve
               # writes no service registration, so a client
               # spawns its own sidecar on 49374 and the fetch
               # fails. Serve now runs in --service mode with
               # the config pre-written with the Keychain
               # password, so the TUI adopts our already-up
               # server on 4096 instead. The V8 JIT
               # check that 77b9a2f added is removed (2026-11-26):
               # it answered the question (JIT works, see
               # KERNARIUM-BUILD.md) and cost ~2-3 s before
               # serve on every boot.
               # Boot regression fix (2026-11-26): the health
               # timer now starts on the guest's "server
               # listening" marker and probes at once, with a
               # 20 s fallback if the marker never arrives; the
               # health probe has a 5 s timeout (a pre-ready
               # probe hung the full 30 s through the vsock
               # bridge in 77b9a2f, healthy at 41 s).
               "serve --service",
               "opencode/service.json",
               "--hostname 127.0.0.1",
               "Health probe starting (server listening in guest)",
               "Health timer fallback"]
for m in new_strings:
    check(f"new string present: {m}", m in blob)
# The old plain serve on 0.0.0.0 is gone: it wrote no service
# registration, so a client would spawn its own sidecar.
check("no plain serve on 0.0.0.0", "serve --port 4096 --hostname 0.0.0.0" not in blob)
# The V8 JIT check is removed from the boot path (2026-11-26):
# it answered the question (JIT works) and cost ~2-3 s before serve.
check("no JIT probe node command", "node --jitless" not in blob)
check("no JIT probe output marker", "JIT probe default:" not in blob)
# The proxy is an adaptation of TermX's, not a copy: no TermX
# identifiers may leak into this binary (wrong defaults key,
# wrong log prefix, wrong queue label).
for m in ["termx.localhostPorts", "TXLocalhostProxy",
          "app.termx.ios.localhost-proxy"]:
    check(f"no TermX proxy leftover: {m}", m not in blob)
# Removed controls must be gone as button titles
check("no 'Stop engine' string", "Stop engine" not in blob)
# Slop removal (2026-11-25): the removed UI strings must be gone
for m in ["JITless", "LinuxRunner", "inbuilt",
          "Real OpenCode 2.3.0, inside this app",
          "Guest image not installed yet",
          "Downloading guest image part",
          "Guest core linked",
          "Debian 13 guest",
          "The engine cannot start in this build",
          "Not ready in this build",
          "inside the guest",
          "guest workspace",
          "Guest ready",
          "Verifying the image",
          "Booting guest",
          # 1bf4c3a Settings card restyle, reverted 2026-11-25: Settings
          # must match the Integrations page (plain inset grouped
          # table), no glyph tiles, no header card.
          "Server connection, agent, providers and app info.",
          "server.rack",
          "plug"]:
    check(f"slop gone: {m}", m not in blob)
# Non-ASCII UI strings live in the binary as UTF-16LE (the blob runs
# break at the ellipsis), so check the raw bytes directly.
for m in ["Extracting…", "Verifying…", "Starting…"]:
    check(f"utf16 string present: {m}", m.encode("utf-16-le") in binary)
check("slop gone: Extracting the image…",
      "Extracting the image…".encode("utf-16-le") not in binary)
# Location prompts (Info.plist, not the binary): no implementation names
usage = (info.get('NSLocationWhenInUseUsageDescription') or '') + \
        (info.get('NSLocationAlwaysAndWhenInUseUsageDescription') or '')
check("no 'Linux engine' in location prompts", "Linux engine" not in usage)
print(f"'Start engine' present: {'Start engine' in blob} "
      f"(expected absent; stateDescription uses other wording)")

print()
print("RESULT:", "ALL PASS" if not fails else f"FAILURES: {fails}")
sys.exit(1 if fails else 0)
