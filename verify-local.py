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
           "b1018c9357236ea2355bff488eda32171cc25c450997cccd7052b15992d3a8fa",
           "c7511200d3e23e21bcd68e63904e489b4724e24c263464e92c8dd72963a83e1f",
           "opencode-debian-trixie-arm64.ext4.gz.part00",
           "opencode-debian-trixie-arm64.ext4.gz.part11"]
for m in markers:
    check(f"string present: {m[:40]}", m in blob)
for i in range(1, 8):
    check(f"string present: Launch step {i}/7", f"Launch step {i}/7" in blob)
check("no TODO-FILL", "TODO-FILL" not in blob)
check("no BUILD-NOTE", "BUILD-NOTE" not in blob)
# New behaviour in this build
new_strings = ["Retrying in 60s", "Automatic retry: starting engine",
               "duplicate install ignored",
               "Auto-start: retrying after a failed start",
               "it tries again by itself",
               "Guest image not installed yet",
               "Show desktop",
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
               "Extracting the image",
               "Extraction:",
               "Extraction finished",
               "Background time expired during install",
               "Install paused",
               "Install complete",
               # Guest boot -1 fix (2026-11-25)
               "Canonicalized boot paths",
               "Boot paths:",
               "Boot pre-flight:",
               # Server-first bootstrap + desktop VT fix (2026-11-25)
               "server listening",
               "Server listening",
               "Server probe:",
               "Server probe failed:",
               "Starting server...",
               "Starting desktop...",
               "Server on 4096 confirmed",
               "DESKTOP READY",
               "desktop diagnostics",
               "Active VT:",
               "Could not load chats"]
for m in new_strings:
    check(f"new string present: {m}", m in blob)
# Removed controls must be gone as button titles
check("no 'Stop engine' string", "Stop engine" not in blob)
print(f"'Start engine' present: {'Start engine' in blob} "
      f"(expected absent; stateDescription uses other wording)")

print()
print("RESULT:", "ALL PASS" if not fails else f"FAILURES: {fails}")
sys.exit(1 if fails else 0)
