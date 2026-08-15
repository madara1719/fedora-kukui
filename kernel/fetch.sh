#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=version.env
source "${SCRIPT_DIR}/version.env"

ROOT_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
SOURCE_DIR="${BUILD_DIR}/source"
RELEASE_DIR="${BUILD_DIR}/release"

mkdir -p "${BUILD_DIR}"
rm -rf "${SOURCE_DIR}" "${RELEASE_DIR}"

echo "==> Kernel: ${KERNEL_RELEASE}"
echo "==> Repository: ${KERNEL_REPO}"
echo "==> Commit: ${KERNEL_COMMIT}"

echo "==> Cloning kernel source..."
git clone \
    --depth 1 \
    --branch "${KERNEL_TAG}" \
    "${KERNEL_REPO}" \
    "${SOURCE_DIR}"

cd "${SOURCE_DIR}"

echo "==> Verifying commit..."
ACTUAL_COMMIT="$(git rev-parse HEAD)"

if [[ "${ACTUAL_COMMIT}" != "${KERNEL_COMMIT}" ]]; then
    echo "ERROR: unexpected commit"
    echo "Expected: ${KERNEL_COMMIT}"
    echo "Actual:   ${ACTUAL_COMMIT}"
    exit 1
fi

echo "==> Kernel source verified."
echo "    ${ACTUAL_COMMIT}"

echo "==> Kernel source is ready at:"
echo "    ${SOURCE_DIR}"
