#!/bin/bash
# ptl-camera.sh — Build and package the Intel IPU7 camera stack for Panther Lake.
#
# Usage:
#   ./ptl-camera.sh        — package + bundle only (requires existing staging/ and kernel deb)
#   ./ptl-camera.sh --all  — clone all repos + Docker build + kernel build + package + bundle
#
# Files needed alongside this script:
#   Dockerfile.camera-builder       (same directory)
#   package/install.sh              (bundled into tn-camera-ptl.tar.gz for board installation)
#   package/launch_video_pipeline_ptl.sh  (installed to /usr/local/bin/ inside the camera deb)
#
# Output:
#   ptl-camera-out/ipu7-camera-ptl.deb   — camera userspace deb
#   ptl-camera-out/tn-camera-ptl.tar.gz  — final deliverable (kernel deb + camera deb + install.sh)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# All repos, staging, output debs, and the final tarball land under this directory.
OUT_DIR="${SCRIPT_DIR}/ptl-camera-out"

BUILD_MODE=false

# ---------------------------------------------------------------------------
# Parse args
# ---------------------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        --all) BUILD_MODE=true ;;
        *) echo "ERROR: Unknown argument: ${arg}"; echo "Usage: $0 [--all]"; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Repo definitions — camera userspace + kernel overlay
#
# All repos are cloned into OUT_DIR/<name>/ so the whole build tree is
# self-contained under ptl-camera-out/.
#
# Clone strategy:
#   tag  → git clone --depth 1 --branch <ref>   (shallow, saves disk)
#   branch → git clone --branch <ref>            (full, kernel requires history to build)
# ---------------------------------------------------------------------------
REPO_NAMES=(
    ipu7-camera-bins
    ipu7-camera-hal
    icamerasrc
    tn-intel-linux-kernel-overlay
)
REPO_URLS=(
    "https://github.com/intel/ipu7-camera-bins.git"
    "https://github.com/intel/ipu7-camera-hal.git"
    "https://github.com/intel/icamerasrc.git"
    "https://github.com/TechNexion-Vision/tn-intel-linux-kernel-overlay.git"
)
REPO_REFS=(
    "20251226_1140_191_PTL_PV_IoT"
    "20251226_1140_191_PTL_PV_IoT"
    "icamerasrc_slim_api"
    "main"
)
REPO_TYPES=(tag tag branch branch)

# ---------------------------------------------------------------------------
# Kernel build configuration
# Update these three variables when bumping to a new kernel version.
# ---------------------------------------------------------------------------
KERNEL_DIR="${OUT_DIR}/tn-intel-linux-kernel-overlay"
KERNEL_BUILD_TAG="mainline-tracking-overlay-v6.17.11-ubuntu-260128T080735Z"
KERNEL_BUILD_NUMBER="1000"
KERNEL_BUILD_CONFIG="tn-ptl"

# ---------------------------------------------------------------------------
# Helper: return 0 if the repo at $dir already has the expected ref.
#
# Branch repos accept refs/heads/ (local branch) OR refs/remotes/origin/
# so that a local-only mock repo (no remote) is treated as already-cloned.
# ---------------------------------------------------------------------------
repo_has_ref() {
    local dir="$1" ref="$2" type="$3"
    [ -d "${dir}/.git" ] || return 1
    if [ "${type}" = "tag" ]; then
        git -C "${dir}" rev-parse "refs/tags/${ref}" >/dev/null 2>&1
    else
        git -C "${dir}" rev-parse "refs/heads/${ref}" >/dev/null 2>&1 || \
        git -C "${dir}" rev-parse "refs/remotes/origin/${ref}" >/dev/null 2>&1
    fi
}

# ---------------------------------------------------------------------------
# Step 1: Clone repos (only when --all)
#
# Per-repo logic:
#   - dir missing OR ref missing → (re)clone
#   - dir exists AND ref present → skip (avoids redundant network fetches)
#
# Tags use --depth 1 (shallow) to save disk space and clone time.
# Branches are cloned without --depth because the kernel build.sh requires
# a full git history (it embeds the commit count in the version string).
# ---------------------------------------------------------------------------
do_clone() {
    echo "[clone] Checking repos in: ${OUT_DIR}"
    mkdir -p "${OUT_DIR}"
    local i
    for i in "${!REPO_NAMES[@]}"; do
        local name="${REPO_NAMES[$i]}"
        local url="${REPO_URLS[$i]}"
        local ref="${REPO_REFS[$i]}"
        local type="${REPO_TYPES[$i]}"
        local dir="${OUT_DIR}/${name}"

        if repo_has_ref "${dir}" "${ref}" "${type}"; then
            echo "[clone] SKIP ${name} (${type} '${ref}' already present)"
            continue
        fi

        echo "[clone] Cloning ${name} @ ${ref} ..."
        local tmp_dir="${dir}.tmp.$$"
        if [ "${type}" = "tag" ]; then
            git clone --depth 1 --branch "${ref}" "${url}" "${tmp_dir}"
        else
            # Full clone for branch repos; kernel needs complete history to build.
            git clone --branch "${ref}" "${url}" "${tmp_dir}"
        fi \
        || {
            rm -rf "${tmp_dir}"
            echo "ERROR: Failed to clone ${name} from ${url}"
            exit 1
        }
        rm -rf "${dir}"
        mv "${tmp_dir}" "${dir}"
        echo "[clone] Done: ${name}"
    done
}

# ---------------------------------------------------------------------------
# Step 2: Build Docker image (skip if already tagged ipu7-ptl-builder)
#
# The Dockerfile installs cmake, autoconf, GStreamer-dev, libdrm, etc.
# Building happens only once; to force a rebuild: docker rmi ipu7-ptl-builder
# ---------------------------------------------------------------------------
do_docker_build() {
    if docker image inspect ipu7-ptl-builder >/dev/null 2>&1; then
        echo "[docker] Image ipu7-ptl-builder exists, skipping build."
        return
    fi
    echo "[docker] Building image ipu7-ptl-builder ..."
    docker build -t ipu7-ptl-builder \
        -f "${SCRIPT_DIR}/Dockerfile.camera-builder" \
        "${SCRIPT_DIR}" \
    || {
        echo "ERROR: Docker image build failed."
        echo "  To retry from scratch: docker rmi ipu7-ptl-builder"
        exit 1
    }
    echo "[docker] Image built."
}

# ---------------------------------------------------------------------------
# Step 3: Run Docker container → build HAL + icamerasrc → staging/
#
# The build script is passed inline via heredoc to bash -s (stdin), so no
# separate entrypoint file is needed in the repository.
# intel/ is mounted as /workspace; HOST_UID/GID let the container chown
# staging/ back to the host user after building as root.
# If staging/ is root-owned from a previous interrupted run, rm -rf fails
# here with an actionable error rather than silently leaving stale files.
# ---------------------------------------------------------------------------
do_docker_run() {
    if [ -d "${OUT_DIR}/staging" ]; then
        echo "[build] Removing old staging/ ..."
        rm -rf "${OUT_DIR}/staging" 2>/dev/null || {
            # staging is root-owned from an interrupted build; use Docker to remove it
            echo "[build] staging/ is root-owned, removing via Docker ..."
            docker run --rm -v "${OUT_DIR}:/data" ipu7-ptl-builder rm -rf /data/staging || {
                echo "ERROR: Cannot remove staging/."
                echo "  Fix: sudo rm -rf \"${OUT_DIR}/staging\""
                exit 1
            }
        }
    fi

    echo "[build] Running Docker build container ..."
    docker run --rm -i \
        -v "${SCRIPT_DIR}:/workspace" \
        -e HOST_UID="$(id -u)" \
        -e HOST_GID="$(id -g)" \
        ipu7-ptl-builder \
        bash -s <<'DOCKER_SCRIPT'
set -euo pipefail

OUT_DIR="/workspace/ptl-camera-out"
STAGING="${OUT_DIR}/staging"
BINS="${OUT_DIR}/ipu7-camera-bins"
CONFIG_REPO="/workspace/tn-ipu7-camera-hal-config"
HAL_DIR="${OUT_DIR}/ipu7-camera-hal"
ICAM_DIR="${OUT_DIR}/icamerasrc"

echo "=== PTL Camera Build (inside container) ==="

# Apply TN config files into ipu7-camera-hal source tree before cmake.
echo "[config] Applying tn-ipu7-camera-hal-config ..."
HAL_CONFIG="${HAL_DIR}/config/linux/ipu75xa"
cp "${CONFIG_REPO}/ipu75xa/libcamhal_configs.json" "${HAL_CONFIG}/"
cp "${CONFIG_REPO}/ipu75xa/sensors/"*.json         "${HAL_CONFIG}/sensors/"
echo "[config] Done."

# Install ipu7-camera-bins into the container's /usr/ (build dependency only).
# -P preserves the symlink chain so the linker resolves sonames correctly.
echo "[bins] Installing ipu7-camera-bins to /usr/ ..."
cp -P "${BINS}/lib/"*.so*          /usr/lib/
cp -r "${BINS}/include/"*          /usr/include/
cp    "${BINS}/lib/pkgconfig/"*.pc /usr/lib/pkgconfig/
ldconfig
echo "[bins] Done."

# Build ipu7-camera-hal with cmake.
# DESTDIR redirects install into staging/ while preserving target-board paths.
echo "[hal] Building ipu7-camera-hal ..."
cd "${HAL_DIR}"
rm -rf build
mkdir build && cd build

PKG_CONFIG_PATH=/usr/lib/pkgconfig cmake \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/usr \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_CAMHAL_ADAPTOR=ON \
    -DBUILD_CAMHAL_PLUGIN=ON \
    -DIPU_VERSIONS="ipu7x;ipu75xa" \
    -DUSE_STATIC_GRAPH=ON \
    -DUSE_STATIC_GRAPH_AUTOGEN=ON \
    ..

make -j"$(nproc)"
make DESTDIR="${STAGING}" install
echo "[hal] Done."

# Copy libcamhal into container /usr/ so icamerasrc ./configure can find it.
echo "[hal] Making libcamhal visible to pkg-config ..."
cp -P "${STAGING}/usr/lib/libcamhal.so"*          /usr/lib/
cp    "${STAGING}/usr/lib/pkgconfig/libcamhal.pc"  /usr/lib/pkgconfig/
cp -r "${STAGING}/usr/include/libcamhal"           /usr/include/
ldconfig

# Build icamerasrc with autotools.
# CHROME_SLIM_CAMHAL=ON selects the slim HAL API required for PTL.
echo "[icam] Building icamerasrc ..."
cd "${ICAM_DIR}"

if [ ! -f configure ]; then
    NOCONFIGURE=1 ./autogen.sh
fi

if [ -f Makefile ]; then
    make distclean || true
fi

CHROME_SLIM_CAMHAL=ON \
PKG_CONFIG_PATH=/usr/lib/pkgconfig \
    ./configure --prefix=/usr --enable-gstdrmformat=yes

make -j"$(nproc)"
make DESTDIR="${STAGING}" install
echo "[icam] Done."

# Restore staging/ ownership to the host user.
# Without this, the host user cannot delete staging/ without sudo.
if [ -n "${HOST_UID:-}" ] && [ -n "${HOST_GID:-}" ]; then
    echo "[chown] Restoring ownership to ${HOST_UID}:${HOST_GID} ..."
    chown -R "${HOST_UID}:${HOST_GID}" "${STAGING}"
    chown -R "${HOST_UID}:${HOST_GID}" "${HAL_DIR}/build"
fi

echo ""
echo "=== Build complete. staging: ${STAGING} ==="
DOCKER_SCRIPT
    local exit_code=$?
    if [ ${exit_code} -ne 0 ]; then
        echo "ERROR: Docker build run failed."
        echo "  If image may be stale: docker rmi ipu7-ptl-builder  then re-run."
        exit 1
    fi
    echo "[build] Docker build completed."
}

# ---------------------------------------------------------------------------
# Step 4: Build kernel deb from tn-intel-linux-kernel-overlay
#
# Skips if linux-image-*.deb already exists in KERNEL_DIR/build/.
# To force a rebuild, delete the existing debs:
#   rm -f ptl-camera-out/tn-intel-linux-kernel-overlay/build/linux-image-*.deb
# ---------------------------------------------------------------------------
do_build_kernel() {
    if [ ! -d "${KERNEL_DIR}" ]; then
        echo "ERROR: Kernel repo not found at ${KERNEL_DIR}"
        echo "  Run: ./ptl-camera.sh --all"
        exit 1
    fi

    # Check for an existing non-dbg image deb; skip if found.
    local existing
    existing=$(ls "${KERNEL_DIR}/linux-image-"*.deb 2>/dev/null | grep -v '\-dbg' | head -1 || true)
    if [ -n "${existing}" ]; then
        echo "[kernel] SKIP build — deb already exists: $(basename "${existing}")"
        echo "  To rebuild: rm ${KERNEL_DIR}/linux-image-*.deb"
        return
    fi

    echo "[kernel] Building kernel deb (this may take 30+ minutes) ..."
    echo "[kernel] Tag=${KERNEL_BUILD_TAG} Build=${KERNEL_BUILD_NUMBER} Config=${KERNEL_BUILD_CONFIG}"
    cd "${KERNEL_DIR}"
    ./build.sh -r no \
        -t "${KERNEL_BUILD_TAG}" \
        -b "${KERNEL_BUILD_NUMBER}" \
        -c "${KERNEL_BUILD_CONFIG}" \
    || {
        echo "ERROR: Kernel build failed."
        echo "  Check build logs in ${KERNEL_DIR}/build/"
        exit 1
    }
    echo "[kernel] Kernel build complete."
}

# ---------------------------------------------------------------------------
# Step 5: Merge staging + ipu7-camera-bins → .deb-work → ipu7-camera-ptl.deb
#
# staging/          contains: libcamhal, icamerasrc plugin, /etc/camera configs
# ipu7-camera-bins/ contains: ISP algorithm .so files
# Both are merged into .deb-work, stripped of dev artifacts, then packed.
# ---------------------------------------------------------------------------
do_package() {
    echo "[package] Starting packaging ..."

    local BINS="${OUT_DIR}/ipu7-camera-bins"
    local DEB_WORK="${OUT_DIR}/.deb-work"
    local DEB_FILE="${OUT_DIR}/ipu7-camera-ptl.deb"

    if [ ! -d "${OUT_DIR}/staging" ]; then
        echo "ERROR: staging/ not found. Run: ./ptl-camera.sh --all"
        exit 1
    fi
    if [ ! -d "${BINS}" ]; then
        echo "ERROR: ipu7-camera-bins/ not found. Run: ./ptl-camera.sh --all"
        exit 1
    fi
    if ! command -v dpkg-deb >/dev/null 2>&1; then
        echo "ERROR: dpkg-deb not installed. Fix: sudo apt install dpkg-dev"
        exit 1
    fi

    rm -rf "${DEB_WORK}"
    mkdir -p "${DEB_WORK}/DEBIAN"
    mkdir -p "${DEB_WORK}/usr/lib"

    echo "[package] Copying staging artifacts ..."
    cp -a "${OUT_DIR}/staging/." "${DEB_WORK}/"

    # -P preserves symlink chains (libfoo.so → libfoo.so.1 → libfoo.so.1.0.0)
    echo "[package] Copying ipu7-camera-bins libraries ..."
    cp -P "${BINS}/lib/"*.so* "${DEB_WORK}/usr/lib/"

    # Strip dev-only artifacts not needed at runtime on the board
    echo "[package] Removing dev artifacts (headers, pkgconfig, .a, .la) ..."
    rm -rf "${DEB_WORK}/usr/include"
    rm -rf "${DEB_WORK}/usr/lib/pkgconfig"
    find "${DEB_WORK}/usr/lib" -name "*.a"  -delete
    find "${DEB_WORK}/usr/lib" -name "*.la" -delete

    # Install launch script into the deb so it's available to all users after install
    install -Dm755 "${SCRIPT_DIR}/package/launch_video_pipeline_ptl.sh" \
        "${DEB_WORK}/usr/local/bin/launch_video_pipeline_ptl.sh"

    # Firmware intentionally excluded: the board OS provides the correct version.
    # Installing an older ipu7-camera-bins firmware causes CSE authentication
    # failure → IPU7 driver fails to start → no ISYS → no /dev/video nodes.

    cat > "${DEB_WORK}/DEBIAN/control" <<'EOF'
Package: ipu7-camera-ptl
Version: 1.0
Architecture: amd64
Maintainer: TechNexion <support@technexion.com>
Depends: libgstreamer1.0-0, gstreamer1.0-plugins-base, libdrm2, libva2, gstreamer1.0-vaapi, gstreamer1.0-plugins-bad, libjsoncpp25
Description: Intel IPU7 Camera Stack for Panther Lake (TEVS AR0234)
 Includes ipu7-camera-bins ISP libraries, ipu7-camera-hal,
 icamerasrc GStreamer plugin, and TEVS sensor configuration.
 Supports TEVS AR0234 camera on CSI port 0 and CSI port 2.
EOF

    # postinst: refresh linker cache and clear GStreamer plugin registry so
    # the new icamerasrc is discovered without requiring a reboot.
    cat > "${DEB_WORK}/DEBIAN/postinst" <<'EOF'
#!/bin/bash
set -e
ldconfig
rm -rf /root/.cache/gstreamer-1.0/ /home/*/.cache/gstreamer-1.0/ 2>/dev/null || true
EOF
    chmod 0755 "${DEB_WORK}/DEBIAN/postinst"

    echo "[package] Building .deb ..."
    dpkg-deb --build "${DEB_WORK}" "${DEB_FILE}"
    rm -rf "${DEB_WORK}"

    echo ""
    echo "[verify] Package info:"
    dpkg -I "${DEB_FILE}"
    echo ""
    echo "[verify] Package contents (first 50 files):"
    dpkg -c "${DEB_FILE}" 2>/dev/null | head -50 || true
    echo ""
    echo "[package] Done: ${DEB_FILE}"
}

# ---------------------------------------------------------------------------
# Step 6: Bundle kernel deb + camera deb + install.sh → tn-camera-ptl.tar.gz
#
# The tarball is self-contained: copy it to a board and run install.sh as root.
# On re-run the tarball is always rebuilt to pick up the latest deb files.
# ---------------------------------------------------------------------------
do_bundle() {
    echo "[bundle] Creating tn-camera-ptl.tar.gz ..."

    local KERNEL_DEB
    KERNEL_DEB=$(ls "${KERNEL_DIR}/linux-image-"*.deb 2>/dev/null | grep -v '\-dbg' | head -1 || true)
    local CAMERA_DEB="${OUT_DIR}/ipu7-camera-ptl.deb"
    local INSTALL_SH="${SCRIPT_DIR}/package/install.sh"
    local PKG="tn-camera-ptl"
    local PKG_DIR="${OUT_DIR}/${PKG}"
    local TAR="${OUT_DIR}/${PKG}.tar.gz"

    if [ -z "${KERNEL_DEB}" ]; then
        echo "ERROR: Kernel deb not found in ${KERNEL_DIR}/"
        echo "  Run: ./ptl-camera.sh --all"
        exit 1
    fi
    if [ ! -f "${CAMERA_DEB}" ]; then
        echo "ERROR: Camera deb not found: ${CAMERA_DEB}"
        exit 1
    fi
    if [ ! -f "${INSTALL_SH}" ]; then
        echo "ERROR: install.sh not found: ${INSTALL_SH}"
        exit 1
    fi

    rm -rf "${PKG_DIR}"
    mkdir -p "${PKG_DIR}"
    cp "${KERNEL_DEB}" "${PKG_DIR}/"
    cp "${CAMERA_DEB}" "${PKG_DIR}/"
    cp "${INSTALL_SH}" "${PKG_DIR}/"
    chmod +x "${PKG_DIR}/install.sh"

    tar czf "${TAR}" -C "${OUT_DIR}" "${PKG}"
    rm -rf "${PKG_DIR}"

    echo ""
    echo "==================================================================="
    echo "Bundle: ${TAR}"
    echo ""
    echo "Deploy to board:"
    echo "  scp ${TAR} <user>@<BOARD_IP>:~/"
    echo "  ssh <user>@<BOARD_IP> 'tar xf tn-camera-ptl.tar.gz && sudo ./tn-camera-ptl/install.sh'"
    echo "==================================================================="
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if $BUILD_MODE; then
    do_clone
    do_docker_build
    do_docker_run
    do_build_kernel
fi

do_package
do_bundle
