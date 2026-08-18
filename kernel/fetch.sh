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
echo "==> Download: ${KERNEL_ARCHIVE_URL}"

curl -fL --retry 3 \
    -o "${ARCHIVE}" \
    "${KERNEL_ARCHIVE_URL}"

if [[ -n "${KERNEL_ARCHIVE_SHA256}" ]]; then
    echo "==> Verifying archive SHA-256..."
    echo "${KERNEL_ARCHIVE_SHA256}  ${ARCHIVE}" | sha256sum -c -
else
    echo "==> WARNING: archive SHA-256 is not configured"
fi

echo "==> Extracting archive..."

rm -rf "${EXTRACT_DIR}"
mkdir -p "${EXTRACT_DIR}"

tar -xzf "${ARCHIVE}" -C "${EXTRACT_DIR}"

KPART_SOURCE="${EXTRACT_DIR}/${KERNEL_KPART_PATH}"
MODULES_SOURCE="${EXTRACT_DIR}/${KERNEL_MODULES_PATH}"

if [[ ! -f "${KPART_SOURCE}" ]]; then
    echo "ERROR: kernel partition not found:"
    echo "       ${KPART_SOURCE}"
    exit 1
fi

if [[ ! -d "${MODULES_SOURCE}" ]]; then
    echo "ERROR: kernel modules not found:"
    echo "       ${MODULES_SOURCE}"
    exit 1
fi

echo "==> Installing vmlinux.kpart..."

cp -f "${KPART_SOURCE}" "${KPART}"

echo "==> Installing kernel modules..."

rm -rf "${MODULES_DIR}"
mkdir -p "${MODULES_DIR}"

cp -a "${MODULES_SOURCE}" "${MODULES_DIR}/"

echo "==> Verifying vmlinux.kpart..."

KPART_SHA256="$(sha256sum "${KPART}" | awk '{print $1}')"

printf 'EXPECTED: <%s>\n' "${KERNEL_KPART_SHA256}"
printf 'ACTUAL:   <%s>\n' "${KPART_SHA256}"

if [[ "${KPART_SHA256}" == "${KERNEL_KPART_SHA256}" ]]; then
    echo "==> HASH MATCH: yes"
else
    echo "==> HASH MATCH: no"
    exit 1
fi

echo "==> Kernel ready."
echo "    kpart:   ${KPART}"
echo "    modules: ${MODULES_DIR}"
