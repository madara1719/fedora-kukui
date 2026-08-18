#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)" 
source "${ROOT_DIR}/kernel/version.env"

ROOTFS="${ROOTFS:-${ROOT_DIR}/build/rootfs}"
KERNEL="${KERNEL:-${ROOT_DIR}/build/kernel/vmlinux.kpart}"

IMAGE_DIR="${ROOT_DIR}/build/image"
IMAGE="${IMAGE_DIR}/fedora-kukui.img"

IMAGE_SIZE="${IMAGE_SIZE:-8G}"

LOOP=""
MAPPER=""
MNT_BOOT=""
MNT_ROOT=""

die() {
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    echo
    echo "==> $*"
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Falta la herramienta: $1"
}

cleanup() {
    set +e

    if [[ -n "${MNT_BOOT}" && -d "${MNT_BOOT}" ]]; then
        umount "${MNT_BOOT}" 2>/dev/null || true
    fi

    if [[ -n "${MNT_ROOT}" && -d "${MNT_ROOT}" ]]; then
        umount "${MNT_ROOT}" 2>/dev/null || true
    fi

    if [[ -n "${LOOP}" ]]; then
        kpartx -dv "${LOOP}" 2>/dev/null || true
        losetup -d "${LOOP}" 2>/dev/null || true
    fi

    if [[ -n "${MNT_BOOT}" && -d "${MNT_BOOT}" ]]; then
        rmdir "${MNT_BOOT}" 2>/dev/null || true
    fi

    if [[ -n "${MNT_ROOT}" && -d "${MNT_ROOT}" ]]; then
        rmdir "${MNT_ROOT}" 2>/dev/null || true
    fi
}

trap cleanup EXIT

# ----------------------------------------------------------------------
# Preconditions
# ----------------------------------------------------------------------

[[ "${EUID}" -eq 0 ]] || die "Ejecuta este script como root"

[[ -d "${ROOTFS}" ]] ||
    die "No existe el rootfs: ${ROOTFS}"

[[ -f "${KERNEL}" ]] ||
    die "No existe el kernel: ${KERNEL}"

require_cmd cgpt
require_cmd dd
require_cmd blkid
require_cmd kpartx
require_cmd losetup
require_cmd mkfs.ext4
require_cmd mkfs.btrfs
require_cmd mount
require_cmd rsync
require_cmd truncate
require_cmd udevadm

mkdir -p "${IMAGE_DIR}"

rm -f "${IMAGE}"

# ----------------------------------------------------------------------
# Create image
# ----------------------------------------------------------------------

info "Creating image: ${IMAGE_SIZE}"

truncate -s "${IMAGE_SIZE}" "${IMAGE}"

# ----------------------------------------------------------------------
# Create ChromeOS-compatible GPT
# ----------------------------------------------------------------------

info "Creating GPT"

# Reset any existing GPT metadata.
cgpt create -z "${IMAGE}"

# Create fresh GPT.
cgpt create "${IMAGE}"

# Create protective MBR.
cgpt boot -p "${IMAGE}"

# ----------------------------------------------------------------------
# Partition layout
#
# p1: KernelA
#     start 8192 sectors
#     size 262144 sectors = 128 MiB
#
# p2: KernelB
#     start 270336 sectors
#     size 262144 sectors = 128 MiB
#
# p3: /boot
#     start 532480 sectors
#     size 1048576 sectors = 512 MiB
#
# p4: /
#     start 1581056 sectors
#     remaining space
# ----------------------------------------------------------------------

info "Creating KernelA"

cgpt add \
    -i 1 \
    -b 8192 \
    -s 262144 \
    -t kernel \
    -l KernelA \
    -P 10 \
    -S 1 \
    -T 2 \
    "${IMAGE}"

info "Creating KernelB"

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

info "Creating boot partition"

cgpt add \
    -i 3 \
    -b 532480 \
    -s 1048576 \
    -t data \
    -l bootpart \
    -B 1 \
    "${IMAGE}"

# Determine the last usable sector from the GPT.
LAST_SECTOR="$(
    cgpt show "${IMAGE}" |
        awk '/Sec GPT table/ { print $1; exit }'
)"

[[ -n "${LAST_SECTOR}" ]] ||
    die "No se pudo determinar el final de la GPT"

ROOT_START=1581056

# Keep the secondary GPT table/header intact.
ROOT_SIZE=$((LAST_SECTOR - ROOT_START - 33))

(( ROOT_SIZE > 0 )) ||
    die "No hay espacio suficiente para la partición root"

info "Creating root partition"

cgpt add \
    -i 4 \
    -b "${ROOT_START}" \
    -s "${ROOT_SIZE}" \
    -t data \
    -l rootpart \
    "${IMAGE}"

sync

# ----------------------------------------------------------------------
# Verify GPT before writing filesystems
# ----------------------------------------------------------------------

info "Verifying GPT"

cgpt show "${IMAGE}"

# ----------------------------------------------------------------------
# Write kernel to KernelA / KernelB
# ----------------------------------------------------------------------

info "Writing KernelA"

dd \
    if="${KERNEL}" \
    of="${IMAGE}" \
    bs=512 \
    seek=8192 \
    conv=notrunc \
    status=progress

info "Writing KernelB"

dd \
    if="${KERNEL}" \
    of="${IMAGE}" \
    bs=512 \
    seek=270336 \
    conv=notrunc \
    status=progress

sync

# ----------------------------------------------------------------------
# Attach image as loop device
# ----------------------------------------------------------------------

info "Attaching loop device"

LOOP="$(losetup --find --show "${IMAGE}")"

[[ -n "${LOOP}" ]] ||
    die "No se pudo crear loop device"

info "Loop device: ${LOOP}"

# ----------------------------------------------------------------------
# Create partition mappings
# ----------------------------------------------------------------------

info "Creating partition mappings"

kpartx -av "${LOOP}"

udevadm settle

MAPPER="$(basename "${LOOP}")"

BOOT_DEV="/dev/mapper/${MAPPER}p3"
ROOT_DEV="/dev/mapper/${MAPPER}p4"

info "Partition devices"

ls -l \
    "/dev/mapper/${MAPPER}p1" \
    "/dev/mapper/${MAPPER}p2" \
    "${BOOT_DEV}" \
    "${ROOT_DEV}"

[[ -b "${BOOT_DEV}" ]] ||
    die "No existe ${BOOT_DEV}"

[[ -b "${ROOT_DEV}" ]] ||
    die "No existe ${ROOT_DEV}"

# ----------------------------------------------------------------------
# Create filesystems
# ----------------------------------------------------------------------

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

# ----------------------------------------------------------------------
# Mount filesystems
# ----------------------------------------------------------------------

MNT_BOOT="$(mktemp -d)"
MNT_ROOT="$(mktemp -d)"

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

# ----------------------------------------------------------------------
# Install Fedora rootfs
# ----------------------------------------------------------------------

info "Installing Fedora rootfs"

rsync \
    -aHAX \
    --numeric-ids \
    "${ROOTFS}/" \
    "${MNT_ROOT}/"

# ----------------------------------------------------------------------
# Populate /boot
# ----------------------------------------------------------------------

info "Preparing /boot"

mkdir -p "${MNT_BOOT}"

# We do not depend on the local kernel archive.
# The Chromebook boots from KernelA/KernelB.
#
# Keep /boot itself valid for Fedora, but do not copy artifacts that
# may not be available in the GitHub Actions image job.

mkdir -p "${MNT_BOOT}/lost+found"

# ----------------------------------------------------------------------
# Install /etc/fstab
# ----------------------------------------------------------------------

info "Generating fstab"

ROOT_UUID="$(blkid -s UUID -o value "${ROOT_DEV}")"
BOOT_UUID="$(blkid -s UUID -o value "${BOOT_DEV}")"

[[ -n "${ROOT_UUID}" ]] ||
    die "No se pudo obtener UUID de root"

[[ -n "${BOOT_UUID}" ]] ||
    die "No se pudo obtener UUID de boot"

cat > "${MNT_ROOT}/etc/fstab" <<EOF
UUID=${ROOT_UUID} / btrfs noatime,nodiratime,compress-force=zstd:3,ssd,discard=async 0 0
UUID=${BOOT_UUID} /boot ext4 noatime,nodiratime,errors=remount-ro 0 2
EOF

# ----------------------------------------------------------------------
# Basic validation
# ----------------------------------------------------------------------

info "Validating rootfs"

[[ -d "${MNT_ROOT}/usr" ]] ||
    die "El rootfs no contiene /usr"

[[ -d "${MNT_ROOT}/etc" ]] ||
    die "El rootfs no contiene /etc"

[[ -f "${MNT_ROOT}/etc/fstab" ]] ||
    die "No se creó /etc/fstab"

info "Validating kernel"

KERNEL_SHA256="$(sha256sum "${KERNEL}" | awk '{print $1}')"

echo "Kernel SHA-256:"
echo "${KERNEL_SHA256}"

if [[ "${KERNEL_SHA256}" != "${KERNEL_KPART_SHA256}" ]]; then
    die "SHA-256 inesperado para vmlinux.kpart"
fi

sync

# ----------------------------------------------------------------------
# Final report
# ----------------------------------------------------------------------

info "Final GPT"

cgpt show "${IMAGE}"

info "Image"

ls -lh "${IMAGE}"

info "Image build completed successfully"
