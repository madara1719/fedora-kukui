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
tar -xzf "${APK_FILE}" -C "${EXTRACT_DIR}" 2>&1 | grep -v "APK-TOOLS.checksum.SHA1" || true

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

# --- staging de módulos para dracut ---
echo "==> Staging modules to /lib/modules/${KERNEL_KVER}"
mkdir -p /lib/modules
rm -rf "/lib/modules/${KERNEL_KVER}"
cp -a "${MODULES_DIR}/${KERNEL_KVER}" "/lib/modules/${KERNEL_KVER}"
depmod -a "${KERNEL_KVER}" 2>/dev/null || true

# ============================================================
# HOOKS DE DRACUT PARA DIAGNÓSTICO DE INPUT
# ============================================================
echo "==> Creating dracut diagnostic hooks"

# HOOK 1: captura dmesg durante initramfs (pre-mount)
HOOK1_DIR="/usr/lib/dracut/modules.d/99input-diag"
mkdir -p "${HOOK1_DIR}"

cat > "${HOOK1_DIR}/module-setup.sh" << 'EOF'
#!/usr/bin/env bash
check() { return 0; }
depends() { return 0; }
install() {
    inst_hook pre-mount 99 "${moddir}/input-diag.sh"
}
EOF

cat > "${HOOK1_DIR}/input-diag.sh" << 'EOF'
#!/usr/bin/env bash
{
    echo "=== INITRAMFS DIAG $(date) ==="
    echo "--- uname ---"
    uname -a
    echo "--- cmdline ---"
    cat /proc/cmdline
    echo "--- dmesg (cros/ec/elan/spi/i2c/input/mt8183) ---"
    dmesg | grep -iE 'cros|elan|spi|i2c|hid|input|keyboard|touchpad|mt8183|mediatek|probe|error|fail' | tail -100
    echo "--- /sys/bus/spi/devices ---"
    ls -la /sys/bus/spi/devices/ 2>&1 || true
    echo "--- /sys/bus/i2c/devices ---"
    ls -la /sys/bus/i2c/devices/ 2>&1 || true
    echo "--- modules loaded ---"
    cat /proc/modules 2>/dev/null | head -60
    echo "--- modules.builtin (cros/elan/input) ---"
    cat /lib/modules/$(uname -r)/modules.builtin 2>/dev/null | grep -iE 'cros|elan|input|hid|spi|i2c' || echo "none matched"
    echo "=== END INITRAMFS DIAG ==="
} > /run/input-diag-early.log 2>&1 || true
EOF

chmod +x "${HOOK1_DIR}/module-setup.sh" "${HOOK1_DIR}/input-diag.sh"

# HOOK 2: copia el log al rootfs después del mount
HOOK2_DIR="/usr/lib/dracut/modules.d/99copy-diag"
mkdir -p "${HOOK2_DIR}"

cat > "${HOOK2_DIR}/module-setup.sh" << 'EOF'
#!/usr/bin/env bash
check() { return 0; }
depends() { return 0; }
install() {
    inst_hook mount 99 "${moddir}/copy-diag.sh"
}
EOF

cat > "${HOOK2_DIR}/copy-diag.sh" << 'EOF'
#!/usr/bin/env bash
if [ -f /run/input-diag-early.log ]; then
    # Copiar a múltiples ubicaciones del rootfs montado en /sysroot
    cp /run/input-diag-early.log /sysroot/input-diag.log 2>/dev/null || true
    cp /run/input-diag-early.log /sysroot/root/input-diag.log 2>/dev/null || true
    mkdir -p /sysroot/var/log 2>/dev/null || true
    cp /run/input-diag-early.log /sysroot/var/log/input-diag.log 2>/dev/null || true
    sync
fi
EOF

chmod +x "${HOOK2_DIR}/module-setup.sh" "${HOOK2_DIR}/copy-diag.sh"

# Verificar que los hooks existen
echo "==> Verifying hooks exist before dracut"
[[ -f "${HOOK1_DIR}/module-setup.sh" ]] || { echo "ERROR: hook1 module-setup missing"; exit 1; }
[[ -f "${HOOK1_DIR}/input-diag.sh" ]] || { echo "ERROR: hook1 script missing"; exit 1; }
[[ -f "${HOOK2_DIR}/module-setup.sh" ]] || { echo "ERROR: hook2 module-setup missing"; exit 1; }
[[ -f "${HOOK2_DIR}/copy-diag.sh" ]] || { echo "ERROR: hook2 script missing"; exit 1; }
echo "==> Hooks verified OK"

# ============================================================
# GENERAR INITRAMFS CON HOOKS FORZADOS
# ============================================================
echo "==> Generating initramfs with dracut"

DESIRED_DRIVERS="btrfs xhci-hcd xhci-plat xhci-mtk xhci-mtk-hcd usb-storage uas sd-mod mmc-block"
AVAILABLE_DRIVERS=""

for drv in ${DESIRED_DRIVERS}; do
    drv_us=$(echo "${drv}" | tr '-' '_')
    drv_hy=$(echo "${drv}" | tr '_' '-')
    if find "/lib/modules/${KERNEL_KVER}" \
        \( -name "${drv_us}.ko*" -o -name "${drv_hy}.ko*" \) \
        -print -quit 2>/dev/null | grep -q .; then
        AVAILABLE_DRIVERS="${AVAILABLE_DRIVERS} ${drv_us}"
        echo "    + Found driver: ${drv}"
    else
        echo "    - Not a loadable module (built-in or absent): ${drv}"
    fi
done

# CLAVE: --force-add para incluir los módulos de diagnóstico personalizados
DRACUT_ARGS=(--force --no-hostonly --no-early-microcode --force-add "input-diag copy-diag")
if [[ -n "${AVAILABLE_DRIVERS// /}" ]]; then
    DRACUT_ARGS+=(--add-drivers "${AVAILABLE_DRIVERS# }")
fi

echo "==> dracut args: ${DRACUT_ARGS[*]}"

if ! dracut "${DRACUT_ARGS[@]}" "${INITRAMFS}" "${KERNEL_KVER}" 2>&1 | grep -v "No '/dev/log'"; then
    echo "WARNING: dracut failed with --add-drivers, retrying without extra drivers"
    dracut --force --no-hostonly --no-early-microcode \
        --force-add "input-diag copy-diag" \
        "${INITRAMFS}" "${KERNEL_KVER}" 2>&1 | grep -v "No '/dev/log'" || true
fi

if [[ ! -s "${INITRAMFS}" ]]; then
    echo "ERROR: initramfs generation failed completely"
    exit 1
fi
echo "==> initramfs: $(ls -lh "${INITRAMFS}" | awk '{print $5}')"

# Verificar que los hooks están dentro del initramfs
echo "==> Verifying hooks inside initramfs"
if command -v lsinitrd >/dev/null 2>&1; then
    lsinitrd "${INITRAMFS}" 2>/dev/null | grep -iE 'input-diag|copy-diag' && \
        echo "==> Hooks CONFIRMED in initramfs" || \
        echo "!!! WARNING: hooks NOT found in initramfs !!!"
else
    echo "==> lsinitrd not available, skipping hook verification"
fi

# ============================================================
# EMPAQUETAR KPART CON MKDEPTHCHARGE
# ============================================================
echo "==> Building kpart with mkdepthcharge"
[[ -f "${DEVKEYS_DIR}/kernel.keyblock" ]] || { echo "ERROR: devkeys not found at ${DEVKEYS_DIR}"; exit 1; }
command -v mkdepthcharge >/dev/null 2>&1 || { echo "ERROR: mkdepthcharge not found in PATH"; exit 1; }

for tool in mkimage dtc futility; do
    if command -v "${tool}" >/dev/null 2>&1; then
        echo "    + ${tool}: $(command -v "${tool}")"
    else
        echo "    ! WARNING: ${tool} not found"
    fi
done

POSITIONAL_ARGS=()
POSITIONAL_ARGS+=("${VMLINUX}")
POSITIONAL_ARGS+=("${INITRAMFS}")
for dtb in "${DTB_FILES[@]}"; do
    POSITIONAL_ARGS+=("${dtb}")
done

echo "==> Packing ${#DTB_FILES[@]} DTBs + kernel + initramfs into kpart"
echo "==> Output: ${KPART}"

set +e
mkdepthcharge \
    --output "${KPART}" \
    --cmdline "${KERNEL_CMDLINE}" \
    --keydir "${DEVKEYS_DIR}" \
    -- \
    "${POSITIONAL_ARGS[@]}" 2>&1 | tee /tmp/mkdepthcharge.log
MKDC_EXIT=$?
set -e

echo "==> mkdepthcharge exit code: ${MKDC_EXIT}"

if [[ ${MKDC_EXIT} -ne 0 ]] || [[ ! -f "${KPART}" ]] || [[ $(stat -c%s "${KPART}" 2>/dev/null || echo 0) -lt 1000 ]]; then
    echo "ERROR: mkdepthcharge failed to create valid kpart"
    cat /tmp/mkdepthcharge.log || true
    ls -la "${BUILD_DIR}/" || true
    exit 1
fi

echo "==> Kernel ready."
echo "    kpart: $(ls -lh "${KPART}" | awk '{print $5}')"
echo "    modules: ${MODULES_DIR}"
echo "    DTBs: ${#DTB_FILES[@]} Kukui variants"

echo "==> Verifying packed kpart..."
vbutil_kernel --verify "${KPART}" | grep -E "Config:|Body verification" || true
