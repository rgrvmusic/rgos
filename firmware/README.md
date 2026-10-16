# Vendored Raspberry Pi firmware blobs

These replace the copies from Debian trixie's `raspi-firmware` package
(1.20240424), which cannot boot this image's GPT disk on a Pi 4.

The firmware refuses a protective MBR entry (type `0xEE`), which is the first
entry of every GPT disk. On a Pi 4 it stops at the rainbow screen and the ACT
LED blinks "kernel not found" - the boot files are present, the partition
table is valid, and nothing on the card is broken. See Debian bug #1130560.

* 1.20240424 (trixie's package) - fails
* 1.20241126 - fails
* **1.20250305 - first release that boots this layout** (used here)

`start4.elf` and `fixup4.dat` are a matched pair and must be from the same
release. `bootcode.bin` is not used by the Pi 4/5 bootloader but is kept in
step so the set does not drift.

Source: <https://github.com/raspberrypi/firmware/tree/1.20250305/boot>

| file | sha256 |
| --- | --- |
| `start4.elf` | `d0934327a519a0ac7f6ad1914195e3c6186c77e9f5c2576e6a07527a92694d36` |
| `fixup4.dat` | `1ce9388a0f577f3de037f9453c18ee5af308cc242f404bed3f44a96a74aec4a6` |
| `bootcode.bin` | `b7f7faf1a1c6957e2abb79b5a5171eea7e75de60745481ab9c3890801619cef9` |

`mkosi.finalize` installs these over the package's copies. Do not delete them
to "get back to the distro version": the image will build cleanly and hang at
the rainbow screen on real hardware.
