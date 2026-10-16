#!/usr/bin/env bash
# check-image.sh -- inspect a built RegrooveOS image without booting it.
#
# This is the "userspace-only" test layer: it mounts the image's two
# partitions read-only on the host and checks the assembled filesystem. It
# catches the class of defect that is invisible to every build exit code --
# a kernel whose modules do not match its own version string, a unit systemd
# will refuse to parse, an fstab that lost its entries, firmware files that
# never reached the boot partition.
#
# What it CANNOT prove, by construction: that the image boots. The Raspberry
# Pi boot chain runs on the VideoCore VPU before the ARM core starts, and no
# open emulator implements it -- see tools/qemu-test.sh and the README.
#
# Needs root for losetup/mount. A regular image file is attached to a loop
# device; a whole block device (e.g. /dev/sdd) is used directly. Either way the
# target is mounted read-only and never written. Loop devices are released.

set -euo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=${1:-$REPO/build/regrooveos_1.raw}
KERNEL_IMG=${KERNEL_IMG:-}

pass=0 fail=0 warn=0
ok()   { printf '  \033[32mok\033[0m   %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=$((fail+1)); }
meh()  { printf '  \033[33mwarn\033[0m %s\n' "$*"; warn=$((warn+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

if [ ! -f "$IMAGE" ] && [ ! -b "$IMAGE" ]; then
    echo "error: no image or block device at $IMAGE" >&2
    exit 1
fi

LOOP=""
BOOTMNT=$(mktemp -d)
ROOTMNT=$(mktemp -d)

cleanup() {
    set +e
    # sudo throughout, matching the mounts below: the loop device is created
    # with sudo and is root-owned, so a plain umount/losetup -d fails with
    # "must be superuser" and leaks both the mount and the loop device.
    mountpoint -q "$BOOTMNT" && sudo umount "$BOOTMNT"
    mountpoint -q "$ROOTMNT" && sudo umount "$ROOTMNT"
    [ -n "$LOOP" ] && sudo losetup -d "$LOOP"
    rmdir "$BOOTMNT" "$ROOTMNT"
}
trap cleanup EXIT

if [ -b "$IMAGE" ]; then
    # A whole disk is used as-is. Requiring the whole disk rather than a
    # partition keeps the P1/P2 naming below meaningful, and it is also what
    # flash-image.sh passes after writing a card.
    IMAGE=$(readlink -f "$IMAGE")
    if [ "$(lsblk -dno TYPE "$IMAGE")" != disk ] &&
       [ "$(lsblk -dno TYPE "$IMAGE")" != loop ]; then
        echo "error: $IMAGE is not a whole block device" >&2; exit 1
    fi
    case "$IMAGE" in
        *[0-9]) P1="${IMAGE}p1"; P2="${IMAGE}p2" ;;
        *)      P1="${IMAGE}1";  P2="${IMAGE}2"  ;;
    esac
    echo "device: $IMAGE"
else
    sudo losetup --find --show --partscan --read-only "$IMAGE" > /tmp/.regroove-loop
    LOOP=$(cat /tmp/.regroove-loop); rm -f /tmp/.regroove-loop
    P1="${LOOP}p1"; P2="${LOOP}p2"
    echo "image: $IMAGE"
    echo "loop:  $LOOP"
fi
[ -b "$P1" ] && [ -b "$P2" ] || {
    echo "error: expected two partitions on $IMAGE, found none" >&2; exit 1; }

sudo mount -o ro "$P1" "$BOOTMNT"
sudo mount -o ro "$P2" "$ROOTMNT"

# The firmware's own kernel is the authority on what /lib/modules must be
# named. Reading it from the boot partition rather than from the build tree
# means this works on a downloaded or hand-flashed image too. KERNEL_IMG can
# still be overridden explicitly.
KERNEL_IMG=${KERNEL_IMG:-$BOOTMNT/kernel8.img}

# ---------------------------------------------------------------- boot ----
head_ "boot partition"

# The two load-bearing properties. Both fail silently: the image builds to a
# clean exit 0 and then does not boot. See README "The boot partition has two
# load-bearing properties".
# sudo, because the partition device node is root-owned. Without it `file`
# reports "no read permission" and this check FAILS a correctly built image,
# which is worse than not checking at all.
bootinfo=$(sudo file -s "$P1")
if grep -q 'FAT (32 bit)' <<<"$bootinfo"; then
    ok "FAT32 (the firmware will not boot FAT16)"
else
    bad "not FAT32: $(sed 's/.*: //' <<<"$bootinfo")"
fi
# Read the field rather than scrape prose for it. `file` does not report a
# FAT logical sector size at all -- for this partition it prints "FAT (32
# bit), sectors/FAT 1024, ..." and no sector size anywhere -- so the string
# this check originally looked for only ever appeared in fsck.fat's output,
# and the check was FAILing a correct image.
#
# BPB_BytsPerSec is a little-endian u16 at offset 11 of the FAT boot sector,
# so it is read as two bytes and recombined rather than as one u16, which
# would make the check depend on the host's byte order.
read -r lo hi < <(sudo dd if="$P1" bs=1 skip=11 count=2 status=none |
                  od -An -tu1)
bps=$(( lo + 256 * hi ))
if [ "$bps" = 512 ]; then
    ok "512-byte logical sectors (start4.elf has no 4K-sector support)"
else
    bad "logical sector size is $bps, not 512 -- the firmware cannot read this"
fi

for f in bootcode.bin start4.elf fixup4.dat config.txt cmdline.txt kernel8.img; do
    [ -f "$BOOTMNT/$f" ] && ok "$f present" || bad "$f MISSING"
done

# The firmware picks the DTB by board name, so the exact filename is what
# matters -- a truncation to 8.3 would be a silent no-boot.
for f in bcm2711-rpi-4-b.dtb bcm2711-rpi-cm4.dtb bcm2712-rpi-5-b.dtb; do
    [ -f "$BOOTMNT/$f" ] && ok "$f (exact name)" || bad "$f MISSING (long filename lost?)"
done

# Every overlay config.txt asks for by name must be staged. Parameters after
# the first comma (e.g. hifiberry-dacplus,slave) are not part of the filename.
while IFS= read -r ovl; do
    [ -f "$BOOTMNT/overlays/$ovl.dtbo" ] \
        && ok "config.txt wants $ovl and the overlay is present" \
        || bad "config.txt requests $ovl but overlays/$ovl.dtbo is MISSING"
done < <(grep -oP '^\s*dtoverlay=\K[^,\s]+' "$BOOTMNT/config.txt" 2>/dev/null)
n_ovl=$(find "$BOOTMNT/overlays" -name '*.dtbo' 2>/dev/null | wc -l)
[ "$n_ovl" -gt 300 ] && ok "$n_ovl overlays staged" || meh "only $n_ovl overlays"

# KMS must be requested by its per-SoC name. The generic name is NOT safe:
# measured on firmware 1.20250305, dtoverlay=vc4-kms-v3d resolved to the
# BCM2835 overlay on a CM4 even with overlay_map.dtb present, the firmware
# dropped it, and HDMI silently stayed on the firmware framebuffer -- no
# /dev/dri, no HDMI1, and display 0 only after a cable replug. The image
# boots and looks healthy from SSH, so it cannot be caught any other way.
for ovl in vc4-kms-v3d-pi4 vc4-kms-v3d-pi5; do
    grep -qE "^[[:space:]]*dtoverlay=$ovl[[:space:]]*$" "$BOOTMNT/config.txt" \
        && ok "config.txt names $ovl explicitly" \
        || bad "config.txt does not name $ovl -- KMS can be dropped on that SoC"
done
if grep -qE '^[[:space:]]*dtoverlay=vc4-kms-v3d[[:space:]]*$' "$BOOTMNT/config.txt"; then
    bad "config.txt uses generic dtoverlay=vc4-kms-v3d (BCM2835 flavour on Pi 4/CM4)"
fi

# overlay_map.dtb belongs at the boot partition root, not in overlays/. The
# image does not depend on it for KMS (see above), but other overlays with
# per-SoC variants do, and it is standard boot-partition content.
if [ -s "$BOOTMNT/overlay_map.dtb" ]; then
    grep -aq 'vc4-kms-v3d-pi4' "$BOOTMNT/overlay_map.dtb" \
        && ok "overlay_map.dtb present and maps vc4-kms-v3d to the BCM2711 flavour" \
        || bad "overlay_map.dtb has no vc4-kms-v3d-pi4 mapping"
else
    bad "overlay_map.dtb MISSING from the boot partition root"
fi

# Cross-check the one thing that cannot be fixed at runtime: if cmdline's
# PARTUUID does not name the root partition, the kernel panics with
# "unable to mount root fs" and there is no shell to fix it from.
cmdline=$(cat "$BOOTMNT/cmdline.txt")
want=$(grep -oP 'root=PARTUUID=\K[0-9a-f-]+' <<<"$cmdline" || true)
have=$(sudo sgdisk -i 2 "$IMAGE" 2>/dev/null |
       sed -n 's/^Partition unique GUID: //p' | tr '[:upper:]' '[:lower:]')
[ -n "$want" ] && [ "$want" = "$have" ] \
    && ok "cmdline root PARTUUID matches the root partition ($want)" \
    || bad "PARTUUID mismatch: cmdline=$want root partition=$have"

# The HDMI console is only usable if tty1 is named as a console; getty@tty1
# then draws on it. And nothing should route the whole systemd journal to
# /dev/kmsg: printk copies that to every console, so the login prompt is
# buried under service chatter within seconds of boot.
grep -qw 'console=tty1' <<<"$cmdline" \
    && ok "HDMI console named in cmdline (console=tty1)" \
    || bad "console=tty1 missing -- no getty on HDMI"
if grep -qw 'systemd.log_target=kmsg' <<<"$cmdline"; then
    meh "systemd.log_target=kmsg sends every systemd log line to the console"
fi

# ---------------------------------------------------------------- root ----
head_ "root filesystem"

# /etc/fstab is generated by systemd-repart -- mkosi always passes
# --generate-fstab=/etc/fstab -- so anything hand-written would be clobbered
# anyway (see README). Both partitions deliberately declare no MountPoint=:
#
#   * root is mounted by the kernel from cmdline.txt. MountPoint= would also
#     add `discard`, and MountPoint= can only append to repart's defaults,
#     never remove them. See 10-root.conf.
#   * the boot partition is mounted by boot-firmware.mount by PARTUUID,
#     because the UUID= entry repart generates for it can never resolve: a
#     FAT filesystem holds only a 4-byte volume ID, so udev publishes
#     1707-11AA while repart writes the full 170711aa-31ff-... That costs a
#     90-second device timeout on every boot. See 00-boot.conf.
#
# With no MountPoint= anywhere, repart writes no entries and the file ends up
# absent entirely -- confirmed on a built image. That is the intended state,
# so assert the absence rather than demanding an empty file. If someone
# re-adds MountPoint=, an entry reappears here and this catches it.
if [ -e "$ROOTMNT/etc/fstab" ]; then
    mapfile -t fstab_entries < <(grep -E '^[^#[:space:]]' "$ROOTMNT/etc/fstab" || true)
    if [ "${#fstab_entries[@]}" -eq 0 ]; then
        ok "/etc/fstab exists but holds no entries (no MountPoint= declared)"
    else
        bad "/etc/fstab has ${#fstab_entries[@]} active entr(ies) -- unexpected:"
        printf '       %s\n' "${fstab_entries[@]}"
        if grep -q 'discard' "$ROOTMNT/etc/fstab"; then
            bad "  ...and one carries 'discard', which stalls SD/eMMC controllers"
        fi
        if grep -q 'UUID=170711aa' "$ROOTMNT/etc/fstab"; then
            bad "  ...and one is the unresolved vfat UUID= entry repart generates"
        fi
    fi
else
    ok "no /etc/fstab -- root comes from cmdline.txt, /boot/firmware from a unit"
fi

# The unit that replaces the fstab entry. Check it is present, that its
# WantedBy= symlink actually resolves (a dangling one is skipped silently --
# this exact failure was hit with a getty symlink, see the preset check
# below), and that its PARTUUID names the real boot partition.
mount_unit=/etc/systemd/system/boot-firmware.mount
if [ -f "$ROOTMNT$mount_unit" ]; then
    ok "$mount_unit present"
    link=/etc/systemd/system/local-fs.target.wants/boot-firmware.mount
    if [ -e "$ROOTMNT$link" ]; then
        ok "enabled: $link resolves"
    else
        bad "$link is missing or dangling -- /boot/firmware would never mount"
    fi
    want_boot=$(grep -oP 'by-partuuid/\K[0-9a-f-]+' "$ROOTMNT$mount_unit" || true)
    have_boot=$(sudo sgdisk -i 1 "$IMAGE" 2>/dev/null |
                sed -n 's/^Partition unique GUID: //p' | tr '[:upper:]' '[:lower:]')
    [ -n "$want_boot" ] && [ "$want_boot" = "$have_boot" ] \
        && ok "mount unit PARTUUID matches the boot partition ($want_boot)" \
        || bad "boot PARTUUID mismatch: unit=$want_boot partition=$have_boot"
else
    bad "$mount_unit missing -- nothing would mount /boot/firmware"
fi

# The modules must be named for the exact kernel that will load them. A
# mismatch is a hard failure at boot: every module silently refuses to load,
# including the display driver.
if [ -f "$KERNEL_IMG" ]; then
    kver_img=$(strings -a "$KERNEL_IMG" | grep -m1 -oP 'Linux version \K[^ ]+' || true)
    kver_mod=$(basename "$(find "$ROOTMNT/lib/modules" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1)" 2>/dev/null || true)
    if [ -z "$kver_mod" ]; then
        bad "no /lib/modules/<version> in the image (modules were not staged)"
    elif [ "$kver_img" = "$kver_mod" ]; then
        ok "modules match the kernel: $kver_mod"
    else
        bad "kernel is $kver_img but modules are $kver_mod -- no module would load"
    fi
else
    meh "no local kernel at $KERNEL_IMG; skipped version match"
fi

moddir="$ROOTMNT/lib/modules/$kver_mod"
if [ -d "$moddir" ]; then
    [ -f "$moddir/modules.dep" ] && ok "modules.dep present (depmod ran)" \
        || bad "modules.dep missing -- modprobe will not resolve dependencies"
    n_ko=$(find "$moddir" -name '*.ko*' | wc -l)
    [ "$n_ko" -gt 0 ] && ok "$n_ko kernel modules installed" || bad "no .ko files in $moddir"

    # The gap this whole exercise was about: DRM is =m, so no vc4 module
    # means no HDMI at all once dtoverlay=vc4-kms-v3d has taken the display.
    find "$moddir" -name 'vc4.ko*' | grep -q . \
        && ok "vc4.ko present (KMS display driver for HDMI)" \
        || bad "vc4.ko MISSING -- no HDMI"

    # modules_install leaves these pointing into the build tree, which does
    # not exist on the device. build.sh removes them.
    for l in build source; do
        [ -e "$moddir/$l" ] && bad "$moddir/$l dangling symlink left in image" \
                            || ok "no stale $l symlink"
    done
fi

# systemd units: a unit that does not parse is a service that never starts,
# and the build says nothing about it.
unit=/etc/systemd/system/regroove-firmware@.service
if [ -f "$ROOTMNT$unit" ]; then
    ok "$unit present"
    if systemd-analyze --root="$ROOTMNT" verify "$unit" >/tmp/.regroove-verify 2>&1; then
        ok "systemd-analyze verify accepts it"
    else
        meh "systemd-analyze verify complained:"
        sed 's/^/       /' /tmp/.regroove-verify
    fi
    rm -f /tmp/.regroove-verify
else
    meh "$unit not found"
fi

# systemd-firstboot's ExecStart prompts for locale/keymap/timezone/root
# password with StandardInput=tty and is ordered Before=sysinit.target. On an
# image whose /etc/machine-id is "uninitialized" (what mkosi ships) it runs on
# the first boot, stops at that prompt on /dev/console -- ttyAMA1, the serial
# port -- and never returns: sysinit never completes, no getty starts on any
# console, and the HDMI screen goes quiet after the kernel messages. Masked by
# mkosi.finalize.
if [ -L "$ROOTMNT/etc/systemd/system/systemd-firstboot.service" ] && \
   [ "$(readlink "$ROOTMNT/etc/systemd/system/systemd-firstboot.service")" = /dev/null ]; then
    ok "systemd-firstboot masked (no interactive prompt blocking sysinit)"
else
    bad "systemd-firstboot NOT masked -- first boot stops at a prompt on ttyAMA1"
fi

# With the link marked RequiredForOnline=no, networkd reports its Online state
# as "unknown" and systemd-networkd-wait-online times out after 120 seconds
# instead of returning immediately -- the boot ends "degraded" and everything
# ordered after network-online.target (podman auto-update) waits it out.
# Masked by mkosi.finalize; DHCP continues in the background.
if [ -L "$ROOTMNT/etc/systemd/system/systemd-networkd-wait-online.service" ] && \
   [ "$(readlink "$ROOTMNT/etc/systemd/system/systemd-networkd-wait-online.service")" = /dev/null ]; then
    ok "systemd-networkd-wait-online masked (DHCP never blocks boot)"
else
    bad "systemd-networkd-wait-online NOT masked -- 120s timeout, boot ends degraded"
fi

# DHCP supplies the link's nameservers, but networkd only records them: it is
# a DHCP client, not a resolver. systemd-resolved consumes them and serves
# 127.0.0.53, and /etc/resolv.conf must point at that stub or glibc has no
# nameserver at all. Measured on 10.0.21.176: networkctl status showed
# "DNS: 10.0.21.2", /etc/resolv.conf did not exist, and `getent hosts
# deb.debian.org` failed while ping and SSH by address worked.
if [ -x "$ROOTMNT/usr/lib/systemd/systemd-resolved" ]; then
    ok "systemd-resolved installed (consumes the DHCP nameservers)"
    if [ -e "$ROOTMNT/etc/systemd/system/multi-user.target.wants/systemd-resolved.service" ]; then
        ok "systemd-resolved enabled"
    else
        bad "systemd-resolved installed but NOT enabled -- DNS stays broken"
    fi
    if [ -L "$ROOTMNT/etc/resolv.conf" ] && \
       [ "$(readlink "$ROOTMNT/etc/resolv.conf")" = ../run/systemd/resolve/stub-resolv.conf ]; then
        ok "/etc/resolv.conf points at the resolved stub"
    else
        bad "/etc/resolv.conf missing or not the resolved stub -- no name lookup"
    fi
else
    bad "systemd-resolved MISSING -- no /etc/resolv.conf: every name lookup fails"
fi

# udev is a separate Debian package and systemd does not depend on it. Without
# it nothing creates /dev/disk/by-partuuid/, so boot-firmware.mount waits 90
# seconds for a device that never appears and then fails on a dependency; the
# root still mounts because the kernel resolves root=PARTUUID= itself, so the
# boot looks half-alive and the fault reads as a display or network problem.
# The rules file is the one that creates the persistent symlinks.
if [ -x "$ROOTMNT/usr/lib/systemd/systemd-udevd" ] && \
   { [ -x "$ROOTMNT/usr/bin/udevadm" ] || [ -x "$ROOTMNT/bin/udevadm" ]; } && \
   [ -f "$ROOTMNT/usr/lib/udev/rules.d/60-persistent-storage.rules" ]; then
    ok "udev present (by-partuuid links, module autoload, firmware loading)"
else
    bad "udev MISSING -- no /dev/disk/by-partuuid: boot-firmware.mount waits 90s"
fi

# The serial console needs a getty, or the box boots to a console that prints
# everything and accepts no login. systemd's own getty generator did not
# create one here, so the image enables console-getty.service through a
# preset.
#
# This check earns its place twice over: the first two attempts at it failed
# silently. A getty.target.wants/ symlink in mkosi.extra pointed at
# /usr/lib/systemd/system/console-getty.service, which does not exist inside
# mkosi.extra -- so it dangled in the source tree and mkosi simply did not
# carry it across. The built image had only Debian's getty@tty1 and nothing
# said so. A preset file survives because it is a plain file.
# agetty does not implement a login itself: it execs the login program, which
# on Debian lives in the `login` package -- split out of util-linux, so a
# package list that names util-linux does not get it. When it is absent, every
# getty exits at once and systemd restarts it in a loop: the box boots, the
# kernel log looks healthy, and there is no prompt on any console. The build
# exits 0 and the image passes every other check here.
if [ -x "$ROOTMNT/bin/login" ] || [ -x "$ROOTMNT/usr/bin/login" ]; then
    ok "/bin/login present (getty has a login program to exec)"
else
    bad "/bin/login MISSING -- every getty would restart in a loop, no prompt"
fi

getty_link=/etc/systemd/system/getty.target.wants/console-getty.service
if [ -e "$ROOTMNT$getty_link" ]; then
    # Resolve the link target *inside* the image before believing it. It
    # points at /usr/lib/systemd/system/console-getty.service, an ABSOLUTE
    # path, and `-e` on the link follows it against the host root -- so on any
    # host that has systemd installed this check passed no matter what the
    # image contained. It would have reported a healthy getty for an image
    # with none, which is the exact failure it exists to catch.
    getty_tgt=$(readlink "$ROOTMNT$getty_link")
    case "$getty_tgt" in
        /*) getty_tgt="$ROOTMNT$getty_tgt" ;;
        *)  getty_tgt="$(dirname "$ROOTMNT$getty_link")/$getty_tgt" ;;
    esac
    if [ -f "$getty_tgt" ]; then
        ok "console-getty.service enabled and its target is in the image"
    else
        bad "console-getty.service is enabled but DANGLING in the image:"
        bad "  $(readlink "$ROOTMNT$getty_link") does not exist there"
    fi
else
    bad "console-getty.service NOT enabled -- the serial console would have no login"
fi
preset=/usr/lib/systemd/system-preset/50-regrooveos.preset
if [ -f "$ROOTMNT$preset" ]; then
    ok "$(basename "$preset") landed in the image"
else
    meh "$preset missing -- the getty check above can only pass if it was applied"
fi

# Branding. mkosi rewrites IMAGE_ID=/IMAGE_VERSION= in place in this file and
# skips symlinks, so the hand-written NAME/PRETTY_NAME have to live at
# /usr/lib/os-release: /etc/os-release is a symlink to it, and a real file at
# /etc would replace the symlink and make mkosi skip the image identity.
osrel=$ROOTMNT/usr/lib/os-release
if grep -q '^NAME="RegrooveOS"' "$osrel" 2>/dev/null; then
    ok "branded: $(grep -m1 '^PRETTY_NAME=' "$osrel" | cut -d= -f2-)"
else
    bad "not branded -- Debian's identity would be presented instead"
fi
if grep -q '^IMAGE_ID=' "$osrel" 2>/dev/null; then
    ok "mkosi stamped $(grep -m1 '^IMAGE_ID=' "$osrel")"
else
    meh "IMAGE_ID= not stamped in os-release (mkosi configure_os_release)"
fi

# The dev image is the one you install packages on. apt is not in Debian's
# Essential set and the host-side mkosi install never puts apt itself into the
# image, so the dev profile carries apt and the archive keyring explicitly;
# mkosi then generates the deb822 sources file because /usr/bin/apt exists.
# Measured on the dev image before that: dpkg was present, apt-get was not,
# /etc/apt held only apt.conf.d.
# The production image stays without them: it is rebuilt, not patched.
imgid=$(sed -n 's/^IMAGE_ID=//p' "$osrel" | tr -d '"')
case "$imgid" in
    *-dev)
        if [ -x "$ROOTMNT/usr/bin/apt-get" ]; then
            ok "apt-get present (the dev image installs packages on the device)"
            # mkosi writes etc/apt/sources.list.d/<release>.sources itself,
            # but only when apt is installed. Do not name the file: it is the
            # release name. Check that some source points at the archive.
            if grep -lqs 'deb.debian.org' "$ROOTMNT"/etc/apt/sources.list.d/*.sources 2>/dev/null; then
                ok "Debian archive sources configured"
            else
                bad "apt-get present but no deb.debian.org entry in apt sources -- apt cannot fetch"
            fi
            if [ -s "$ROOTMNT/usr/share/keyrings/debian-archive-keyring.gpg" ]; then
                ok "debian-archive-keyring present"
            else
                bad "archive keyring missing -- apt-get update cannot verify the archive"
            fi
        else
            bad "apt-get MISSING from the dev image -- nothing can be installed on the device"
        fi
        ;;
    *)
        if [ -x "$ROOTMNT/usr/bin/apt-get" ]; then
            meh "apt-get present in the production image -- keep it lean"
        else
            ok "no apt-get in the production image (rebuilt, not patched)"
        fi
        ;;
esac
for f in etc/issue etc/motd; do
    if [ -f "$ROOTMNT/$f" ]; then ok "/$f present"; else meh "/$f missing"; fi
done

for pkg in systemd kmod alsa-utils raspi-firmware; do
    dpkg-query --admindir="$ROOTMNT/var/lib/dpkg" -W "$pkg" >/dev/null 2>&1 \
        && ok "$pkg installed" || bad "$pkg NOT installed"
done

# The root copy would be dead weight and, worse, could diverge from the
# boot partition. 10-root.conf excludes it.
if [ -n "$(ls -A "$ROOTMNT/boot/firmware" 2>/dev/null)" ]; then
    bad "/boot/firmware is populated in root too (ExcludeFiles did not apply)"
else
    ok "kernel/firmware not duplicated into root"
fi

printf '\n\033[1m%d passed, %d failed, %d warnings\033[0m\n' "$pass" "$fail" "$warn"
[ "$fail" -eq 0 ]
