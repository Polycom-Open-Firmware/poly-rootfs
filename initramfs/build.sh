#!/usr/bin/env bash
# Build out/initramfs.cpio.gz from initramfs/init + a static busybox.
#
# Usage:
#   BUSYBOX=/path/to/busybox ./initramfs/build.sh
#   ./initramfs/build.sh                  # autodetect from ../work/rootfs/usr/bin/busybox
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$HERE/.." && pwd)"
OUT="${ROOT_DIR}/out"
mkdir -p "$OUT"

BUSYBOX="${BUSYBOX:-${ROOT_DIR}/work/rootfs/usr/bin/busybox}"
if [ ! -x "$BUSYBOX" ]; then
    echo "busybox not found at $BUSYBOX" >&2
    echo "set BUSYBOX=/path/to/busybox-static" >&2
    exit 1
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP"/{bin,sbin,etc,proc,sys,dev,run,sysroot}
install -m 0755 "$BUSYBOX" "$TMP/bin/busybox"

# Applets used by /init
for applet in sh mount umount mkdir cat grep sed cp ls switch_root sleep echo cut tr; do
    ln -sf busybox "$TMP/bin/$applet"
done

install -m 0755 "$HERE/init" "$TMP/init"

( cd "$TMP" && find . | cpio -o -H newc --quiet ) | gzip -9 > "$OUT/initramfs.cpio.gz"
echo "Wrote $OUT/initramfs.cpio.gz ($(stat -c%s "$OUT/initramfs.cpio.gz") bytes)"
