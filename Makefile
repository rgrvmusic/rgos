# RegrooveOS
#
#   make kernel          build the PREEMPT_RT Raspberry Pi kernel
#   make build           build the disk image
#   make dev             build the development image
#   make summary         print the fully resolved mkosi configuration
#   make check-image     inspect a built image without booting it; catches
#                        a kernel/module version mismatch, a bad fstab, a
#                        unit systemd will not parse
#   make qemu-test       boot the image's kernel+rootfs under QEMU
#   make qemu-run        same, with the console handed to you
#   make dev-run         the above, on the dev image (the only login path)
#   make run             the mkosi-native qemu path (see README; it cannot
#                        boot this image, which has no ESP)
#   make clean

MKOSI    ?= mkosi
PROFILE  ?=
# Recursive (=), NOT simply-expanded (:=). With := this is evaluated once at
# parse time, when PROFILE is still empty, so it freezes as "" and the
# target-specific `dev: PROFILE := dev` below has nothing left to influence --
# `make dev` then silently builds the *base* image. The failure is invisible:
# mkosi is not passed a profile at all, so it cannot warn about a missing one,
# and you get a clean exit 0 and a working image with the wrong contents.
# It only ever appeared to work for `make build PROFILE=dev`, because a
# command-line variable is set before the Makefile is read.
PROFILE_ARG = $(if $(PROFILE),--profile $(PROFILE),)
# mkosi names its output <ImageId>_<ImageVersion>.raw, and both settings live
# in mkosi.conf. The version suffix is easy to miss: the file is
# build/regrooveos_1.raw, not build/regrooveos.raw, and the dev profile
# overrides ImageId, giving build/regrooveos-dev_1.raw. Keep this in step
# with mkosi.conf's ImageVersion.
# Overridable so the checks can be pointed at a dev image or a downloaded one.
IMAGE    ?= build/regrooveos_1.raw
DEV_IMAGE ?= build/regrooveos-dev_1.raw

.PHONY: build dev kernel summary shell run check-image qemu-test qemu-run dev-run clean

build:
	@echo ">> mkosi $(PROFILE_ARG) -f build   [PROFILE='$(PROFILE)']"
	$(MKOSI) $(PROFILE_ARG) -f build

# The dev image is the same tree plus the on-device tooling. No point
# building it if the kernel is missing, so let the error surface early.
dev: PROFILE := dev
dev: build

kernel:
	./kernel/build.sh

# Prints every setting after profile and drop-in merging. The cheapest way
# to catch a config mistake without a full build.
summary:
	$(MKOSI) $(PROFILE_ARG) summary

shell:
	$(MKOSI) $(PROFILE_ARG) shell

# Static inspection of the assembled image. Needs root (loop device) and is
# the only one of these that can say anything about the boot partition's
# FAT32 / 512-byte-sector properties.
check-image:
	./tools/check-image.sh $(IMAGE)

# Kernels and root filesystems get booted here, boot partitions do not:
# QEMU has no VideoCore emulation, so it cannot run the Pi firmware. Read
# the header of tools/qemu-test.sh before trusting a green run.
qemu-test:
	./tools/qemu-test.sh $(IMAGE)

# Same boot, but the console is handed to you so the box can be logged into.
# Leave QEMU with Ctrl-A then x.
qemu-run:
	INTERACTIVE=1 ./tools/qemu-test.sh $(IMAGE)

# The dev image is the only one with a login path: it sets RootPassword= and
# Autologin=, so /dev/console lands in a root shell. The base image leaves
# root locked, so its console getty presents a prompt nothing can pass --
# which is the right default for something that ships.
dev-run:
	INTERACTIVE=1 ./tools/qemu-test.sh $(DEV_IMAGE)

# The image is arm64 and built for a Pi, so this only proves that the
# userspace and systemd come up. Boot, firmware and the realtime behaviour
# still have to be checked on hardware.
run:
	$(MKOSI) $(PROFILE_ARG) -f qemu

clean:
	$(MKOSI) $(PROFILE_ARG) clean
	rm -rf build
