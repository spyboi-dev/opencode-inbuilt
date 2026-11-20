# Boot base archive (vendored)

`uml-boot-base-aarch64.cpio.gz` is the guest boot base initramfs the
Kernarium runtime embeds (the static BusyBox + e2fsprogs base every Linux
guest boots through). It is built from upstream's pinned inputs
(Buildroot 2026.05.3 + BusyBox 1.38.0, `tools/rootfs/starter/build-all.sh
--product boot-base-aarch64`) on Linux — the macOS runner cannot build it,
and no published copy exists in any Kernarium release, so it is vendored
here. The copy in this directory was built 2026-11-20 from the pinned
Kernarium commit `fbe12ee` (see `KERNARIUM-BUILD.md`).

The runtime-tree CMake configure verifies it against
`tools/rootfs/boot-ramdisk/accepted-aarch64.env` (size + SHA-256). A locally
built base does not match the upstream descriptor (Buildroot output is not
bit-reproducible), so the workflow updates that descriptor in the cloned
checkout to this file's size and SHA-256 before configuring — the same
"accept" pattern used for the kernel descriptor. If this file is ever
rebuilt, update the workflow step's expectations (it reads the size and
hash from the file itself, so no edit is needed).
