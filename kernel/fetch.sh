#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/version.env"

BUILD_DIR="${SCRIPT_DIR}/build"
APK_FILE="${BUILD_DIR}/${KERNEL_RELEASE}.apk"
EXTRACT_DIR="${BUILD_DIR}/extracted"
VMLINUX="${BUILD_DIR}/vmlinuz"
MODULES_DIR="${BUILD_DIR}/modules"
DTB_DIR="${BUILD_DIR}/dtbs"
KPART="${BUILD_DIR}/vmlinux.kpart"
INITRAMFS="${BUILD_DIR}/initramfs.img"
DEVKEYS_DIR="${DEVKEYS_DIR:-/usr/share/vboot/devkeys}"

mkdir -p "${BUILD_DIR}"

echo "==> Kernel: ${KERNEL_RELEASE}"
echo "==> Download: ${KERNEL_ARCHIVE_URL}"

# 1. Descargar el paquete .apk de postmarketOS
curl -fL --retry 3 -o "${APK_FILE}" "${KERNEL_ARCHIVE_URL}"

if [[ -n "${KERNEL_ARCHIVE_SHA256:-}" ]]; then
    echo "==> Verifying archive SHA-256..."
    echo "${KERNEL_ARCHIVE_SHA256}  ${APK_FILE}" | sha256sum -c -
else
    echo "==> WARNING: archive SHA-256 is not configured (skipping verification)"
fi

echo "==> Extracting APK (it's a standard tar.gz)..."
rm -rf "${EXTRACT_DIR}"
mkdir -p "${EXTRACT_DIR}"
tar -xzf "${APK_FILE}" -C "${EXTRACT_DIR}"

# 2. Extraer vmlinuz
VMLINUX_SOURCE=$(find "${EXTRACT_DIR}/boot" -maxdepth 1 -name "vmlinuz*" -type f | head -n 1)
[[ -f "${VMLINUX_SOURCE}" ]] || { echo "ERROR: vmlinuz not found"; exit 1; }
cp -f "${VMLINUX_SOURCE}" "${VMLINUX}"
echo "==> Found vmlinuz: ${VMLINUX_SOURCE}"

# 3. Extraer módulos
MODULES_SOURCE=$(find "${EXTRACT_DIR}/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d | head -n 1)
[[ -d "${MODULES_SOURCE}" ]] || { echo "ERROR: kernel modules not found"; exit 1; }
KERNEL_KVER="$(basename "${MODULES_SOURCE}")"
rm -rf "${MODULES_DIR}"
mkdir -p "${MODULES_DIR}"
cp -a "${MODULES_SOURCE}" "${MODULES_DIR}/"
echo "==> Found modules: ${KERNEL_KVER}"

# 4. Extraer TODOS los DTBs de Kukui
DTB_SOURCE_DIR=$(find "${EXTRACT_DIR}" -type d -path "*dtbs/mediatek" | head -n 1)
[[ -d "${DTB_SOURCE_DIR}" ]] || { echo "ERROR: DTBs directory not found"; exit 1; }

DTB_FILES=()
while IFS= read -r -d '' dtb; do
    DTB_FILES+=("${dtb}")
done < <(find "${DTB_SOURCE_DIR}" -name "${KERNEL_DTB_PATTERN}" -print0 | sort -z)

if [[ ${#DTB_FILES[@]} -eq 0 ]]; then
    echo "ERROR: no DTBs matching '${KERNEL_DTB_PATTERN}'. Available:"
    ls "${DTB_SOURCE_DIR}"
    exit 1
fi

echo "==> Found ${#DTB_FILES[@]} Kukui DTBs"

rm -rf "${DTB_DIR}"
mkdir -p "${DTB_DIR}"
cp -a "${DTB_SOURCE_DIR}" "${DTB_DIR}/"

# 5. Instalar módulos donde dracut los espera
echo "==> Staging modules to /lib/modules/${KERNEL_KVER}"
mkdir -p /lib/modules
rm -rf "/lib
