#!/bin/bash
# ptl-camera.sh — Build and package the Intel IPU7 camera stack for Panther Lake.
#
# Usage:
#   ./ptl-camera.sh        — package only (requires staging/ and ipu7-camera-bins/ to exist)
#   ./ptl-camera.sh --all  — clone repos (if needed) + Docker build + package
#
# Files needed alongside this script:
#   Dockerfile.camera-builder   (same directory)
#
# Output: ptl-camera-out/ipu7-camera-ptl.deb
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# All repos, staging, and the output .deb land under this directory.
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
# Repo definitions
# ---------------------------------------------------------------------------
REPO_NAMES=(
    ipu7-camera-bins
    ipu7-camera-hal
    icamerasrc
)
REPO_URLS=(
    "https://github.com/intel/ipu7-camera-bins.git"
    "https://github.com/intel/ipu7-camera-hal.git"
    "https://github.com/intel/icamerasrc.git"
)
REPO_REFS=(
    "20251226_1140_191_PTL_PV_IoT"
    "20251226_1140_191_PTL_PV_IoT"
    "icamerasrc_slim_api"
)
REPO_TYPES=(tag tag branch)

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
# Step 2: Clone repos (only when --all)
#
# Logic per repo:
#   - dir missing OR ref missing → (re)clone
#   - dir exists AND ref exists  → skip
# This preserves local-only repos (e.g. tn-ipu7-camera-hal-config) and
# avoids redundant network fetches if repos were cloned in a previous run.
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
            git clone --branch "${ref}" "${url}" "${tmp_dir}"
        fi \
        || {
            rm -rf "${tmp_dir}"
            echo "ERROR: Failed to clone ${name} from ${url}"
            echo "  If this is a local-only repo, ensure it exists at: ${dir}"
            exit 1
        }
        rm -rf "${dir}"
        mv "${tmp_dir}" "${dir}"
        echo "[clone] Done: ${name}"
    done
}

# ---------------------------------------------------------------------------
# Step 3: Build Docker image (skip if already tagged ipu7-ptl-builder)
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
# Step 4: Run Docker container → build HAL + icamerasrc → staging/
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
# ipu7-camera-hal (Intel upstream) lacks TEVS sensor JSON; tn-ipu7-camera-hal-config
# provides libcamhal_configs.json and sensors/tevs-ar0234*.json so cmake install
# automatically picks them up into staging/etc/camera/ipu75xa/.
echo "[config] Applying tn-ipu7-camera-hal-config ..."
HAL_CONFIG="${HAL_DIR}/config/linux/ipu75xa"
cp "${CONFIG_REPO}/ipu75xa/libcamhal_configs.json" "${HAL_CONFIG}/"
cp "${CONFIG_REPO}/ipu75xa/sensors/"*.json         "${HAL_CONFIG}/sensors/"
echo "[config] Done."

# Install ipu7-camera-bins into the container's /usr/ (build dependency only).
# cmake uses pkg-config to find ia_imaging-ipu75xa and other ISP libs;
# their .so and .pc must be on system paths before cmake runs.
# -P preserves the symlink chain (libfoo.so → libfoo.so.1 → libfoo.so.1.0.0)
# so the linker resolves sonames correctly during the build.
echo "[bins] Installing ipu7-camera-bins to /usr/ ..."
cp -P "${BINS}/lib/"*.so*          /usr/lib/
cp -r "${BINS}/include/"*          /usr/include/
cp    "${BINS}/lib/pkgconfig/"*.pc /usr/lib/pkgconfig/
ldconfig
echo "[bins] Done."

# Build ipu7-camera-hal with cmake.
# DESTDIR redirects install into staging/ while preserving target-board paths:
#   staging/usr/lib/libcamhal.so*, staging/usr/lib/libcamhal/plugins/ipu75xa.so
#   staging/etc/camera/ipu75xa/   ← includes TN TEVS JSON from config step above
echo "[hal] Building ipu7-camera-hal ..."
cd "${HAL_DIR}"
rm -rf build   # avoid stale CMakeCache from a previous interrupted run
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
# cmake installed libcamhal.pc into staging/usr/lib/pkgconfig/, but pkg-config
# searches /usr/lib/pkgconfig (system path) — copy makes it visible without
# requiring PKG_CONFIG_PATH to point at staging.
echo "[hal] Making libcamhal visible to pkg-config ..."
cp -P "${STAGING}/usr/lib/libcamhal.so"*          /usr/lib/
cp    "${STAGING}/usr/lib/pkgconfig/libcamhal.pc"  /usr/lib/pkgconfig/
cp -r "${STAGING}/usr/include/libcamhal"           /usr/include/
ldconfig

# Build icamerasrc with autotools.
# CHROME_SLIM_CAMHAL=ON selects slim HAL API (required for PTL).
# NOCONFIGURE=1 prevents autogen.sh from auto-calling ./configure so we can
# pass our own flags. distclean removes stale Makefiles from a previous run.
echo "[icam] Building icamerasrc ..."
cd "${ICAM_DIR}"

if [ ! -f configure ]; then   # fresh clone has autogen.sh but no configure
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
# Everything built in the container is owned by root (uid 0); without this
# chown the host user cannot read or delete staging/ without sudo.
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
# Step 5: Merge staging + ipu7-camera-bins → .deb-work → ipu7-camera-ptl.deb
#
# staging/          contains: libcamhal, icamerasrc plugin, /etc/camera configs
# ipu7-camera-bins/ contains: ISP algorithm .so, firmware, headers, pkgconfig
# Both are merged into .deb-work, then dpkg-deb compresses to a .deb.
# ---------------------------------------------------------------------------
do_package() {
    echo "[package] Starting packaging ..."

    local BINS="${OUT_DIR}/ipu7-camera-bins"
    local DEB_WORK="${OUT_DIR}/.deb-work"
    local DEB_FILE="${OUT_DIR}/ipu7-camera-ptl.deb"

    # Validate prerequisites
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

    # Copy staging (libcamhal + icamerasrc plugin + /etc/camera configs)
    echo "[package] Copying staging artifacts ..."
    cp -a "${OUT_DIR}/staging/." "${DEB_WORK}/"

    # Add ISP algorithm libs from ipu7-camera-bins.
    # -P preserves the symlink chain (libfoo.so → libfoo.so.1 → libfoo.so.1.0.0)
    # so the linker resolves the correct soname at runtime on the board.
    echo "[package] Copying ipu7-camera-bins libraries ..."
    cp -P "${BINS}/lib/"*.so* "${DEB_WORK}/usr/lib/"

    # Strip dev-only artifacts not needed at runtime on the board
    echo "[package] Removing dev artifacts (headers, pkgconfig, .a, .la) ..."
    rm -rf "${DEB_WORK}/usr/include"
    rm -rf "${DEB_WORK}/usr/lib/pkgconfig"
    find "${DEB_WORK}/usr/lib" -name "*.a"  -delete
    find "${DEB_WORK}/usr/lib" -name "*.la" -delete

    # Firmware intentionally excluded: the board OS provides the correct version
    # (ipu7ptl_fw.bin.zst). Installing an older ipu7-camera-bins firmware causes
    # CSE authentication failure → IPU7 driver fails → ISYS never starts → no tevs probe.

    # DEBIAN/control
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
    # the new icamerasrc is picked up immediately without requiring a reboot.
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
    echo "==================================================================="
    echo "Output: ${DEB_FILE}"
    echo ""
    echo "Deploy to board:"
    echo "  sshpass -p ubuntu scp \"${DEB_FILE}\" ubuntu@<BOARD_IP>:/tmp/"
    echo "  ssh ubuntu@<BOARD_IP> 'sudo apt install /tmp/ipu7-camera-ptl.deb'"
    echo "==================================================================="
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
if $BUILD_MODE; then
    do_clone
    do_docker_build
    do_docker_run
fi

do_package
