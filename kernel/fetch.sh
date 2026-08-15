#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/version.env"

BUILD_DIR="${SCRIPT_DIR}/build"
ARCHIVE="${BUILD_DIR}/${KERNEL_RELEASE}.tar.gz"
EXTRACT_DIR="${BUILD_DIR}/archive"
KPART="${BUILD_DIR}/vmlinux.kpart"
MODULES_DIR="${BUILD_DIR}/modules"

mkdir -p "${BUILD_DIR}"

echo "==> Kernel: ${KERNEL_RELEASE}"

echo "==> Downloading kernel archive..."
curl -fL --retry 3 \
    -o "${ARCHIVE}" \
    "${KERNEL_ARCHIVE_URL}"

echo "==> Verifying SHA-256..."
echo "${KERNEL_SHA256}  ${ARCHIVE}" | sha256sum -c -

echo "==> Extracting archive..."
rm -rf "${EXTRACT_DIR}"
mkdir -p "${EXTRACT_DIR}"

tar -xzf "${ARCHIVE}" -C "${EXTRACT_DIR}"

echo "==> Locating vmlinux.kpart..."
KPART_SOURCE="${EXTRACT_DIR}/boot/vmlinux.kpart-${KERNEL_RELEASE}"

if [[ ! -f "${KPART_SOURCE}" ]]; then
    echo "ERROR: expected kernel partition not found:"
    echo "       ${KPART_SOURCE}"
    exit 1
fi

cp "${KPART_SOURCE}" "${KPART}"

echo "==> Installing kernel modules..."
rm -rf "${MODULES_DIR}"
mkdir -p "${MODULES_DIR}"

SOURCE_MODULES="${EXTRACT_DIR}/lib/modules"

if [[ ! -d "${SOURCE_MODULES}" ]]; then
    echo "ERROR: kernel modules not found:"
    echo "       ${SOURCE_MODULES}"
    exit 1
fi

cp -a "${SOURCE_MODULES}/." "${MODULES_DIR}/"

echo "==> Verifying extracted kernel..."
echo "    SHA-256:"
sha256sum "${KPART}"

echo "==> Kernel ready:"
echo "    ${KPART}"
echo "    ${MODULES_DIR}"
