# Regroove OS


A purpose-built OS for rehosting instrument firmwares on Raspberry Pi hardware.

Targets: **Raspberry Pi 4, Raspberry Pi 5, Compute Module 4, Compute Module 5.**


## Layout

```
mkosi.conf                       shared configuration (Debian trixie, arm64)
mkosi.profiles/dev.conf          on-device tooling, plus a login path
mkosi.repart/
    00-boot.conf                 vfat boot partition - firmware + kernel
    10-root.conf                 ext4 root
mkosi.extra/                     files copied verbatim into the image root
    boot/firmware/config.txt     Pi firmware config, one file for all four boards
    boot/firmware/cmdline.txt    kernel command line (single line)
    etc/systemd/system/          regroove-firmware@.service, boot-firmware.mount
    etc/{issue,motd}             console branding
    etc/{security,sysctl.d}/     realtime limits and latency tuning
    usr/lib/os-release           the branding itself - see "Branding" below
    usr/lib/systemd/system-preset/50-regrooveos.preset
                                 enables the serial console getty
mkosi.finalize                   stages the built kernel and modules into the image
kernel/
    rt.fragment                  CONFIG_PREEMPT_RT + no-initramfs requirements
    build.sh                     Raspberry Pi kernel build; fetches source, then stages
    download/                    fetched tarball (gitignored)
tools/
    check-image.sh               static inspection of a built image (needs root)
    qemu-test.sh                 boots it under QEMU
    qemu-dtb-fixture.py          makes the PL011 usable under QEMU - test only
docs/os-base-decision.md         the ADR: why Debian + mkosi
```

mkosi names its output `<ImageId>_<ImageVersion>.raw`, so the artifacts are
`build/regrooveos_1.raw` and `build/regrooveos-dev_1.raw`. The `_1` comes from
`ImageVersion=1` in `mkosi.conf` and is easy to miss.


## Prerequisites

`mkosi` 24.3 is packaged for Fedora 41:

```sh
sudo dnf install mkosi
```

mkosi must be able to execute `aarch64` binaries on your x86_64 host while
building. Confirm the binfmt handler is registered - if this file is missing,
the build will fail partway through with an unhelpful `Exec format error`:

```sh
ls /proc/sys/fs/binfmt_misc/qemu-aarch64
```

Kernel builds need an aarch64 cross toolchain:

```sh
sudo dnf install gcc-aarch64-linux-gnu binutils-aarch64-linux-gnu
```

`make kernel` fetches the Raspberry Pi tree from GitHub. If GitHub is only
reachable through a proxy on your network (Debian and Fedora mirrors usually
are not), export `http_proxy` and `https_proxy` first - the fetch uses `curl`,
which honours both.


## Building

```sh
make summary     # cheapest sanity check: prints the resolved configuration
make kernel      # Raspberry Pi tree + PREEMPT_RT; slow, first run fetches the tree
make build       # produces build/regrooveos_1.raw
```

`make build` will refuse to run if the kernel has not been staged - an image
without `kernel8.img` is unbootable, and the failure is worth catching at build
time rather than at boot time.

For a development image with ssh, podman and debug tools:

```sh
make dev         # produces build/regrooveos-dev_1.raw
```

> The dev profile sets the root password to `regroove` and enables autologin.
> It is a bench image. Do not put it on a network you do not control.


## Testing without hardware

Two layers. Neither is a substitute for the third, which is real hardware.

```sh
make check-image           # static: mount both partitions and read the filesystem
make qemu-test             # boot it under QEMU's raspi4b machine
make dev-run               # the same boot, interactively, on the dev image
```

`check-image` is the only layer that can say anything about the boot
partition's FAT32 / 512-byte-sector properties. It also catches the class of
defect that no build exit code reflects: modules that do not match the kernel's
own version string, a unit systemd refuses to parse, a mount unit whose
`WantedBy=` symlink dangles, a getty the image claims to enable but does not, a
boot partition built with 4096-byte sectors.

`qemu-test` boots the real kernel and the real root filesystem, and it is worth
being precise about what that does **not** cover. **QEMU emulates no
VideoCore.** It does not read `config.txt`, does not execute `start4.elf`, and
never loads `kernel8.img` from the FAT partition;
`strings qemu-system-aarch64 | grep -c kernel8.img` returns 0. The kernel is
injected with `-kernel` instead, so the entire Pi boot chain is skipped.
Firmware, HDMI and realtime behaviour stay hardware-only questions.


## Flashing

```sh
sudo dd if=build/regrooveos_1.raw of=/dev/sdX bs=4M status=progress conv=fsync
```

On CM4/CM5 with onboard eMMC, put the module in USB boot mode and use `rpiboot`
instead.

Verify the boot partition is FAT32 before first boot. This is the single most
likely reason for a silent no-boot:

```sh
file -s /dev/sdX1        # expect "FAT (32 bit)"
```

### Growing the root filesystem

The image is sized to its contents, so a freshly flashed card leaves most of
its capacity unused. Grow it once after flashing:

```sh
sudo growpart /dev/sdX 2
sudo resize2fs /dev/sdX2
```

Automatic grow-on-first-boot is not implemented. The root partition does carry
the Discoverable Partitions `GrowFileSystem` flag, but that flag is only acted
on by `systemd-gpt-auto-generator` and `--image=`, neither of which is in play
here, so it currently does nothing.


## Running a rehosted firmware

Stage a userspace outside the OS image, so it survives image updates:

```sh
install -d /var/lib/regroove/move
```

then start the template unit:

```sh
systemctl enable --now regroove-firmware@move.service
```

The unit expects `/var/lib/regroove/<name>/launch` to be executable. Realtime
scheduling is configured on the unit rather than through `limits.d`, so it
applies however the service is started.

