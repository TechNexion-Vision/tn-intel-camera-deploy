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
kernel_debs=()
for deb in "${SCRIPT_DIR}"/linux-image-*.deb; do
    [ -f "${deb}" ] || continue
    [[ "$(basename "${deb}")" == *-dbg* ]] && continue
    kernel_debs+=("${deb}")
done

case ${#kernel_debs[@]} in
    0) error "linux-image-*.deb not found in ${SCRIPT_DIR}" ;;
    1) KERNEL_DEB=${kernel_debs[0]} ;;
    *) error "Multiple kernel image debs in ${SCRIPT_DIR}: ${kernel_debs[*]}" ;;
esac

CAMERA_DEB="${SCRIPT_DIR}/ipu7-camera-ptl.deb"
[ -f "${CAMERA_DEB}" ] || error "ipu7-camera-ptl.deb not found in ${SCRIPT_DIR}"

KERNEL_PACKAGE=$(dpkg-deb -f "${KERNEL_DEB}" Package) || error "Cannot read kernel package name from ${KERNEL_DEB}"
[[ "${KERNEL_PACKAGE}" =~ ^linux-image-[a-z0-9][a-z0-9.+_~-]*$ ]] || \
    error "Unexpected kernel package name: ${KERNEL_PACKAGE}"
KERNEL_RELEASE=${KERNEL_PACKAGE#linux-image-}

info "Kernel deb : $(basename "${KERNEL_DEB}")"
info "Kernel release: ${KERNEL_RELEASE}"
info "Camera deb : $(basename "${CAMERA_DEB}")"
echo ""

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
# The package version may be unchanged when repackaging board configuration.
apt install -y --reinstall "${CAMERA_DEB}" || error "Camera stack installation failed."
info "Camera stack installed."
echo ""

# ---------------------------------------------------------------------------
# Step 3: GRUB modifications
# ---------------------------------------------------------------------------
GRUB_CFG=${GRUB_CFG:-/etc/default/grub}

info "Backing up ${GRUB_CFG} → ${GRUB_CFG}.bak"
cp "${GRUB_CFG}" "${GRUB_CFG}.bak"

# 3a: Add i915.force_probe=7d51 to kernel cmdline (idempotent)
if grep -q 'i915.force_probe=7d51' "${GRUB_CFG}"; then
    warn "i915.force_probe=7d51 already present in GRUB_CMDLINE_LINUX_DEFAULT, skipping."
else
    # Append to existing value; handle both empty and non-empty cases
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"$/GRUB_CMDLINE_LINUX_DEFAULT="\1 i915.force_probe=7d51"/' "${GRUB_CFG}"
    # Remove leading space if the original value was empty ("")
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT=" /GRUB_CMDLINE_LINUX_DEFAULT="/' "${GRUB_CFG}"
    info "i915.force_probe=7d51 added to GRUB_CMDLINE_LINUX_DEFAULT."
fi

# 3b: Generate the menu before selecting the installed kernel's entry ID.
info "Running update-grub..."
update-grub
GRUB_MENU_CFG=${GRUB_MENU_CFG:-/boot/grub/grub.cfg}
[ -f "${GRUB_MENU_CFG}" ] || error "GRUB menu not found: ${GRUB_MENU_CFG}"

kernel_id_prefix="gnulinux-${KERNEL_RELEASE}-advanced-"
mapfile -t kernel_ids < <(awk -F"'" -v prefix="${kernel_id_prefix}" '
    $1 ~ /^[[:space:]]*menuentry[[:space:]]/ {
        for (i = 2; i <= NF; i += 2)
            if (index($i, prefix) == 1) print $i
    }
' "${GRUB_MENU_CFG}")
[ "${#kernel_ids[@]}" -eq 1 ] || \
    error "Expected one GRUB entry for ${KERNEL_RELEASE}, found ${#kernel_ids[@]} in ${GRUB_MENU_CFG}"

kernel_id=${kernel_ids[0]}
parent_id="gnulinux-advanced-${kernel_id#"${kernel_id_prefix}"}"
mapfile -t parent_ids < <(awk -F"'" -v id="${parent_id}" '
    $1 ~ /^[[:space:]]*submenu[[:space:]]/ {
        for (i = 2; i <= NF; i += 2)
            if ($i == id) print $i
    }
' "${GRUB_MENU_CFG}")

case ${#parent_ids[@]} in
    1) grub_default_id="${parent_id}>${kernel_id}" ;;
    0)
        if grep -Eq '^[[:space:]]*submenu .*gnulinux-advanced-' "${GRUB_MENU_CFG}"; then
            error "GRUB submenu ${parent_id} not found for ${KERNEL_RELEASE}"
        fi
        grub_default_id=${kernel_id}
        ;;
    *) error "Multiple GRUB submenus with ID ${parent_id}" ;;
esac

if grep -q '^GRUB_DEFAULT=' "${GRUB_CFG}"; then
    sed -i "s|^GRUB_DEFAULT=.*|GRUB_DEFAULT=\"${grub_default_id}\"|" "${GRUB_CFG}"
else
    printf 'GRUB_DEFAULT="%s"\n' "${grub_default_id}" >> "${GRUB_CFG}"
fi
info "GRUB_DEFAULT set to ${grub_default_id}."
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
