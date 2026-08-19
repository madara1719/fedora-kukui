#!/bin/bash
set -e

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/version.env"

BUILD_DIR="${SCRIPT_DIR}/build"
APK_FILE="${BUILD_DIR}/${KERNEL_RELEASE}.apk"
EXTRACT_DIR="${BUILD_DIR}/extracted"
VMLINUX="${BUILD_DIR}/vmlinuz"
MODULES_DIR="${BUILD_DIR}/modules"
DTB_DIR="${BUILD_DIR}/dtbs"
KPART="${BUILD_DIR}/vmlinux.kpart"

mkdir -p "${BUILD_DIR}"

echo "==> Kernel: ${KERNEL_RELEASE}"
echo "==> Download: ${KERNEL_ARCHIVE_URL}"

# 1. Descargar el paquete .apk de postmarketOS
curl -fL --retry 3 -o "${APK_FILE}" "${KERNEL_ARCHIVE_URL}"

if [[ -n "${KERNEL_ARCHIVE_SHA256}" ]]; then
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
VMLINUX_SOURCE=$(find "${EXTRACT_DIR}/boot" -name "vmlinuz*" -type f | head -n 1)
if [[ ! -f "${VMLINUX_SOURCE}" ]]; then
    echo "ERROR: vmlinuz not found in extracted APK"
    exit 1
fi
cp -f "${VMLINUX_SOURCE}" "${VMLINUX}"
echo "==> Found vmlinuz: ${VMLINUX_SOURCE}"

# 3. Extraer módulos
MODULES_SOURCE=$(find "${EXTRACT_DIR}/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d | head -n 1)
if [[ ! -d "${MODULES_SOURCE}" ]]; then
    echo "ERROR: kernel modules not found in extracted APK"
    exit 1
fi
rm -rf "${MODULES_DIR}"
mkdir -p "${MODULES_DIR}"
cp -a "${MODULES_SOURCE}" "${MODULES_DIR}/"
echo "==> Found modules in: ${MODULES_SOURCE}"

# 4. Extraer DTBs (Device Trees)
DTB_SOURCE=$(find "${EXTRACT_DIR}" -path "*/dtbs/mediatek" -type d | head -n 1)
if [[ -d "${DTB_SOURCE}" ]]; then
    rm -rf "${DTB_DIR}"
    mkdir -p "${DTB_DIR}"
    cp -a "${DTB_SOURCE}" "${DTB_DIR}/"
    echo "==> Found DTBs in: ${DTB_SOURCE}"
else
    echo "WARNING: DTBs not found in standard path, they might be bundled in vmlinuz or modules"
fi

# 5. Empaquetar vmlinux.kpart firmado con TUS devkeys
echo "==> Packing vmlinux.kpart with vbutil_kernel..."

# Ruta a tus devkeys. En local suele ser ~/devkeys o /usr/share/vboot/devkeys
# En GitHub Actions, deberás configurar esta variable de entorno o montar las claves
DEVKEYS_DIR="${DEVKEYS_DIR:-${HOME}/devkeys}"

if [[ ! -f "${DEVKEYS_DIR}/kernel.keyblock" ]]; then
    echo "ERROR: devkeys not found at ${DEVKEYS_DIR}/kernel.keyblock"
    echo "Please set the DEVKEYS_DIR environment variable to your devkeys path."
    exit 1
fi

# Crear archivo de cmdline
CMDLINE_FILE="${BUILD_DIR}/cmdline.txt"
echo "${KERNEL_CMDLINE}" > "${CMDLINE_FILE}"

# Crear un bootloader vacío de 4096 bytes (requerido por vbutil_kernel)
dd if=/dev/zero of="${BUILD_DIR}/empty_bootloader" bs=4096 count=1 status=none

# Empaquetar
vbutil_kernel --pack "${KPART}" \
    --keyblock "${DEVKEYS_DIR}/kernel.keyblock" \
    --signprivate "${DEVKEYS_DIR}/kernel_data_key.vbprivk" \
    --version 1 \
    --vmlinuz "${VMLINUX}" \
    --bootloader "${BUILD_DIR}/empty_bootloader" \
    --config "${CMDLINE_FILE}" \
    --arch arm

echo "==> Kernel ready."
echo "    kpart:   ${KPART}"
echo "    modules: ${MODULES_DIR}"

# Verificación final
echo "==> Verifying packed kpart..."
vbutil_kernel --verify "${KPART}" | grep -E "Config:|Body verification"
