#!/usr/bin/env bash
# Managed by surface11-camera. Installed by setup-system-cameras.sh.
set -euo pipefail
[[ $# -le 2 ]] || { echo 'Expected camera and optional --validate/--describe' >&2; exit 2; }
case "${2:-}" in ''|--validate|--describe) ;; *) echo 'Unknown relay option' >&2; exit 2 ;; esac
case "${1:-}" in
  front) node=libcamera_input.__SB_.PC00.I2C5.CAMF; device=/dev/video42; name='Surface Front Camera'; rotation=none ;;
  rear) node=libcamera_input.__SB_.PC00.I2C3.CAMR; device=/dev/video43; name='Surface Rear Camera'; rotation=rotate-180 ;;
  *) echo 'Expected front or rear' >&2; exit 2 ;;
esac
# Keep the proven size until higher native modes pass host corruption/stride tests.
# Apply the same modest spatial denoise to every app; no temporal ghosting or
# digital brightening (which would also amplify noise). Override through a user
# service Environment= line for a sharpness/noise A/B comparison.
quality=${SURFACE11_CAMERA_QUALITY:-balanced}
# The front sensor needs stronger spatial cleanup than the rear.
median_size=5
[[ $1 != front ]] || median_size=9
case "$quality" in
  balanced) filter="videoconvert ! video/x-raw,format=I420,colorimetry=bt601 ! videomedian name=surface-denoise filtersize=$median_size lum-only=false !" ;;
  detail) filter='' ;;
  *) echo 'SURFACE11_CAMERA_QUALITY must be balanced or detail' >&2; exit 2 ;;
esac
# bt601 explicitly means limited-range YUV, 601 matrix, 709 transfer and
# SMPTE170M primaries. The direct V4L2 writer declares precisely the same tuple.
shared_caps='video/x-raw,format=YUY2,width=640,height=480,framerate=30/1,pixel-aspect-ratio=1/1,colorimetry=bt601,chroma-site=mpeg2'
# The relay holds only a black placeholder while idle, opens the physical
# PipeWire source on the loopback client-usage event, and releases it on idle.
# The relay writes appsink frames directly: v4l2sink rw output is unimplemented.
# This also avoids the loopback/GStreamer mmap dequeue path.
# Backend source names cannot match the loopback nodes, avoiding feedback.
# Bake the rear sensor's 180-degree mounting correction into the shared pixels;
# V4L2 consumers do not receive libcamera's rotation metadata.
input="pipewiresrc client-properties=props,application.name=surface11-camera-relay target-object=$node stream-properties=props,node.dont-fallback=true do-timestamp=true ! video/x-raw,width=640,height=480 ! $filter videoconvert ! videoflip name=surface-orientation method=$rotation ! videorate ! $shared_caps ! identity"
output="appsrc name=appsrc caps=$shared_caps ! queue max-size-buffers=3 leaky=downstream ! appsink name=loopback-writer emit-signals=true max-buffers=3 drop=true sync=false async=false"
splash="videotestsrc is-live=true pattern=black ! $shared_caps ! identity"
if [[ ${2:-} == --describe ]]; then
  printf '%s\n' "$input" "$output" "$splash"
  exit 0
fi
if [[ ${2:-} == --validate ]]; then
  # Parse the exact relay descriptions without opening/streaming any camera.
  python3 - "$input" "$output" "$splash" "$rotation" "$quality" "$median_size" <<'PYGST'
import sys
import gi
gi.require_version('Gst', '1.0')
from gi.repository import Gst
Gst.init(None)
for label, description in zip(['input', 'output', 'idle'], sys.argv[1:4]):
    pipeline = Gst.parse_launch_full(description, None, Gst.ParseFlags.FATAL_ERRORS)
    if label != 'output' and Gst.Bin.find_unlinked_pad(pipeline, Gst.PadDirection.SRC) is None:
        raise SystemExit(f'{label}: no output pad for the relay appsink')
    if label == 'input':
        denoise = pipeline.get_by_name('surface-denoise')
        if (denoise is not None) != (sys.argv[5] == 'balanced'):
            raise SystemExit('Input denoise does not match selected quality profile.')
        if denoise is not None and int(denoise.get_property('filtersize')) != int(sys.argv[6]):
            raise SystemExit('Input denoise strength does not match the camera profile.')
        orientation = pipeline.get_by_name('surface-orientation')
        expected = 2 if sys.argv[4] == 'rotate-180' else 0
        if orientation is None or int(orientation.get_property('method')) != expected:
            raise SystemExit('Input must apply the physical camera mounting correction.')
    if label == 'output':
        appsrc = pipeline.get_by_name('appsrc')
        sink = pipeline.get_by_name('loopback-writer')
        if sink is None or sink.get_factory().get_name() != 'appsink':
            raise SystemExit('Output must use the direct appsink writer, not v4l2sink.')
        if not sink.get_property('emit-signals') or sink.get_property('async'):
            raise SystemExit('Direct writer requires sample callbacks and synchronous startup.')
        required = Gst.Caps.from_string('video/x-raw,pixel-aspect-ratio=1/1,colorimetry=bt601,chroma-site=mpeg2')
        if not appsrc.get_property('caps').is_subset(required):
            raise SystemExit('Output caps must declare square pixels for V4L2 acceptance.')
    pipeline.set_state(Gst.State.NULL)
    print(f'PASS: {label} pipeline parses.')
PYGST
  exit 0
fi
for ((attempt=0; attempt<30; attempt++)); do
  [[ -w $device ]] && break
  sleep 1
done
[[ -w $device ]] || { echo "No write access to $device" >&2; exit 1; }
[[ $(cat "/sys/class/video4linux/${device##*/}/name") == "$name" ]] || exit 1
export SURFACE11_LOOPBACK_DEVICE="$device"
echo "Surface $1: quality=$quality, shared 640x480@30 YUYV limited-range BT.601; native auto exposure/white balance" >&2
exec /usr/local/libexec/surface11-camera/v4l2-relayd -i "$input" -o "$output" -s "$splash"
