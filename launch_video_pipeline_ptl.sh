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

DEV_NAME=${1:-"tevs-ar0234-2"}

DEFAULT_RES="1280x720"
DEFAULT_FMT="UYVY"
CAM_RES="${2:-$DEFAULT_RES}"
IFS='x' read -r -a RES_ARRAY <<< "$CAM_RES"
VIDEO_WIDTH=${RES_ARRAY[0]}
VIDEO_HEIGHT=${RES_ARRAY[1]}

CAM_FMT="${3:-$DEFAULT_FMT}"

echo "device name: $DEV_NAME"
echo "width: $VIDEO_WIDTH, height: $VIDEO_HEIGHT, format=$CAM_FMT"

DEFAULT_TEST_MODE="CAM_PREVIEW"
TEST_MODE="${4:-$DEFAULT_TEST_MODE}"

# IO mode: 1=mmap (default), 4=DMABuf
IO_MODE="${5:-1}"

echo $TEST_MODE

# Caps and convert chain depend on IO mode
if [ "$IO_MODE" = "4" ]; then
    SOURCE_CAPS="video/x-raw(memory:DMABuf),drm-format=$CAM_FMT,width=$VIDEO_WIDTH,height=$VIDEO_HEIGHT"
    CONVERT="glupload ! glcolorconvert ! gldownload"
else
    SOURCE_CAPS="video/x-raw,format=$CAM_FMT,width=$VIDEO_WIDTH,height=$VIDEO_HEIGHT"
    CONVERT="videoconvert"
fi

# Kill any previous gst-launch holding video devices
sudo pkill -f gst-launch-1.0 2>/dev/null; sleep 0.3

if [ "$TEST_MODE" = "MULTICAMx2-CSI0" ]; then
   echo "Start $TEST_MODE Preview...."
   sudo -E gst-launch-1.0 \
    icamerasrc num-buffers=-1 printfps=true io-mode=$IO_MODE scene-mode=normal \
    device-name=vlsgm2-5 ! \
    "$SOURCE_CAPS" ! queue ! \
    $CONVERT ! xvimagesink sync=false --no-position \
\
    icamerasrc num-buffers=-1 printfps=true io-mode=$IO_MODE scene-mode=normal \
    device-name=vlsgm2-6 ! \
    "$SOURCE_CAPS" ! queue ! \
    $CONVERT ! xvimagesink sync=false --no-position

elif [ "$TEST_MODE" = "MULTICAMx2-CSI1" ]; then
   echo "Start $TEST_MODE Preview...."
   sudo -E gst-launch-1.0 \
    icamerasrc num-buffers=-1 printfps=true io-mode=$IO_MODE scene-mode=normal \
    device-name=vlsgm2-7 ! \
    "$SOURCE_CAPS" ! queue ! \
    $CONVERT ! xvimagesink sync=false --no-position \
\
    icamerasrc num-buffers=-1 printfps=true io-mode=$IO_MODE scene-mode=normal \
    device-name=vlsgm2-8 ! \
    "$SOURCE_CAPS" ! queue ! \
    $CONVERT ! xvimagesink sync=false --no-position

elif [ "$TEST_MODE" = "MULTICAMx4" ]; then
   echo "Start $TEST_MODE Preview...."
   sudo -E gst-launch-1.0 \
    icamerasrc num-buffers=-1 printfps=true io-mode=$IO_MODE scene-mode=normal \
    device-name=vlsgm2-5 ! \
    "$SOURCE_CAPS" ! queue ! \
    $CONVERT ! xvimagesink sync=false --no-position \
\
    icamerasrc num-buffers=-1 printfps=true io-mode=$IO_MODE scene-mode=normal \
    device-name=vlsgm2-6 ! \
    "$SOURCE_CAPS" ! queue ! \
    $CONVERT ! xvimagesink sync=false --no-position \
\
    icamerasrc num-buffers=-1 printfps=true io-mode=$IO_MODE scene-mode=normal \
    device-name=vlsgm2-7 ! \
    "$SOURCE_CAPS" ! queue ! \
    $CONVERT ! xvimagesink sync=false --no-position \
\
    icamerasrc num-buffers=-1 printfps=true io-mode=$IO_MODE scene-mode=normal \
    device-name=vlsgm2-8 ! \
    "$SOURCE_CAPS" ! queue ! \
    $CONVERT ! xvimagesink sync=false --no-position

elif [ "$TEST_MODE" = "MULTICAMx4-FAKESINK" ]; then
   echo "Start $TEST_MODE...."
   sudo -E gst-launch-1.0 \
    icamerasrc num-buffers=-1 printfps=true io-mode=$IO_MODE scene-mode=normal \
    device-name=vlsgm2-5 ! \
    "$SOURCE_CAPS" ! fakesink \
\
    icamerasrc num-buffers=-1 printfps=true io-mode=$IO_MODE scene-mode=normal \
    device-name=vlsgm2-6 ! \
    "$SOURCE_CAPS" ! fakesink \
\
    icamerasrc num-buffers=-1 printfps=true io-mode=$IO_MODE scene-mode=normal \
    device-name=vlsgm2-7 ! \
    "$SOURCE_CAPS" ! fakesink \
\
    icamerasrc num-buffers=-1 printfps=true io-mode=$IO_MODE scene-mode=normal \
    device-name=vlsgm2-8 ! \
    "$SOURCE_CAPS" ! fakesink

else
   echo "Start Camera Preview...."
   sudo -E gst-launch-1.0 \
    icamerasrc num-buffers=-1 printfps=true io-mode=$IO_MODE scene-mode=normal \
    device-name=$DEV_NAME ! \
    "$SOURCE_CAPS" ! queue ! \
    $CONVERT ! xvimagesink sync=false --no-position
fi
