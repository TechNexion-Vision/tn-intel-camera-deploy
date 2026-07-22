#!/bin/bash
# install.sh — TechNexion PTL camera stack installer
#
# Installs:
#   1. Intel IPU7 kernel with TEVS support (linux-image-*.deb)
#   2. Camera userspace stack: HAL, GStreamer plugin, launch script (ipu7-camera-ptl.deb)
#   3. GRUB: set new kernel as default boot + add i915.force_probe=7d51
#
# Usage: sudo ./install.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ---------------------------------------------------------------------------
# Check root
# ---------------------------------------------------------------------------
if [ "$EUID" -ne 0 ]; then
    error "Run as root: sudo ./install.sh"
fi

echo ""
echo "=============================================="
echo " TechNexion PTL Camera Stack Installer"
echo "=============================================="
echo ""

# ---------------------------------------------------------------------------
# Locate debs
# ---------------------------------------------------------------------------
KERNEL_DEB=$(ls "${SCRIPT_DIR}"/linux-image-*.deb 2>/dev/null | grep -v '\-dbg' | head -1)
CAMERA_DEB=$(ls "${SCRIPT_DIR}"/ipu7-camera-ptl.deb 2>/dev/null | head -1)

[ -z "${KERNEL_DEB}" ]  && error "linux-image-*.deb not found in ${SCRIPT_DIR}"
[ -z "${CAMERA_DEB}" ]  && error "ipu7-camera-ptl.deb not found in ${SCRIPT_DIR}"

info "Kernel deb : $(basename "${KERNEL_DEB}")"
info "Camera deb : $(basename "${CAMERA_DEB}")"
echo ""

# Kernel release string (e.g. 6.17.0-tn-ptl-260128t080735z), used later to pin
# the GRUB default entry. The deb's Package name is "linux-image-<release>".
KERNEL_RELEASE="$(dpkg-deb -f "${KERNEL_DEB}" Package | sed 's/^linux-image-//')"

# ---------------------------------------------------------------------------
# Step 1: Install kernel
# ---------------------------------------------------------------------------
info "Installing kernel package..."
apt install -y "${KERNEL_DEB}" || error "Kernel installation failed."
info "Kernel installed."
echo ""

# ---------------------------------------------------------------------------
# Step 2: Install camera userspace stack
# ---------------------------------------------------------------------------
info "Installing camera userspace stack..."
apt install -y "${CAMERA_DEB}" || error "Camera stack installation failed."
info "Camera stack installed."
echo ""

# ---------------------------------------------------------------------------
# Step 3: GRUB modifications
# ---------------------------------------------------------------------------
GRUB_CFG=/etc/default/grub

info "Backing up ${GRUB_CFG} → ${GRUB_CFG}.bak"
cp "${GRUB_CFG}" "${GRUB_CFG}.bak"

# 3a: Pin GRUB_DEFAULT to this exact kernel's menu entry.
# GRUB_DEFAULT=0 is NOT safe here: grub-mkconfig lists kernels in version-sorted
# order, and a stock/HWE kernel (e.g. 7.0.0-28-generic) numerically outranks
# this TN kernel (6.17.x), so "entry 0" would silently boot the wrong kernel.
GRUB_DEFAULT_VALUE="Advanced options for Ubuntu>Ubuntu, with Linux ${KERNEL_RELEASE}"
if grep -q '^GRUB_DEFAULT=' "${GRUB_CFG}"; then
    sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"${GRUB_DEFAULT_VALUE}\"|" "${GRUB_CFG}"
else
    echo "GRUB_DEFAULT=\"${GRUB_DEFAULT_VALUE}\"" >> "${GRUB_CFG}"
fi
info "GRUB_DEFAULT pinned to: ${GRUB_DEFAULT_VALUE}"

# 3b: Add i915.force_probe=7d51 to kernel cmdline (idempotent)
if grep -q 'i915.force_probe=7d51' "${GRUB_CFG}"; then
    warn "i915.force_probe=7d51 already present in GRUB_CMDLINE_LINUX_DEFAULT, skipping."
else
    # Append to existing value; handle both empty and non-empty cases
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/GRUB_CMDLINE_LINUX_DEFAULT="\1 i915.force_probe=7d51"/' "${GRUB_CFG}"
    # Remove leading space if the original value was empty ("")
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=" /GRUB_CMDLINE_LINUX_DEFAULT="/' "${GRUB_CFG}"
    info "i915.force_probe=7d51 added to GRUB_CMDLINE_LINUX_DEFAULT."
fi

# 3c: Update GRUB
info "Running update-grub..."
update-grub
info "GRUB updated."
echo ""

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo "=============================================="
echo " Installation complete."
echo ""
echo " Next step: reboot to load the new kernel."
echo "   sudo reboot"
echo "=============================================="
echo ""

read -r -p "Reboot now? [y/N] " REPLY
if [[ "${REPLY}" =~ ^[Yy]$ ]]; then
    reboot
fi
