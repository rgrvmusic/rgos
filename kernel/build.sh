#!/usr/bin/env bash
# Build the RegrooveOS kernel: Raspberry Pi tree + CONFIG_PREEMPT_RT.
#
# Has run end to end: exit 0, staging a 24 MB kernel8.img (6.12.112-v8, PREEMPT_RT)
# with 25 device trees, 363 overlays and 1911 .ko.xz for the same version.
#
# Output lands in kernel/out/, which mkosi.finalize copies onto the boot
# partition.

set -euo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# PREEMPT_RT is mainlined as of 6.12, so 6.12 is the floor. Override to
# track a newer branch.
BRANCH=${KERNEL_BRANCH:-rpi-6.12.y}
REPO=${KERNEL_REPO:-https://github.com/raspberrypi/linux.git}
SRC=${KERNEL_SRC:-$HERE/linux}
OUT=${KERNEL_OUT:-$HERE/out}
DOWNLOAD=${KERNEL_DOWNLOAD:-$HERE/download}
TARBALL=$DOWNLOAD/linux-$BRANCH.tar.gz
TARBALL_URL=${KERNEL_TARBALL_URL:-https://codeload.github.com/raspberrypi/linux/tar.gz/refs/heads/$BRANCH}
JOBS=${JOBS:-$(nproc)}
CROSS=${CROSS_COMPILE:-aarch64-linux-gnu-}

# bcm2711_defconfig is the arm64 config the Pi Foundation ships, and the
# resulting kernel covers Pi 3/4/5 from one image. If Pi 5 / CM5 support
# turns out to be missing from it, bcm2712_defconfig is the alternative --
# at the cost of a second kernel per board.
DEFCONFIG=${DEFCONFIG:-bcm2711_defconfig}

command -v "${CROSS}gcc" >/dev/null || {
    echo "error: ${CROSS}gcc not found. Install an aarch64 cross toolchain," >&2
    echo "       or set CROSS_COMPILE= to point at one." >&2
    exit 1
}

# Fetch the source tree.
#
# The tarball is the default rather than `git clone`, and that is a workaround
# for a measured problem, not a preference. Behind a proxy that never closes
# the response, `git clone` hangs at the end of the pack transfer: observed as
# index-pack parked at 0% CPU for 13 minutes with a complete 210MB temp pack
# on disk and an idle socket. curl stops at Content-Length instead of waiting
# for EOF, so it finishes where git does not -- 236MiB in 52s here.
#
# There is deliberately no `-C -`. codeload ignores Range on this endpoint
# (measured: asking for 5MiB returned all 236MiB), so a resume would append a
# second copy onto the file rather than continue it. Retries restart from
# zero, which at the observed rate costs about a minute.
fetch_tarball() {
    mkdir -p "$DOWNLOAD"
    echo "==> fetching $TARBALL_URL"
    curl --fail --location --retry 5 --retry-delay 3 --retry-all-errors \
         --speed-limit 51200 --speed-time 30 \
         --output "$TARBALL" "$TARBALL_URL"
    gzip -t "$TARBALL"

    echo "==> extracting into $SRC"
    local tmp
    tmp=$(mktemp -d "$HERE/.extract.XXXXXX")
    tar -xzf "$TARBALL" -C "$tmp"
    rm -rf "$SRC"
    mv "$tmp"/linux-* "$SRC"
    rmdir "$tmp"
}

fetch_git() {
    echo "==> cloning $REPO ($BRANCH)"
    rm -rf "$SRC"
    git clone --depth 1 --branch "$BRANCH" "$REPO" "$SRC"
}

# A kernel tree is identified by its top-level Makefile. A directory without
# one is debris from an interrupted fetch -- a killed clone leaves a .git and
# a partial pack behind -- so it is discarded rather than half-reused.
if [ ! -f "$SRC/Makefile" ]; then
    [ -e "$SRC" ] && echo "==> discarding incomplete source tree at $SRC"

    case ${KERNEL_FETCH:-tarball} in
        tarball) fetch_tarball ;;
        git)     fetch_git ;;
        *)       echo "error: KERNEL_FETCH must be 'tarball' or 'git'" >&2; exit 1 ;;
    esac
fi

cd "$SRC"

echo "==> $DEFCONFIG"
make ARCH=arm64 CROSS_COMPILE="$CROSS" "$DEFCONFIG"

echo "==> merging rt.fragment"
# -m merges into .config without running a build; -O keeps paths local.
ARCH=arm64 CROSS_COMPILE="$CROSS" \
    scripts/kconfig/merge_config.sh -m -O . .config "$HERE/rt.fragment"

echo "==> olddefconfig (resolving fragment dependencies)"
make ARCH=arm64 CROSS_COMPILE="$CROSS" olddefconfig

# Fail loudly rather than shipping a silently non-realtime kernel: a
# PREEMPT_RT request that the solver dropped is easy to miss.
if ! grep -q '^CONFIG_PREEMPT_RT=y' .config; then
    echo "error: CONFIG_PREEMPT_RT did not survive olddefconfig." >&2
    echo "       Check that CONFIG_EXPERT=y and the branch is >= 6.12." >&2
    exit 1
fi

# Same reasoning as the check above, and it only bites in one combination, so
# it tests for that combination rather than for the symbol alone. A
# decompressor that did not survive olddefconfig is invisible until a module
# fails to load on the device, and then only if the image happens to lack
# liblzma.so.5 for kmod to dlopen. See rt.fragment.
if grep -q '^CONFIG_MODULE_COMPRESS_XZ=y' .config &&
   ! grep -q '^CONFIG_MODULE_DECOMPRESS=y' .config; then
    echo "error: modules are xz-compressed but the kernel cannot decompress them." >&2
    echo "       CONFIG_MODULE_DECOMPRESS did not survive olddefconfig, so no" >&2
    echo "       module would load unless the image ships liblzma.so.5 for kmod" >&2
    echo "       to dlopen. See rt.fragment." >&2
    exit 1
fi

# The rehosted userspace is 32-bit. Without this, a misaligned
# multi-word access in it is SIGBUS instead of being fixed up, and the failure
# only appears when the firmware runs on the device. A plain bool under an
# already-set CONFIG_COMPAT, but check anyway: a silent drop is invisible.
if ! grep -q '^CONFIG_COMPAT_ALIGNMENT_FIXUPS=y' .config; then
    echo "error: CONFIG_COMPAT_ALIGNMENT_FIXUPS is not set after olddefconfig." >&2
    echo "       32-bit misaligned multi-word accesses would fault with SIGBUS." >&2
    echo "       See rt.fragment." >&2
    exit 1
fi

echo "==> building"
make ARCH=arm64 CROSS_COMPILE="$CROSS" -j"$JOBS" Image dtbs modules

echo "==> staging into $OUT"
rm -rf "$OUT"
mkdir -p "$OUT/dts" "$OUT/overlays"

cp arch/arm64/boot/Image "$OUT/kernel8.img"
cp arch/arm64/boot/dts/broadcom/*.dtb "$OUT/dts/" 2>/dev/null || true
cp arch/arm64/boot/dts/overlays/*.dtbo "$OUT/overlays/" 2>/dev/null || true

# overlay_map.dtb is the firmware's per-SoC overlay routing table. The kernel
# builds it as an ordinary .dtb inside the overlays directory, so the *.dtbo
# glob above misses it, and the firmware looks for it at the boot partition
# ROOT -- not in overlays/. Ship it: overlays that have per-SoC variants use
# the routing.
#
# config.txt deliberately does not depend on it for KMS. On firmware
# 1.20250305 the generic dtoverlay=vc4-kms-v3d still resolved to the BCM2835
# overlay on a CM4 with this file present; that overlay's fragments do not
# match the BCM2711 tree, the firmware dropped it, and the display fell back
# to bcm2708_fb (HDMI0 only, and only after a cable replug). config.txt
# therefore names vc4-kms-v3d-pi4 / -pi5 directly in [pi4] / [pi5].
if [ -f arch/arm64/boot/dts/overlays/overlay_map.dtb ]; then
    cp arch/arm64/boot/dts/overlays/overlay_map.dtb "$OUT/"
else
    echo "warning: overlay_map.dtb was not built; dtoverlay=vc4-kms-v3d" >&2
    echo "         cannot select the board-specific KMS variant." >&2
fi

# Modules are not optional. bcm2711_defconfig builds the display stack
# (DRM_VC4 / DRM_V3D) and much of the SoC audio path as =m, and
# config.txt's dtoverlay=vc4-kms-v3d takes the display away from the
# firmware framebuffer -- so a modular-but-unstaged vc4 means no HDMI at
# all, not merely no acceleration.
#
# INSTALL_MOD_STRIP=1 drops debug info; unstripped modules run to hundreds
# of megabytes for no benefit on a device that will never run gdb.
#
# depmod runs here, on the host, against INSTALL_MOD_PATH. It is
# architecture-independent, so the host's depmod produces a correct
# modules.dep for the arm64 modules.
echo "==> installing modules"
make ARCH=arm64 CROSS_COMPILE="$CROSS" \
     INSTALL_MOD_PATH="$OUT/modules" INSTALL_MOD_STRIP=1 \
     -j"$JOBS" modules_install

# modules_install leaves build/ and source/ symlinks pointing back into this
# build tree, which does not exist inside the image. Left in place they are
# dangling, and depmod warns about them on the device.
KVER=$(make -s ARCH=arm64 CROSS_COMPILE="$CROSS" kernelrelease)
rm -f "$OUT/modules/lib/modules/$KVER/build" \
      "$OUT/modules/lib/modules/$KVER/source"

cat <<EOF

Staged:
    $OUT/kernel8.img
    $OUT/dts/        $(find "$OUT/dts" -name '*.dtb' | wc -l) device trees
    $OUT/overlays/   $(find "$OUT/overlays" -name '*.dtbo' | wc -l) overlays
    $OUT/overlay_map.dtb  firmware overlay routing (vc4-kms-v3d -> -pi4/-pi5)

    $OUT/modules/     kernel modules for $KVER, depmod'd and stripped

The boot path (MMC/SDHCI_IPROC, ext4, vfat, PL011 console) is built into the
kernel rather than modular, so the image can mount root without needing any
of these modules -- which is what makes it possible to boot with no initramfs.

Next: make build
EOF
