#!/bin/sh
#
# This scripts takes a simpleimage and a kernel tarball, resizes the
# secondary partition and creates a rootfs inside it. Then extracts the
# Kernel tarball on top of it, resulting in a full Pine64 disk image.

OUT_IMAGE="$1"
DISTRO="$2"
VARIANT="$3"
BUILD_ARCH="$4"
MODEL="$5"
shift 5

if [[ -z "$DISTRO" ]] || [[ -z "$VARIANT" ]] || [[ -z "$BUILD_ARCH" ]] || [[ -z "$MODEL" ]]; then
	echo "Usage: $0 <disk.img> <distro> <variant: mate, i3 or minimal> <arch> <model> <packages...>"
    echo "Empty DISTRO, VARIANT, BUILD_ARCH or MODEL."
	exit 1
fi

if [[ "$(id -u)" -ne "0" ]]; then
	echo "This script requires root."
	exit 1
fi

case "$VARIANT" in
    minimal)
        SIZE=2499
        ;;

    i3)
        SIZE=2499
        ;;

    mate)
        SIZE=4999
        ;;

    lxde)
        SIZE=3999
        ;;

    openmediavault)
        SIZE=2499
        ;;

    containers)
        SIZE=2999
        ;;

    *)
        echo "Unknown VARIANT: $VARIANT"
        exit 1
        ;;
esac

PWD=$(readlink -f .)
TEMP=$(mktemp -p $PWD -d -t "$MODEL-build-XXXXXXXXXX")
echo "> Building in $TEMP ..."

cleanup() {
    echo "> Cleaning up ..."
    umount "$TEMP/rootfs/boot/efi" || true
    umount "$TEMP/rootfs/boot" || true
    umount "$TEMP/rootfs" || true
    kpartx -d "${LODEV}" || true
    losetup -d "${LODEV}" || true
    rm -rf "$TEMP"
}
trap cleanup EXIT

TEMP_IMAGE="${OUT_IMAGE}.tmp"

set -ex

# Create
rm -f "$TEMP_IMAGE"
dd if=/dev/zero of="$TEMP_IMAGE" bs=1M seek=$((SIZE-1)) count=0

# Create partitions
echo Updating GPT...
parted -s "${TEMP_IMAGE}" mklabel gpt
parted -s "${TEMP_IMAGE}" unit s mkpart loader1             64       8063   # ~4MB
parted -s "${TEMP_IMAGE}" unit s mkpart boot_efi    fat16   8192     32767  # up-to 16MB => ~12MB
parted -s "${TEMP_IMAGE}" unit s mkpart linux_boot  ext4    32768    262143 # up-to 256MB => 240MB
parted -s "${TEMP_IMAGE}" unit s mkpart linux_root  ext4    262144   100%   # rest
parted -s "${TEMP_IMAGE}" set 3 legacy_boot on

# Assign lodevice
LODEV=$(losetup -f --show "${TEMP_IMAGE}")

# Map path from /dev/loop to /dev/mapper/loop
LODEVMAPPER="${LODEV/\/dev\/loop/\/dev\/mapper\/loop}"

# Assign partitions
kpartx -a "$LODEV"

LODEV_UBOOT="${LODEVMAPPER}p1"
LODEV_EFI="${LODEVMAPPER}p2"
LODEV_BOOT="${LODEVMAPPER}p3"
LODEV_ROOT="${LODEVMAPPER}p4"

# Make filesystem
mkfs.vfat -n "boot-efi" -S 512 "${LODEV_EFI}"
mkfs.ext4 -L "linux-boot" "${LODEV_BOOT}"
mkfs.ext4 -L "linux-root" "${LODEV_ROOT}"
tune2fs -o journal_data_writeback "${LODEV_ROOT}"

# Mount filesystem
mkdir -p "$TEMP/rootfs"
mount -o data=writeback,commit=3600 "${LODEV_ROOT}" "$TEMP/rootfs"
mkdir -p "$TEMP/rootfs/boot"
mount "${LODEV_BOOT}" "$TEMP/rootfs/boot"
mkdir -p "$TEMP/rootfs/boot/efi"
mount "${LODEV_EFI}" "$TEMP/rootfs/boot/efi"

# Create image
unshare -m -u -i -p --mount-proc --fork -- \
    rootfs/make-rootfs.sh "$TEMP/rootfs" "$DISTRO" "$VARIANT" "$BUILD_ARCH" "$MODEL" "$@"

# Write bootloader
dd if="$TEMP/rootfs/usr/lib/u-boot-${MODEL}/rksd_loader.img" of="${LODEV_UBOOT}"

# Sync all filesystems
sync -f "$TEMP/rootfs" "$TEMP/rootfs/boot" "$TEMP/rootfs/boot/efi"
fstrim "$TEMP/rootfs"
fstrim "$TEMP/rootfs/boot"
df -h "$TEMP/rootfs" "$TEMP/rootfs/boot" "$TEMP/rootfs/boot/efi"
mv "$TEMP/rootfs/all-packages.txt" "$(dirname "$OUT_IMAGE")/$(basename "$OUT_IMAGE" .img)-packages.txt"

# Umount filesystems
umount "$TEMP/rootfs/boot/efi"
umount "$TEMP/rootfs/boot"
umount "$TEMP/rootfs"

# Cleanup build
cleanup
trap - EXIT

# Verify partitions
parted -s "${TEMP_IMAGE}" print

# Move image into final location
mv "$TEMP_IMAGE" "$OUT_IMAGE"
