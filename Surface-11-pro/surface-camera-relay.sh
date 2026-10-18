#!/usr/bin/env bash
# Managed by surface11-camera. Installed by setup-system-cameras.sh.
set -euo pipefail
case "${1:-}" in
  front) node=libcamera_input.__SB_.PC00.I2C5.CAMF; device=/dev/video42; name='Surface Front Camera' ;;
  rear) node=libcamera_input.__SB_.PC00.I2C3.CAMR; device=/dev/video43; name='Surface Rear Camera' ;;
  *) echo 'Expected front or rear' >&2; exit 2 ;;
esac
# Fixed 640x480 YUYV is a widely supported baseline. No image-quality tuning.
# The relay holds only a black placeholder while idle, opens the physical
# PipeWire source on the loopback client-usage event, and releases it on idle.
# The relay writes appsink frames directly: v4l2sink rw output is unimplemented.
# This also avoids the loopback/GStreamer mmap dequeue path.
# Backend source names cannot match the loopback nodes, avoiding feedback.
input="pipewiresrc target-object=$node do-timestamp=true ! video/x-raw,width=640,height=480 ! videoconvert ! videorate ! video/x-raw,format=YUY2,width=640,height=480,framerate=30/1,pixel-aspect-ratio=1/1 ! identity"
output="appsrc name=appsrc caps=video/x-raw,format=YUY2,width=640,height=480,framerate=30/1,pixel-aspect-ratio=1/1 ! queue max-size-buffers=3 leaky=downstream ! appsink name=loopback-writer emit-signals=true max-buffers=3 drop=true sync=false async=false"
splash='videotestsrc is-live=true pattern=black ! video/x-raw,format=YUY2,width=640,height=480,framerate=30/1,pixel-aspect-ratio=1/1 ! identity'
if [[ ${2:-} == --validate ]]; then
  # Parse the exact relay descriptions without opening/streaming any camera.
  python3 - "$input" "$output" "$splash" <<'PYGST'
import sys
import gi
gi.require_version('Gst', '1.0')
from gi.repository import Gst
Gst.init(None)
for label, description in zip(['input', 'output', 'idle'], sys.argv[1:]):
    pipeline = Gst.parse_launch_full(description, None, Gst.ParseFlags.FATAL_ERRORS)
    if label != 'output' and Gst.Bin.find_unlinked_pad(pipeline, Gst.PadDirection.SRC) is None:
        raise SystemExit(f'{label}: no output pad for the relay appsink')
    if label == 'output':
        appsrc = pipeline.get_by_name('appsrc')
        sink = pipeline.get_by_name('loopback-writer')
        if sink is None or sink.get_factory().get_name() != 'appsink':
            raise SystemExit('Output must use the direct appsink writer, not v4l2sink.')
        if not sink.get_property('emit-signals') or sink.get_property('async'):
            raise SystemExit('Direct writer requires sample callbacks and synchronous startup.')
        required = Gst.Caps.from_string('video/x-raw,pixel-aspect-ratio=1/1')
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
exec /usr/local/libexec/surface11-camera/v4l2-relayd -i "$input" -o "$output" -s "$splash"
