#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

ROOTFS="${ROOT_DIR}/build/rootfs"
PACKAGES_DIR="${SCRIPT_DIR}/packages"

FEDORA_RELEASE="${FEDORA_RELEASE:-44}"
FEDORA_ARCH="${FEDORA_ARCH:-aarch64}"

BASE_PACKAGES="${PACKAGES_DIR}/base.txt"
XFCE_PACKAGES="${PACKAGES_DIR}/xfce.txt"

error() {
    echo "ERROR: $*" >&2
    exit 1
}

info() {
    echo
    echo "==> $*"
}

[[ -f "${BASE_PACKAGES}" ]] || error "No existe ${BASE_PACKAGES}"
[[ -f "${XFCE_PACKAGES}" ]] || error "No existe ${XFCE_PACKAGES}"

command -v dnf >/dev/null 2>&1 || error "dnf no está disponible"
command -v rsync >/dev/null 2>&1 || error "rsync no está disponible"

if [[ "${EUID}" -ne 0 ]]; then
    error "Este script debe ejecutarse como root"
fi

info "Fedora ${FEDORA_RELEASE} ${FEDORA_ARCH}"
info "Rootfs: ${ROOTFS}"

rm -rf "${ROOTFS}"
mkdir -p "${ROOTFS}"

# Leer listas de paquetes ignorando comentarios, líneas vacías y espacios finales.
mapfile -t BASE_PKGS < <(
    sed 's/[[:space:]]*$//' "${BASE_PACKAGES}" |
    grep -Ev '^[[:space:]]*(#|$)'
)

mapfile -t XFCE_PKGS < <(
    sed 's/[[:space:]]*$//' "${XFCE_PACKAGES}" |
    grep -Ev '^[[:space:]]*(#|$)'
)

# No queremos instalar el kernel de Fedora.
for pkg in "${BASE_PKGS[@]}" "${XFCE_PKGS[@]}"; do
    case "${pkg}" in
        kernel|kernel-core|kernel-modules|kernel-modules-core|kernel-modules-extra)
            error "Paquete de kernel detectado: ${pkg}"
            ;;
    esac
done

info "Instalando paquetes"

dnf \
    --releasever="${FEDORA_RELEASE}" \
    --installroot="${ROOTFS}" \
    --forcearch="${FEDORA_ARCH}" \
    --setopt=install_weak_deps=False \
    --setopt=keepcache=True \
    --assumeyes \
    install \
    "${BASE_PKGS[@]}" \
    "${XFCE_PKGS[@]}"

info "Configurando hostname"

echo "fedora-kukui" > "${ROOTFS}/etc/hostname"

cat > "${ROOTFS}/etc/hosts" <<'EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   fedora-kukui
EOF

info "Configurando locale"

cat > "${ROOTFS}/etc/locale.conf" <<'EOF'
LANG=en_US.UTF-8
EOF

info "Configurando timezone"

ln -sf /usr/share/zoneinfo/UTC "${ROOTFS}/etc/localtime"

info "Creando machine-id vacío"

mkdir -p "${ROOTFS}/etc"
: > "${ROOTFS}/etc/machine-id"

info "Configurando SDDM"

mkdir -p "${ROOTFS}/etc/sddm.conf.d"

cat > "${ROOTFS}/etc/sddm.conf.d/10-kukui.conf" <<'EOF'
[General]
DisplayServer=x11

[Autologin]
Relogin=false
EOF

info "Habilitando servicios"

systemctl --root="${ROOTFS}" enable NetworkManager.service
systemctl --root="${ROOTFS}" enable sddm.service

# Bluetooth solamente si el paquete/servicio está presente.
if [[ -f "${ROOTFS}/usr/lib/systemd/system/bluetooth.service" ]]; then
    systemctl --root="${ROOTFS}" enable bluetooth.service
fi

info "Limpiando caches"

rm -rf "${ROOTFS}/var/cache/dnf"
rm -rf "${ROOTFS}/var/log/dnf*"

info "Rootfs terminado"

du -sh "${ROOTFS}"

echo
echo "Rootfs generado en:"
echo "  ${ROOTFS}"
