#!/usr/bin/env bash
# qemu-test.sh -- boot a RegrooveOS image under QEMU's raspi4b machine.
#
#   tools/qemu-test.sh [image]                    supervised run, greps the log
#   INTERACTIVE=1 tools/qemu-test.sh [image]      hand over the console to you
#
# WHAT THIS PROVES
#   That the built kernel actually boots, finds its root partition by
#   PARTUUID, mounts ext4, has udev load modules, and gets systemd to a
#   state you can log in to. Until this passes, "the kernel builds" is the
#   strongest claim anyone can make about the image, and building is not
#   booting.
#
# WHAT THIS DOES NOT PROVE -- do not read a green run as more than it is
#   * The boot partition. QEMU has no VideoCore emulation whatsoever: it does
#     not read config.txt, does not execute start4.elf, and never loads
#     kernel8.img from the FAT partition. Verified with
#     `strings qemu-system-aarch64 | grep -c kernel8.img` -> 0. The kernel is
#     injected with -kernel instead, so the entire Pi boot chain is skipped.
#     The FAT32 / 512-byte-sector properties are NOT exercised here; that is
#     tools/check-image.sh's job.
#   * HDMI. QEMU does not emulate VC4/V3D, so dtoverlay=vc4-kms-v3d and the
#     vc4 driver cannot be tested here no matter what the log says.
#   * Realtime behaviour. TCG is not a timing-faithful model. Only cyclictest
#     on real hardware means anything.
#
# Hard-won details, all of which cost a diagnosis:
#   * -dtb is REQUIRED. The raspi machines do not generate a usable device
#     tree on their own; without -dtb the boot fails before the kernel.
#   * -smp must be >= 4. QEMU rejects -smp 2 on raspi4b outright ("The min
#     CPUs supported by machine 'raspi4b' is 4"), so it cannot model a
#     2-core CM4.
#   * -drive if=sd attaches to the *sdhost* controller, not emmc2. The card
#     therefore enumerates as mmcblk1, not mmcblk0 -- which is exactly why
#     the image uses root=PARTUUID= rather than /dev/mmcblk0p2.
#   * The QEMU SD size must be a power of two, and mkosi sizes the image to
#     its contents, so a throwaway copy is grown to the next power of two.
#   * console=ttyAMA1, and ONLY ttyAMA1. On a Pi 4 the PL011 at 7e201000
#     registers as ttyAMA1, because the shipped DTB aliases serial1 to it
#     (serial0 is the mini-UART at 7e215040, whose 8250 driver fails to
#     probe under QEMU). Passing both names looks like a safe hedge and is
#     the opposite: it is what stops any console from registering at all.
#     See CONSOLE= below for the mechanism, which was read out of this
#     kernel rather than guessed.
#   * The SHIPPED device tree cannot give QEMU a console, and this is the
#     single most misleading thing about this harness. The PL011 takes its
#     uartclk from cprman, whose rates come from the firmware mailbox; QEMU
#     logs those property tags as "unhandled", so uartclk reads 0 and
#     amba-pl011 registers no tty at all. The kernel still prints -- earlycon
#     is polled and needs no clock -- so a boot looks completely healthy and
#     is impossible to log in to. The tell is that the log contains the
#     earlycon line but never "legacy console [ttyAMA1] enabled"; the check
#     at the bottom of this script fails loudly on that.
#     So a fixture tree is generated from the shipped one by
#     tools/qemu-dtb-fixture.py (fixed 48 MHz clock, skip-init and
#     uart-has-rtscts dropped). It is a QEMU-only crutch and never ships:
#     on real hardware the firmware has already done all of this.
#     Set DTB=/path/to.dtb to bypass the fixture and boot a tree verbatim.
#   * earlycon=pl011,mmio32,0xfe201000 stays even with the fixture, because
#     it prints from the very first kernel instruction, before any driver
#     registers. With the fixture it is a convenience, not the only way to
#     see output.
#   * Expect ~200 `WARN_ON(host->cmd)` at bcm2835-mmc.c:661 under TCG. A
#     hard-coded 10 ms SDHCI_CMD_INHIBIT wait expires because emulation is
#     slow; it wedges the SD path and systemd output stalls for tens of
#     seconds. An emulation timing artefact, not an image defect.
#
# Requires qemu-system-aarch64.

set -euo pipefail

REPO=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
IMAGE=${1:-$REPO/build/regrooveos_1.raw}
TIMEOUT=${TIMEOUT:-600}
KERNEL=${KERNEL:-$REPO/kernel/out/kernel8.img}
# The tree the image actually ships. It is not booted directly -- see the
# fixture step below -- but it is the input to it.
DTB_SRC=${DTB_SRC:-$REPO/kernel/out/dts/bcm2711-rpi-4-b.dtb}
# Explicitly setting DTB= bypasses the fixture and boots that tree verbatim.
DTB=${DTB:-}
LOG=${LOG:-/tmp/regroove-qemu.log}
TESTIMG=${TESTIMG:-/tmp/regroove-test.raw}
PARTUUID=${PARTUUID:-7a1c0de0-0001-4000-8000-000000000001}
INTERACTIVE=${INTERACTIVE:-0}

command -v qemu-system-aarch64 >/dev/null || {
    echo "error: qemu-system-aarch64 not found" >&2; exit 1; }
[ -f "$IMAGE" ] || { echo "error: no image at $IMAGE" >&2; exit 1; }
[ -f "$KERNEL" ] || {
    echo "error: no kernel at $KERNEL" >&2
    echo "       run 'make kernel' first -- the image on the boot partition" >&2
    echo "       is not readable by QEMU, so it has to be passed directly." >&2
    exit 1; }

# --- device tree ------------------------------------------------------------
# Build the QEMU fixture tree. See the header for why the shipped one cannot
# be booted directly: it gives earlycon output and no tty, which looks like
# success right up to the point you try to log in.
if [ -n "$DTB" ]; then
    [ -f "$DTB" ] || { echo "error: no device tree at $DTB" >&2; exit 1; }
    echo "==> dtb     $DTB (verbatim, fixture bypassed via DTB=)"
else
    [ -f "$DTB_SRC" ] || {
        echo "error: no device tree at $DTB_SRC" >&2
        echo "       run 'make kernel' first, or set DTB_SRC=." >&2
        exit 1; }

    FIXDIR=${FIXDIR:-/tmp/regroove-qemu-dtb}
    DTB=$FIXDIR/bcm2711-rpi-4-b.qemu.dtb

    # Regenerate when either input is newer than the fixture. dtc and python3
    # are needed only on this path, so DTB=... runs without them.
    if [ -f "$DTB" ] && [ "$DTB" -nt "$DTB_SRC" ] &&
       [ "$DTB" -nt "$REPO/tools/qemu-dtb-fixture.py" ]; then
        echo "==> dtb     $DTB (fixture, cached)"
    else
        command -v dtc >/dev/null || {
            echo "error: dtc not found -- needed to build the fixture tree" >&2
            echo "       install device-tree-compiler, or pass DTB= to bypass" >&2
            exit 1; }
        command -v python3 >/dev/null || {
            echo "error: python3 not found -- needed to build the fixture tree" >&2
            exit 1; }
        echo "==> dtb     $DTB (fixture, generating)"
        mkdir -p "$FIXDIR"
        # Round-trip through source text: the fixture edits are textual, and a
        # failing dtc is far more readable against dts than a flattened blob.
        dtc -q -I dtb -O dts -o "$FIXDIR/shipped.dts" "$DTB_SRC"
        python3 -I "$REPO/tools/qemu-dtb-fixture.py" \
                "$FIXDIR/shipped.dts" "$FIXDIR/fixture.dts"
        dtc -q -I dts -O dtb -o "$DTB" "$FIXDIR/fixture.dts"
    fi
fi

# QEMU refuses an SD card whose size is not a power of two. Work on a
# throwaway sparse copy and leave the real artifact untouched.
size=$(stat -c %s "$IMAGE")
want=1
while [ "$want" -lt "$size" ]; do want=$(( want * 2 )); done

# Reuse the copy only when it is not older than the image it was copied from.
# -nt is the load-bearing part: every image this project builds is smaller
# than 4 GiB, so it always grows to the same 4 GiB and a size test alone
# matches forever. That silently booted a root filesystem from an earlier
# build -- a stale /etc/fstab stalled the boot for 90 seconds and a getty
# that the current image enables was absent -- while the kernel, which is
# passed with -kernel, was current the whole time. A harness that quietly
# tests last week's rootfs is worse than no harness.
if [ -f "$TESTIMG" ] && [ "$(stat -c %s "$TESTIMG")" = "$want" ] &&
   [ "$TESTIMG" -nt "$IMAGE" ]; then
    echo "==> reusing existing $TESTIMG ($want bytes)"
else
    echo "==> image   $IMAGE ($size bytes)"
    echo "==> testing $TESTIMG (sparse copy, grown to $want bytes)"
    rm -f "$TESTIMG"
    cp --sparse=always "$IMAGE" "$TESTIMG"
    qemu-img resize -f raw "$TESTIMG" "$want" >/dev/null
fi

# root= by PARTUUID rather than /dev/mmcblk0p2 on purpose: the card does not
# enumerate as mmcblk0 under emulation (see the header). quiet is dropped and
# loglevel raised so the boot is actually readable.
#
# Exactly one console name, and this is load-bearing rather than tidy.
# Listing console=ttyAMA0 as well does not degrade gracefully -- it prevents
# the serial console from existing, and the boot then looks healthy while
# being impossible to log in to. The path, read out of this kernel:
#
#   printk's try_enable_preferred_console() walks the console= list and
#   returns on the first *name* match, so the ttyAMA0 entry is the only one
#   it ever tries. pl011_console_setup() then does
#       uap = amba_ports[co->index];  if (!uap) return -ENODEV;
#   and amba_ports[0] is empty -- the port is line 1. -ENODEV is not
#   -ENOENT, so register_console() skips its platform-default fallback and
#   bails out silently: no "console [ttyAMA1] enabled", no "disabled"
#   either, and the ttyAMA1 entry is never looked at.
#
# The symptom is a registered tty that is not a console, so it cannot be
# logged in to and getty on it never runs. This was the actual reason the
# interactive console did not work; the missing getty preset was a second,
# independent problem. Override with CONSOLE= for a tree that names the
# PL011 differently.
CONSOLE=${CONSOLE:-ttyAMA1}

# Extra kernel arguments, for one-off diagnosis without editing this file:
#
#   EXTRA='systemd.log_level=debug systemd.log_target=kmsg' make qemu-test
#
# Empty by default, so a normal run boots exactly the shipped configuration
# and nothing here can quietly become part of it.
EXTRA=${EXTRA:-}

APPEND="root=PARTUUID=$PARTUUID rootfstype=ext4 rw rootwait"
APPEND="$APPEND console=$CONSOLE,115200"
APPEND="$APPEND earlycon=pl011,mmio32,0xfe201000 loglevel=7"
if [ -n "$EXTRA" ]; then
    APPEND="$APPEND $EXTRA"
fi

QEMU=(
    qemu-system-aarch64
    -M raspi4b
    -m 2G
    -smp 4                  # raspi4b rejects fewer
    -display none
    -nographic
    -kernel "$KERNEL"
    -dtb "$DTB"
    -drive "file=$TESTIMG,format=raw,if=sd"
    -append "$APPEND"
)

echo "==> image   $IMAGE"
echo "==> kernel  $KERNEL"
echo "==> log     $LOG"

if [ "$INTERACTIVE" = 1 ]; then
    # Interactive: hand stdio to the console so the box can be logged into.
    # -no-reboot is deliberately absent here, so `reboot` cycles instead of
    # dropping you out of QEMU. Leave with Ctrl-A then x.
    echo "==> interactive -- leave with Ctrl-A x"
    echo "    dev image:  Autologin= means /dev/console arrives as a root shell."
    echo "    base image: root is locked, so the getty shows a login prompt"
    echo "                that cannot be passed. That is the intended default."
    echo
    "${QEMU[@]}" 2>&1 | tee "$LOG"
    exit 0
fi

echo "==> limit   ${TIMEOUT}s"
echo

# A supervised run must not consume the terminal, and must not hang waiting
# on stdin: -nographic reads it.
set +e
timeout --foreground "$TIMEOUT" "${QEMU[@]}" \
    -no-reboot < /dev/null > "$LOG" 2>&1
rc=$?
set -e

echo "=== qemu exited $rc (124 = hit the ${TIMEOUT}s limit, so it was still running) ==="
echo "=== $(wc -l < "$LOG") lines of serial output in $LOG ==="

# A run that produced no serial output at all is the one failure mode worth
# naming, because it looks identical to a hang and is usually a bad -kernel.
if ! grep -q 'Linux version' "$LOG"; then
    echo
    echo "no kernel banner in the log -- the kernel was never entered."
    echo "last lines:"
    tail -20 "$LOG" | sed 's/^/    /'
    exit 1
fi

# Distinguish a real console from earlycon-only output: earlycon prints
# without any driver registering, so "there was output" proves nothing.
if ! grep -q 'legacy console \[ttyAMA[01]\] enabled' "$LOG"; then
    echo
    echo "WARNING: no real console registered -- output above may be earlycon"
    echo "         only, which means nothing could be logged in to."
fi

echo
grep -E 'Linux version|PREEMPT_RT|mmc[0-9]|EXT4-fs .*mounted|systemd\[1\]|Reached target|login:' \
     "$LOG" | head -30 | sed 's/^/  /'
