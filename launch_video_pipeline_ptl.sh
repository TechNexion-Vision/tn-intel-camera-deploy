#!/bin/bash

# PTL (Panther Lake) IPU7 TEVS Camera Preview Script
# Adapted from intel-ipu6-drivers/intel-cam-setup/test/launch_video_pipeline.sh

# ── Environment ──────────────────────────────────────────────────────────────
export GST_PLUGIN_PATH=/usr/lib/gstreamer-1.0
export LD_LIBRARY_PATH=$LD_LIBRARY_PATH:/usr/lib
export LIBVA_DRIVER_NAME=iHD
export XDG_RUNTIME_DIR=/run/user/1000

# GNOME on Wayland: use mutter XWayland auth for X11 sinks, or Wayland socket
export DISPLAY=:0
export XAUTHORITY=$(find /run/user/1000/ -name ".mutter-Xwaylandauth.*" 2>/dev/null | head -1)
export WAYLAND_DISPLAY=wayland-0

# ── Parameters ───────────────────────────────────────────────────────────────
DEV_NAME=${1:-"tevs-ar0234-2"}

DEFAULT_RES="1280x720"
DEFAULT_FMT="UYVY"
CAM_RES="${2:-$DEFAULT_RES}"
IFS='x' read -r -a RES_ARRAY <<< "$CAM_RES"
VIDEO_WIDTH=${RES_ARRAY[0]}
VIDEO_HEIGHT=${RES_ARRAY[1]}
CAM_FMT="${3:-$DEFAULT_FMT}"

# IO mode: 1=mmap, 4=DMABuf
IO_MODE="${4:-1}"

# Sink: wayland (default), x11, fakesink
SINK_MODE="${5:-wayland}"

echo "=============================="
echo " PTL IPU7 Camera Preview"
echo "=============================="
echo " Device  : $DEV_NAME"
echo " Res     : ${VIDEO_WIDTH}x${VIDEO_HEIGHT}"
echo " Format  : $CAM_FMT"
echo " IO mode : $IO_MODE (1=mmap, 4=DMABuf)"
echo " Sink    : $SINK_MODE"
echo "=============================="

# ── Sink selection ────────────────────────────────────────────────────────────
if [ "$IO_MODE" = "4" ]; then
    # DMABuf path — requires icamerasrc built with --enable-gstdrmformat=yes
    SOURCE_CAPS="video/x-raw(memory:DMABuf),drm-format=${CAM_FMT},width=${VIDEO_WIDTH},height=${VIDEO_HEIGHT}"
    CONVERT="glupload ! glcolorconvert ! gldownload"
else
    # mmap path
    SOURCE_CAPS="video/x-raw,format=${CAM_FMT},width=${VIDEO_WIDTH},height=${VIDEO_HEIGHT}"
    CONVERT="videoconvert"
fi

case "$SINK_MODE" in
    wayland)
        SINK="waylandsink sync=false"
        ;;
    x11)
        SINK="xvimagesink sync=false"
        ;;
    fakesink)
        SINK="fakesink"
        CONVERT="identity"
        ;;
    *)
        echo "Unknown sink: $SINK_MODE. Use: wayland / x11 / fakesink"
        exit 1
        ;;
esac

echo "Starting preview... (Ctrl+C to stop)"
echo ""

gst-launch-1.0 \
    icamerasrc num-buffers=-1 printfps=true io-mode=${IO_MODE} scene-mode=normal \
    device-name=${DEV_NAME} ! \
    "${SOURCE_CAPS}" ! queue ! \
    ${CONVERT} ! \
    ${SINK}
