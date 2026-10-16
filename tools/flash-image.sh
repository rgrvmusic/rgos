#!/usr/bin/env bash
# flash-image.sh -- write a built RegrooveOS image to a card, grow the root
# filesystem to fill it, and check the result.
#
# This is the only tool in the tree that writes to a block device, and it is
# deliberately not a make(1) target: TARGET is an argument you have to type,
# because dd to the wrong disk has no undo.
#
# The sequence was proven by hand on a 256G card:
#
#   dd -> partprobe -> sgdisk -e -> parted resizepart -> partprobe
#      -> e2fsck -f -y -> resize2fs
#
# sgdisk -e is not optional. The image is smaller than the card, so the backup
# GPT it carries points at the image's old last sector. Until it is moved to
# the real end of the device every partitioning tool reports a disk whose
# backup header is in the wrong place; parted's resizepart moves the partition
# entry but leaves that header alone.
#
# The image's boot files are compared with mkosi.extra/boot/firmware/ before
# anything is written. mkosi copies that tree at build time, so an image built
# before a config.txt change silently carries the old file -- which is exactly
# how a freshly flashed card ended up without the PCM5122 overlay. By default
# this script refuses that combination and asks for a rebuild;
# --sync-boot-config copies the current files onto the card instead, for when
# a rebuild is not what you want.
#
# tools/check-image.sh inspects the image before writing and the card
# afterwards, so a broken build does not cost the card's contents and a bad
# write does not go unnoticed.
#
# usage: sudo tools/flash-image.sh [options] TARGET

set -euo pipefail

SELF=$(readlink -f "${BASH_SOURCE[0]}")
REPO=$(cd -- "$(dirname -- "$SELF")/.." && pwd)
# The argument parser consumes its positional parameters, and the sudo
# re-exec below needs the originals: re-running the script with an empty "$@"
# would print usage and exit 2 instead of flashing anything.
ORIG_ARGS=("$@")

IMAGE="$REPO/build/regrooveos_1.raw"
GROW=1
SYNC_BOOT=0
UNMOUNT=0
ASSUME_YES=0
TARGET=""

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
usage: sudo tools/flash-image.sh [options] TARGET

Write a built RegrooveOS image to TARGET (a whole block device such as
/dev/sdd), grow the root filesystem to fill it, and check the result.

options:
  -i, --image PATH       image to write (default: build/regrooveos_1.raw)
      --dev              use build/regrooveos-dev_1.raw (the loginable image)
      --no-grow          leave the root filesystem at its built size
      --sync-boot-config copy mkosi.extra/boot/firmware/ onto the card when
                         the image predates it
      --unmount          unmount anything mounted from TARGET first
  -y, --yes              do not ask for confirmation
  -h, --help             this text

TARGET must be the whole disk, not a partition. Writing is refused when the
image's boot files differ from mkosi.extra/boot/firmware/, so an image that
predates a config.txt change cannot silently produce a card without that
change. Rebuild with 'make build' (or 'make dev'), or pass --sync-boot-config
to patch the card instead.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        -i|--image)
            if [ $# -lt 2 ]; then die "$1 needs a path"; fi
            IMAGE=$2
            shift 2
            ;;
        --dev)
            IMAGE="$REPO/build/regrooveos-dev_1.raw"
            shift
            ;;
        --no-grow)          GROW=0;        shift ;;
        --sync-boot-config) SYNC_BOOT=1;   shift ;;
        --unmount)          UNMOUNT=1;     shift ;;
        -y|--yes)           ASSUME_YES=1;  shift ;;
        -h|--help)          usage; exit 0 ;;
        -*)                 die "unknown option: $1" ;;
        *)
            if [ -n "$TARGET" ]; then die "only one TARGET may be given"; fi
            TARGET=$1
            shift
            ;;
    esac
done

if [ -z "$TARGET" ]; then
    usage >&2
    exit 2
fi

TARGET=$(readlink -f "$TARGET")
case "$IMAGE" in
    /*) ;;
    *) IMAGE="$PWD/$IMAGE" ;;
esac

# Checks that need no privileges, done before asking for a password so that a
# typo in the device or image name fails immediately.
if [ ! -e "$TARGET" ]; then die "no such device: $TARGET"; fi
if [ ! -b "$TARGET" ]; then die "$TARGET is not a block device"; fi
target_type=$(lsblk -dno TYPE "$TARGET" 2>/dev/null || true)
if [ "$target_type" != disk ] && [ "$target_type" != loop ]; then
    die "$TARGET is not a whole device (pass the disk, not a partition)"
fi
if [ ! -f "$IMAGE" ]; then
    die "no image at $IMAGE (build one with 'make build' or 'make dev')"
fi

# Everything below touches devices or mounts. Re-exec under sudo rather than
# sprinkling sudo through the script: the image file and the cleanup trap then
# run with the same privileges as the writes.
if [ "$(id -u)" -ne 0 ]; then
    exec sudo -- "$SELF" "${ORIG_ARGS[@]}"
fi

for c in dd sync blockdev lsblk findmnt sgdisk parted partprobe e2fsck \
         resize2fs blkid mount umount cmp diff losetup stat swapon \
         mountpoint find awk sed; do
    if ! command -v "$c" >/dev/null 2>&1; then
        die "required command not found: $c"
    fi
done

settle() {
    if command -v udevadm >/dev/null 2>&1; then
        udevadm settle
    fi
}

human() {
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec-i --suffix=B "$1"
    else
        printf '%s bytes' "$1"
    fi
}

# The physical disk that backs a device, following LVM, dm and partition
# layers. Root can sit on an LV whose parent is a partition, so one PKNAME
# step is not enough to recognise the disk being overwritten. -r keeps the
# tree glyphs out of the output.
disk_of() {
    local src path
    src=$(readlink -f "$1")
    if [ ! -b "$src" ]; then
        return 1
    fi
    path=$(lsblk -snro PATH "$src" 2>/dev/null | tail -n 1)
    if [ -n "$path" ]; then
        printf '%s\n' "$path"
    else
        printf '%s\n' "$src"
    fi
}

# /dev/sdd + 2 -> /dev/sdd2, /dev/loop1 + 2 -> /dev/loop1p2. lsblk's PARTN
# column is not dependable here -- it came back blank for loop1p2 -- and the
# naming rule is what the kernel actually uses.
part_path() {
    case "$1" in
        *[0-9]) printf '%sp%s\n' "$1" "$2" ;;
        *)      printf '%s%s\n' "$1" "$2" ;;
    esac
}

# The last partition number in the GPT, read from the device rather than from
# udev. The layout is fixed by mkosi.repart (00-boot, then 10-root), so this
# is the root partition.
last_part_num() {
    sgdisk -p "$1" 2>/dev/null |
        awk '$1 ~ /^[0-9]+$/ && NF >= 6 { n = $1 } END { print n }'
}

part_uuid() {
    sgdisk -i "$2" "$1" 2>/dev/null |
        sed -n 's/^Partition unique GUID: //p' |
        head -n 1 | tr '[:upper:]' '[:lower:]'
}

IMGLOOP=""
IMGBOOT=""
BOOTMNT=""
cleanup() {
    set +e
    if [ -n "$IMGBOOT" ] && mountpoint -q "$IMGBOOT"; then
        umount "$IMGBOOT"
    fi
    if [ -n "$BOOTMNT" ] && mountpoint -q "$BOOTMNT"; then
        umount "$BOOTMNT"
    fi
    if [ -n "$IMGLOOP" ]; then
        losetup -d "$IMGLOOP"
    fi
    if [ -n "$IMGBOOT" ]; then rmdir "$IMGBOOT" 2>/dev/null; fi
    if [ -n "$BOOTMNT" ]; then rmdir "$BOOTMNT" 2>/dev/null; fi
}
trap cleanup EXIT

if [ "$(blockdev --getro "$TARGET")" != 0 ]; then
    die "$TARGET is read-only"
fi
# The GPT and FAT partition offsets in the image are in 512-byte sectors. A
# 4K-native disk would interpret every one of them differently, producing a
# layout that looks written and cannot boot.
target_ss=$(blockdev --getss "$TARGET")
if [ "$target_ss" != 512 ]; then
    die "$TARGET has $target_ss-byte logical sectors; this image needs 512"
fi
target_bytes=$(blockdev --getsize64 "$TARGET")
if [ "$target_bytes" -le 0 ]; then
    die "$TARGET reports size 0 (is a card inserted?)"
fi
image_bytes=$(stat -c %s "$IMAGE")
if [ "$image_bytes" -gt "$target_bytes" ]; then
    die "image is $(human "$image_bytes") but $TARGET is only $(human "$target_bytes")"
fi

# Refuse the disks that would take the running system down with them. The
# mounted-partition check below would also catch these, but this message says
# why rather than listing mountpoints.
for m in / /home /boot /boot/firmware; do
    src=$(findmnt -n -o SOURCE "$m" 2>/dev/null || true)
    if [ -z "$src" ]; then continue; fi
    d=$(disk_of "$src" || true)
    if [ -n "$d" ] && [ "$d" = "$TARGET" ]; then
        die "refusing to overwrite $TARGET: $m is mounted from it"
    fi
done

# The image may live on the card being overwritten (a common mistake when the
# card auto-mounted). Unmounting it with --unmount would make the image
# unreadable halfway through the dd.
img_src=$(findmnt -n -o SOURCE --target "$IMAGE" 2>/dev/null || true)
if [ -n "$img_src" ]; then
    d=$(disk_of "$img_src" || true)
    if [ -n "$d" ] && [ "$d" = "$TARGET" ]; then
        die "the image file is stored on $TARGET; copy it elsewhere first"
    fi
fi

# All descendants, not only partitions: an md or dm device stacked on top of
# one of them is what would be mounted.
mapfile -t DEVICES < <(lsblk -lnpo NAME "$TARGET" | tail -n +2)
# Refuse stacked devices. Unmounting the filesystem on an md or dm device is
# not enough: dd would write underneath a live device that still owns the
# partition.
for p in "${DEVICES[@]}"; do
    t=$(lsblk -dno TYPE "$p" 2>/dev/null || true)
    case "$t" in
        part|disk) ;;
        *) die "$p ($t) is stacked on $TARGET; deactivate it first" ;;
    esac
done
swapon_list=$(swapon --show=NAME --noheadings --raw 2>/dev/null || true)
mounted=()
swaps=()
for p in "${DEVICES[@]}"; do
    while IFS= read -r mp; do
        if [ -n "$mp" ]; then mounted+=("$mp"); fi
    done < <(findmnt -rn -S "$p" -o TARGET 2>/dev/null || true)
    if grep -qxF "$p" <<<"$swapon_list"; then
        swaps+=("$p")
    fi
done

if [ "${#mounted[@]}" -gt 0 ] || [ "${#swaps[@]}" -gt 0 ]; then
    if [ "$UNMOUNT" -eq 0 ]; then
        printf 'error: %s is in use:\n' "$TARGET" >&2
        if [ "${#mounted[@]}" -gt 0 ]; then
            printf '  mounted: %s\n' "${mounted[@]}" >&2
        fi
        if [ "${#swaps[@]}" -gt 0 ]; then
            printf '  swap:    %s\n' "${swaps[@]}" >&2
        fi
        die "unmount it first, or pass --unmount"
    fi
    echo "==> unmounting $TARGET"
    for mp in "${mounted[@]}"; do
        umount "$mp" || die "could not unmount $mp (still busy?)"
    done
    for p in "${swaps[@]}"; do
        swapoff "$p" || die "could not disable swap on $p"
    done
fi

printf '\n'
printf 'image:  %s (%s)\n' "$IMAGE" "$(human "$image_bytes")"
printf 'target: %s (%s)\n' "$TARGET" "$(human "$target_bytes")"
lsblk -dno MODEL,SERIAL,TRAN "$TARGET" | sed 's/^/        /'
printf '\nAll data on %s will be destroyed.\n' "$TARGET"
if [ "$ASSUME_YES" -eq 0 ]; then
    printf 'Type "yes" to continue: '
    answer=""
    if ! IFS= read -r answer < /dev/tty; then
        die "no answer; not a terminal? pass --yes"
    fi
    if [ "$answer" != "yes" ]; then
        printf 'aborted\n'
        exit 1
    fi
fi

# The source-managed boot files, in the layout they have in mkosi.extra.
BOOT_SRC="$REPO/mkosi.extra/boot/firmware"
if [ ! -d "$BOOT_SRC" ]; then die "missing source directory $BOOT_SRC"; fi
mapfile -d '' -t SRC_FILES < <(cd "$BOOT_SRC" && find . -type f -print0 | sort -z)
if [ "${#SRC_FILES[@]}" -eq 0 ]; then die "no files in $BOOT_SRC"; fi

echo
echo "==> checking the image before writing anything"
if ! "$REPO/tools/check-image.sh" "$IMAGE"; then
    die "pre-write check failed; $TARGET was not touched"
fi

# Compare the image's boot partition with the source tree. The image is mounted
# read-only and detached again before the card is touched.
STALE=0
compare_image_boot_config() {
    local loop bootmnt f rel src dest
    loop=$(losetup --find --show --partscan --read-only "$IMAGE") \
        || die "could not attach $IMAGE to a loop device"
    IMGLOOP=$loop
    settle
    bootmnt=$(mktemp -d)
    IMGBOOT=$bootmnt
    mount -o ro "${loop}p1" "$bootmnt" \
        || die "could not mount the boot partition of $IMAGE"
    for f in "${SRC_FILES[@]}"; do
        rel=${f#./}
        src="$BOOT_SRC/$rel"
        dest="$bootmnt/$rel"
        if [ ! -e "$dest" ]; then
            STALE=1
            echo "  $rel is MISSING from the image"
            continue
        fi
        if cmp -s "$src" "$dest"; then
            echo "  $rel matches"
            continue
        fi
        STALE=1
        echo "  $rel differs:"
        diff -u --label "image:$rel" --label "source:$rel" "$dest" "$src" \
            | sed 's/^/    /' || true
    done
    umount "$bootmnt" || die "could not unmount $bootmnt"
    IMGBOOT=""
    rmdir "$bootmnt"
    losetup -d "$loop" || true
    IMGLOOP=""
}

echo
echo "==> comparing the image's boot files with mkosi.extra"
compare_image_boot_config
if [ "$STALE" -eq 1 ]; then
    if [ "$SYNC_BOOT" -eq 0 ]; then
        echo >&2
        echo "The image's boot files are not the ones in the source tree." >&2
        echo "Rebuild with 'make build' (or 'make dev'), or pass" >&2
        echo "--sync-boot-config to copy them onto the card instead." >&2
        die "refusing to write a card with a stale boot configuration"
    fi
    echo "  --sync-boot-config: the differing files will be replaced on the card"
fi

echo
echo "==> writing $IMAGE to $TARGET"
sync
dd if="$IMAGE" of="$TARGET" bs=4M conv=fsync status=progress
sync
partprobe "$TARGET" || die "partprobe failed after writing"
settle

if [ "$target_bytes" -gt "$image_bytes" ]; then
    echo "==> moving the backup GPT to the end of $TARGET"
    sgdisk -e "$TARGET" || die "sgdisk -e failed"
    partprobe "$TARGET" || die "partprobe failed after moving the GPT"
    settle
fi

if [ "$GROW" -eq 0 ]; then
    echo "==> --no-grow: leaving the root filesystem at its built size"
else
    # The layout is fixed by mkosi.repart: 00-boot then 10-root, so root is
    # the last partition. Check that assumption against the pinned PARTUUID
    # rather than growing whatever happens to be last.
    root_num=$(last_part_num "$TARGET")
    if [ -z "$root_num" ]; then
        die "could not read a partition table from $TARGET"
    fi
    root_part=$(part_path "$TARGET" "$root_num")
    if [ ! -b "$root_part" ]; then
        die "root partition $root_part does not exist after writing"
    fi
    want_root=$(sed -n 's/^UUID=//p' "$REPO/mkosi.repart/10-root.conf" \
        | head -n 1 | tr '[:upper:]' '[:lower:]')
    if [ -z "$want_root" ]; then
        die "no UUID= in mkosi.repart/10-root.conf"
    fi
    have_root=$(part_uuid "$TARGET" "$root_num")
    if [ "$want_root" != "$have_root" ]; then
        die "last partition $root_part has PARTUUID '$have_root', not the root PARTUUID '$want_root'"
    fi

    echo "==> growing partition $root_num and its filesystem"
    parted -s "$TARGET" resizepart "$root_num" 100% \
        || die "parted resizepart failed"
    partprobe "$TARGET" || die "partprobe failed after resizepart"
    settle
    if [ ! -b "$root_part" ]; then
        die "$root_part disappeared after resizepart"
    fi

    # e2fsck exits 1 when it corrected something, which is not a failure.
    rc=0
    e2fsck -f -y "$root_part" || rc=$?
    case "$rc" in
        0|1) ;;
        *) die "e2fsck failed on $root_part (exit $rc)" ;;
    esac
    resize2fs "$root_part" || die "resize2fs failed on $root_part"
fi
sync

echo
echo "==> checking the boot files on the card"
boot_part=$(part_path "$TARGET" 1)
if [ ! -b "$boot_part" ]; then die "boot partition $boot_part does not exist"; fi
want_boot=$(sed -n 's/^UUID=//p' "$REPO/mkosi.repart/00-boot.conf" \
    | head -n 1 | tr '[:upper:]' '[:lower:]')
if [ -z "$want_boot" ]; then
    die "no UUID= in mkosi.repart/00-boot.conf"
fi
have_boot=$(part_uuid "$TARGET" 1)
if [ "$want_boot" != "$have_boot" ]; then
    die "partition 1 ($boot_part) has PARTUUID '$have_boot', not the boot PARTUUID '$want_boot'"
fi
BOOTMNT=$(mktemp -d)
if [ "$SYNC_BOOT" -eq 1 ]; then
    mount "$boot_part" "$BOOTMNT" || die "could not mount $boot_part read-write"
else
    mount -o ro "$boot_part" "$BOOTMNT" || die "could not mount $boot_part read-only"
fi
for f in "${SRC_FILES[@]}"; do
    rel=${f#./}
    src="$BOOT_SRC/$rel"
    dest="$BOOTMNT/$rel"
    if cmp -s "$src" "$dest"; then
        echo "  $rel matches"
        continue
    fi
    if [ "$SYNC_BOOT" -eq 0 ]; then
        die "$rel on $boot_part does not match $src; rerun with --sync-boot-config"
    fi
    mkdir -p "$(dirname "$dest")" || die "could not create $(dirname "$dest")"
    cp "$src" "$dest" || die "could not copy $rel to $boot_part"
    if ! cmp -s "$src" "$dest"; then
        die "copying $rel did not produce an identical file"
    fi
    echo "  $rel updated from mkosi.extra"
done
sync
umount "$BOOTMNT" || die "could not unmount $BOOTMNT"
rmdir "$BOOTMNT"
BOOTMNT=""

echo
echo "==> checking the written card"
if ! "$REPO/tools/check-image.sh" "$TARGET"; then
    die "the card was written, but the checks above failed"
fi

echo
lsblk -o NAME,SIZE,FSTYPE,PARTUUID "$TARGET"
echo
echo "Done: $TARGET is ready."
