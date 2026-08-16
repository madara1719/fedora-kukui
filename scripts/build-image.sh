#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

ROOTFS="${ROOTFS:-${ROOT_DIR}/build/rootfs}"
KERNEL="${KERNEL:-${ROOT_DIR}/build/kernel/vmlinux.kpart}"

IMAGE_DIR="${ROOT_DIR}/build/image"
IMAGE="${IMAGE_DIR}/fedora-kukui.img"

# 8 GiB para el primer prototipo.
# Se puede sobrescribir:
# IMAGE_SIZE=16G ./scripts/build-image.sh
IMAGE_SIZE="${IMAGE_SIZE:-8G}"

die() {
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    echo
    echo "==> $*"
}

[[ "${EUID}" -eq 0 ]] || die "Este script debe ejecutarse como root"

[[ -d "${ROOTFS}" ]] ||
    die "No existe ${ROOTFS}"

[[ -f "${KERNEL}" ]] ||
    die "No existe ${KERNEL}"

command -v cgpt >/dev/null ||
    die "Falta cgpt"

command -v sgdisk >/dev/null ||
    die "Falta sgdisk"

command -v mkfs.ext4 >/dev/null ||
    die "Falta mkfs.ext4"

command -v mkfs.btrfs >/dev/null ||
    die "Falta mkfs.btrfs"

command -v losetup >/dev/null ||
    die "Falta losetup"

command -v mount >/dev/null ||
    die "Falta mount"

command -v rsync >/dev/null ||
    die "Falta rsync"

mkdir -p "${IMAGE_DIR}"

rm -f "${IMAGE}"

info "Creating image: ${IMAGE_SIZE}"

truncate -s "${IMAGE_SIZE}" "${IMAGE}"

info "Creating GPT"

cgpt create "${IMAGE}"

# 1 MiB alignment + ChromeOS kernel partitions.
# Exact layout taken from the working Kukui installation:
#
# p1: start 8192,  size 262144 sectors = 128 MiB
# p2: start 270336, size 262144 sectors = 128 MiB
# p3: start 532480, size 1048576 sectors = 512 MiB
# p4: start 1581056, remaining sectors

cgpt add \
    -i 1 \
    -b 8192 \
    -s 262144 \
    -t kernel \
    -l KernelA \
    -P 10 \
    -S 1 \
    -T 0 \
    "${IMAGE}"

cgpt add \
    -i 2 \
    -b 270336 \
    -s 262144 \
    -t kernel \
    -l KernelB \
    -P 0 \
    -S 0 \
    -T 0 \
    "${IMAGE}"

cgpt add \
    -i 3 \
    -b 532480 \
    -s 1048576 \
    -t data \
    -l bootpart \
    -B 1 \
    "${IMAGE}"

LAST_SECTOR="$(cgpt show "${IMAGE}" | awk '/Sec GPT table/ {print $1}')"

ROOT_START=1581056
ROOT_SIZE=$((LAST_SECTOR - ROOT_START - 33))

(( ROOT_SIZE > 0 )) ||
    die "No hay espacio suficiente para la partición root"

cgpt add \
    -i 4 \
    -b "${ROOT_START}" \
    -s "${ROOT_SIZE}" \
    -t data \
    -l rootpart \
    "${IMAGE}"

sync

info "Writing KernelA"

dd if="${KERNEL}" \
   of="${IMAGE}" \
   bs=512 \
   seek=8192 \
   conv=notrunc \
   status=progress

info "Writing KernelB"

dd if="${KERNEL}" \
   of="${IMAGE}" \
   bs=512 \
   seek=270336 \
   conv=notrunc \
   status=progress

sync

info "Attaching loop device"

LOOP="$(losetup --find --show --partscan "${IMAGE}")" 
 
info "Reloading partition table"

partx -a "${LOOP}" || true

udevadm settle || true

ls -l "${LOOP}"*

cleanup() {
    set +e

    umount "${MNT_BOOT}" 2>/dev/null || true
    umount "${MNT_ROOT}" 2>/dev/null || true

    losetup -d "${LOOP}" 2>/dev/null || true
}

trap cleanup EXIT

MNT_BOOT="$(mktemp -d)"
MNT_ROOT="$(mktemp -d)"

BOOT_DEV="${LOOP}p3"
ROOT_DEV="${LOOP}p4"

info "Formatting boot"

mkfs.ext4 \
    -F \
    -L bootpart \
    "${BOOT_DEV}"

info "Formatting root"

mkfs.btrfs \
    -f \
    -L rootpart \
    "${ROOT_DEV}"

info "Mounting root"

mount \
    -o noatime,nodiratime,compress-force=zstd:3,ssd,discard=async \
    "${ROOT_DEV}" \
    "${MNT_ROOT}"

info "Mounting boot"

mount \
    -o noatime,nodiratime \
    "${BOOT_DEV}" \
    "${MNT_BOOT}"

info "Installing Fedora rootfs"

rsync \
    -aHAX \
    --numeric-ids \
    "${ROOTFS}/" \
    "${MNT_ROOT}/"

info "Installing boot files"

mkdir -p "${MNT_BOOT}"

# For the first image we keep the kernel artifacts in /boot as well.
# The actual Chromebook boot kernel is p1/p2.
cp -a \
    "${ROOT_DIR}/kernel/build/archive/boot/." \
    "${MNT_BOOT}/" \
    2>/dev/null || true

info "Generating fstab"

ROOT_UUID="$(blkid -s UUID -o value "${ROOT_DEV}")"
BOOT_UUID="$(blkid -s UUID -o value "${BOOT_DEV}")"

mkdir -p "${MNT_ROOT}/etc"

cat > "${MNT_ROOT}/etc/fstab" <<EOF
UUID=${ROOT_UUID} / btrfs noatime,nodiratime,compress-force=zstd:3,ssd,discard=async 0 0
UUID=${BOOT_UUID} /boot ext4 noatime,nodiratime,errors=remount-ro 0 2
EOF

info "Finishing"

sync

echo
echo "Image:"
echo "  ${IMAGE}"
echo
echo "Partitions:"
cgpt show "${IMAGE}"

echo
echo "Image size:"
ls -lh "${IMAGE}"
