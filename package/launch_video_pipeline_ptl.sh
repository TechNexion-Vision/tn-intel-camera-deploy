#!/bin/bash

# Environments
export GST_PLUGIN_PATH=/usr/lib/gstreamer-1.0
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/lib
export LIBVA_DRIVER_NAME=iHD
export GST_GL_PLATFORM=egl
export DISPLAY=:0
export XAUTHORITY=$(find /run/user/$UID/ -name ".mutter-Xwaylandauth.*" 2>/dev/null)
export WAYLAND_DISPLAY=wayland-0
export XDG_RUNTIME_DIR=/run/user/$UID
# export GST_DEBUG="icamerasrc:7"
# export cameraDebug=7
# export GST_DEBUG_DUMP_DOT_DIR=./gst_debug/

# libcamhal config file on the board; override via env if needed
CAMHAL_CONFIG="${CAMHAL_CONFIG:-/etc/camera/ipu75xa/libcamhal_configs.json}"

DEFAULT_RES="1280x720"
DEFAULT_FMT="UYVY"

# If $1 is a mode name (MULTICAMx*), treat it as TEST_MODE directly.
# Otherwise treat $1 as DEV_NAME (single-cam path).
if [[ "$1" == MULTICAM* ]]; then
    TEST_MODE="$1"
    DEV_NAME=""
    CAM_RES="${2:-$DEFAULT_RES}"
    CAM_FMT="${3:-$DEFAULT_FMT}"
    IO_MODE="${4:-1}"
else
    DEV_NAME="${1:-tevs-ar0234-2}"
    CAM_RES="${2:-$DEFAULT_RES}"
    CAM_FMT="${3:-$DEFAULT_FMT}"
    TEST_MODE="${4:-CAM_PREVIEW}"
    IO_MODE="${5:-1}"
fi

IFS='x' read -r -a RES_ARRAY <<< "$CAM_RES"
VIDEO_WIDTH=${RES_ARRAY[0]}
VIDEO_HEIGHT=${RES_ARRAY[1]}

echo "mode: $TEST_MODE"
[ -n "$DEV_NAME" ] && echo "device name: $DEV_NAME"
echo "width: $VIDEO_WIDTH, height: $VIDEO_HEIGHT, format=$CAM_FMT"

# Caps and convert chain depend on IO mode
if [ "$IO_MODE" = "4" ]; then
    SOURCE_CAPS="video/x-raw(memory:DMABuf),drm-format=$CAM_FMT,width=$VIDEO_WIDTH,height=$VIDEO_HEIGHT"
    CONVERT="glupload ! glcolorconvert ! gldownload"
else
    SOURCE_CAPS="video/x-raw,format=$CAM_FMT,width=$VIDEO_WIDTH,height=$VIDEO_HEIGHT"
    CONVERT="videoconvert"
fi

# Returns whitespace-separated vlsgm2 device names for a given CSI port,
# parsed from libcamhal_configs.json entries of the form "vlsgm2-N-PORT".
get_vlsgm2_devices() {
    local port=$1
    if [ ! -f "$CAMHAL_CONFIG" ]; then
        echo "ERROR: $CAMHAL_CONFIG not found" >&2
        return 1
    fi
    grep -oE '"vlsgm2-[0-9]+-'"$port"'"' "$CAMHAL_CONFIG" \
        | tr -d '"' | sed "s/-${port}$//"
}

# Builds and runs a gst-launch-1.0 pipeline with one icamerasrc per device.
# Usage: run_multicam <sink_type> <dev1> [dev2 ...]
#   sink_type: "preview" or "fakesink"
run_multicam() {
    local sink_type=$1; shift
    local -a devices=("$@")

    if [ ${#devices[@]} -eq 0 ]; then
        echo "ERROR: no devices supplied to run_multicam" >&2
        exit 1
    fi

    echo "Devices: ${devices[*]}"

    local pipeline=""
    for dev in "${devices[@]}"; do
        pipeline+=" icamerasrc num-buffers=-1 printfps=true io-mode=$IO_MODE scene-mode=normal device-name='$dev'"
        pipeline+=" ! '$SOURCE_CAPS' ! queue !"
        if [ "$sink_type" = "fakesink" ]; then
            pipeline+=" fakesink"
        else
            pipeline+=" $CONVERT ! xvimagesink sync=false --no-position"
        fi
    done

    # Kill any previous gst-launch holding video devices
    sudo pkill -f gst-launch-1.0 2>/dev/null; sleep 0.3

    eval sudo -E gst-launch-1.0 "$pipeline"
}

# ── Mode dispatch ──────────────────────────────────────────────────────────────

if [ "$TEST_MODE" = "MULTICAMx4-CSI0" ]; then
    echo "Start $TEST_MODE Preview...."
    mapfile -t devs < <(get_vlsgm2_devices 0)
    run_multicam preview "${devs[@]}"

elif [ "$TEST_MODE" = "MULTICAMx4-CSI2" ]; then
    echo "Start $TEST_MODE Preview...."
    mapfile -t devs < <(get_vlsgm2_devices 2)
    run_multicam preview "${devs[@]}"

elif [ "$TEST_MODE" = "MULTICAMx8" ]; then
    echo "Start $TEST_MODE Preview...."
    mapfile -t devs0 < <(get_vlsgm2_devices 0)
    mapfile -t devs2 < <(get_vlsgm2_devices 2)
    run_multicam preview "${devs0[@]}" "${devs2[@]}"

else
    echo "Start Camera Preview...."
    # Kill any previous gst-launch holding video devices
    sudo pkill -f gst-launch-1.0 2>/dev/null; sleep 0.3
    sudo -E gst-launch-1.0 \
        icamerasrc num-buffers=-1 printfps=true io-mode=$IO_MODE scene-mode=normal \
        device-name=$DEV_NAME ! \
        "$SOURCE_CAPS" ! queue ! \
        $CONVERT ! xvimagesink sync=false --no-position
fi
