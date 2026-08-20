#!/usr/bin/env bash
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

# Asegurar que los binarios instalados por pip estén en el PATH
export PATH="$PATH:$(python3 -m site --user-base)/bin:/root/.local/bin"

mkdir -p "${BUILD_DIR}"

echo "==> Kernel: ${KERNEL_RELEASE}"
echo "==> Download: ${KERNEL_ARCHIVE_URL}"

curl -fL --retry 3 -o "${APK_FILE}" "${KERNEL_ARCHIVE_URL}"

if [[ -n "${KERNEL_ARCHIVE_SHA256:-}" ]]; then
    echo "==> Verifying archive SHA-256..."
    echo "${KERNEL_ARCHIVE_SHA256}  ${APK_FILE}" | sha256sum -c -
else
    echo "==> WARNING: archive SHA-256 is not configured (skipping verification)"
fi

echo "==> Extracting APK..."
rm -rf "${EXTRACT_DIR}"
mkdir -p "${EXTRACT_DIR}"
tar -xzf "${APK_FILE}" -C "${EXTRACT_DIR}"

# --- vmlinuz ---
VMLINUX_SOURCE=$(find "${EXTRACT_DIR}/boot" -maxdepth 1 -name "vmlinuz*" -type f | head -n 1)
[[ -f "${VMLINUX_SOURCE}" ]] || { echo "ERROR: vmlinuz not found"; exit 1; }
cp -f "${VMLINUX_SOURCE}" "${VMLINUX}"
echo "==> Found vmlinuz: ${VMLINUX_SOURCE}"

# --- módulos ---
MODULES_SOURCE=$(find "${EXTRACT_DIR}/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d | head -n 1)
[[ -d "${MODULES_SOURCE}" ]] || { echo "ERROR: kernel modules not found"; exit 1; }
KERNEL_KVER="$(basename "${MODULES_SOURCE}")"
rm -rf "${MODULES_DIR}"
mkdir -p "${MODULES_DIR}"
cp -a "${MODULES_SOURCE}" "${MODULES_DIR}/"
echo "==> Found modules: ${KERNEL_KVER}"

# --- DTBs (todos los Kukui) ---
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

# --- Staging de módulos para dracut ---
echo "==> Staging modules to /lib/modules/${KERNEL_KVER}"
mkdir -p /lib/modules
rm -rf "/lib/modules/${KERNEL_KVER}"
cp -a "${MODULES_DIR}/${KERNEL_KVER}" "/lib/modules/${KERNEL_KVER}"
depmod -a "${KERNEL_KVER}" 2>/dev/null || true

# --- Generar initramfs con detección dinámica de drivers ---
echo "==> Generating initramfs with dracut"
DESIRED_DRIVERS="btrfs xhci-mtk xhci-hcd usb-storage uas sd-mod mmc-block"
AVAILABLE_DRIVERS=""

for drv in ${DESIRED_DRIVERS}; do
    # Buscar tanto con guiones como con guiones bajos
    drv_underscore=$(echo "${drv}" | tr '-' '_')
    drv_hyphen=$(echo "${drv}" | tr '_' '-')
    
    if find "/lib/modules/${KERNEL_KVER}" \( -name "${drv_underscore}.ko*" -o -name "${drv_hyphen}.ko*" \) -print -quit 2>/dev/null | grep -q .; then
        AVAILABLE_DRIVERS="${AVAILABLE_DRIVERS} ${drv}"
        echo "    ✓ Found driver: ${drv}"
    else
        echo "    ✗ Driver not found (skipping): ${drv}"
    fi
done

# Intentar con drivers detectados, fallback sin drivers explícitos si falla
if ! dracut --force --no-hostonly --no-early-microcode \
    --add-drivers "${AVAILABLE_DRIVERS}" \
    "${INITRAMFS}" "${KERNEL_KVER}"; then
    
    echo "WARNING: dracut failed with explicit drivers, retrying without --add-drivers"
    dracut --force --no-hostonly --no-early-microcode \
        "${INITRAMFS}" "${KERNEL_KVER}"
fi

if [[ ! -s "${INITRAMFS}" ]]; then
    echo "ERROR: initramfs generation failed completely"
    exit 1
fi
echo "==> initramfs: $(ls -lh "${INITRAMFS}" | awk '{print $5}')"

# --- Empaquetar kpart con mkdepthcharge ---
echo "==> Building kpart with mkdepthcharge"
[[ -f "${DEVKEYS_DIR}/kernel.keyblock" ]] || { echo "ERROR: devkeys not found at ${DEVKEYS_DIR}"; exit 1; }

if ! command -v mkdepthcharge &>/dev/null; then
    echo "ERROR: mkdepthcharge not found in PATH"
    echo "Current PATH: ${PATH}"
    echo "Python user-site: $(python3 -m site --user-base)/bin"
    ls -la "$(python3 -m site --user-base)/bin/" 2>/dev/null || true
    exit 1
fi

DTB_FLAGS=()
for dtb in "${DTB_FILES[@]}"; do
    DTB_FLAGS+=(--dtb "${dtb}")
done

mkdepthcharge \
    --output "${KPART}" \
    "${DTB_FLAGS[@]}" \
    --initramfs "${INITRAMFS}" \
    --cmdline "${KERNEL_CMDLINE}" \
    --devkeys "${DEVKEYS_DIR}" \
    "${VMLINUX}"

echo "==> Kernel ready."
echo "    kpart: $(ls -lh "${KPART}" | awk '{print $5}')"
echo "    modules: ${MODULES_DIR}"
echo "    DTBs: ${#DTB_FILES[@]} Kukui variants"

# --- Verificación final ---
echo "==> Verifying packed kpart..."
vbutil_kernel --verify "${KPART}" | grep -E "Config:|Body verification" || true
