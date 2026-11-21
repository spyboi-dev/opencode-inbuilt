#!/usr/bin/env python3
# Restore exact modes/owners from an ext4 image onto a debugfs-rdump
# extracted tree. rdump drops setuid/setgid/sticky bits (e.g. the
# image's /usr/bin/sudo is 4755 but lands as 0755), which would break
# sudo in the guest, so this re-applies every entry's mode and numeric
# uid:gid from the image's own `ls -l`. Also fails loudly if any image
# entry is missing from the extraction.
#
#   fixup-rdump-modes.py <image.ext4> <extracted-root>
#
# One debugfs call per directory. Symlinks are lchown'd, never chmod'd
# (Linux symlink modes are meaningless and chmod would follow the link).
# SPDX-License-Identifier: GPL-2.0-or-later
import os
import re
import subprocess
import sys
import time

IMG = sys.argv[1]
ROOT = sys.argv[2]

# /home is an overlayfs mount (metacopy=on): a file rdump left at
# 0:65534 (the unmapped overflow gid, after its own chown failed)
# cannot be chowned directly to its real owner — EPERM every time.
# Chowning it to 0:0 first unsticks it, and the real chown then
# succeeds. Every ownership change is retried with that intermediate
# step; failures are collected and reported at the end instead of
# dying on the first.
def apply_chown(target, uid, gid, is_link):
    fn = os.lchown if is_link else os.chown
    for attempt in range(3):
        try:
            fn(target, uid, gid)
            return True
        except PermissionError:
            try:
                fn(target, 0, 0)
            except PermissionError:
                pass
            time.sleep(0.2)
    return False


def apply_chmod(target, mode):
    for attempt in range(3):
        try:
            os.chmod(target, mode)
            return True
        except PermissionError:
            time.sleep(0.2)
    return False

LINE = re.compile(
    r"^\s*(\d+)\s+([0-9]+)\s+\(\d+\)\s+(\d+)\s+(\d+)\s+\d+\s+\S+\s+\S+\s+(.*)$"
)


def unescape_debugfs(name):
    # debugfs prints non-ASCII bytes in names as \xNN escapes, while
    # rdump writes the real UTF-8 bytes to disk. Decode the escapes
    # back to bytes first, or the two spellings never compare equal
    # (e.g. the NetLock Arany cert with Hungarian accents).
    raw = bytearray()
    i = 0
    while i < len(name):
        c = name[i]
        if c == "\\" and i + 3 < len(name) and name[i + 1] == "x":
            hexpart = name[i + 2:i + 4]
            if all(ch in "0123456789abcdefABCDEF" for ch in hexpart):
                raw.append(int(hexpart, 16))
                i += 4
                continue
        raw.extend(c.encode("utf-8", "surrogateescape"))
        i += 1
    return raw.decode("utf-8", "surrogateescape")


def ls_dir(image_path):
    out = subprocess.run(
        ["debugfs", "-R", "ls -l %s" % image_path, IMG],
        capture_output=True, text=True).stdout
    entries = []
    for line in out.splitlines():
        m = LINE.match(line)
        if not m:
            continue
        mode = int(m.group(2), 8)
        entries.append((unescape_debugfs(m.group(5)), mode, int(m.group(3)), int(m.group(4))))
    return entries


def is_symlink(mode):
    return (mode & 0o170000) == 0o120000


missing = []
failed = []
fixed_modes = 0
fixed_owners = 0
for dirpath, dirnames, filenames in os.walk(ROOT):
    rel = os.path.relpath(dirpath, ROOT)
    image_path = "/" if rel == "." else "/" + rel
    for name, mode, uid, gid in ls_dir(image_path):
        if name == "..":
            continue
        if name == ".":
            target = dirpath
        else:
            target = os.path.join(dirpath, name)
        if not os.path.lexists(target):
            missing.append(os.path.join(image_path, name))
            continue
        st = os.lstat(target)
        want_mode = mode & 0o7777
        if not is_symlink(mode):
            if (st.st_mode & 0o7777) != want_mode:
                if apply_chmod(target, want_mode):
                    fixed_modes += 1
                else:
                    failed.append("chmod %o %s" % (want_mode, target))
        if (st.st_uid, st.st_gid) != (uid, gid):
            if apply_chown(target, uid, gid, is_symlink(mode)):
                fixed_owners += 1
            else:
                failed.append("chown %d:%d %s" % (uid, gid, target))

print("fixup: %d modes corrected, %d owners corrected" % (fixed_modes, fixed_owners))
if failed:
    print("FATAL: %d ownership/mode changes still failing after retries:" % len(failed))
    for f in failed[:20]:
        print("  " + f)
    sys.exit(1)
if missing:
    print("FATAL: %d image entries missing from the extraction:" % len(missing))
    for m in missing[:20]:
        print("  missing: " + m)
    sys.exit(1)
print("fixup: extraction matches the image (no missing entries)")
