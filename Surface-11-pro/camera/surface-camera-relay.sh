#!/usr/bin/env bash
# Managed by surface11-camera. Build both inputs for one shared libcamera manager.
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ ${1:-} == run && $# == 1 ]]; then
  for ((attempt=0; attempt<30; attempt++)); do
    [[ -w /dev/video42 && -w /dev/video43 ]] && break
    sleep 1
  done
  [[ $(cat /sys/class/video4linux/video42/name) == 'Surface Front Camera' &&
     $(cat /sys/class/video4linux/video43/name) == 'Surface Rear Camera' ]] || exit 1
  mapfile -t front < <(bash "$SCRIPT_DIR/surface-camera-relay.sh" front --describe)
  mapfile -t rear < <(bash "$SCRIPT_DIR/surface-camera-relay.sh" rear --describe)
  exec "$SCRIPT_DIR/surface-camera-relay" "${front[0]}" "${rear[0]}"
fi
[[ $# == 2 && ( $2 == --describe || $2 == --validate ) ]] || {
  echo 'Usage: surface-camera-relay.sh run | {front|rear} {--describe|--validate}' >&2; exit 2;
}
case "$1" in
  front) camera='\\_SB_.PC00.I2C5.CAMF'; rotation=none; width=3200; height=1800 ;;
  rear) camera='\\_SB_.PC00.I2C3.CAMR'; rotation=rotate-180; width=1920; height=1080 ;;
  *) exit 2 ;;
esac
quality=${SURFACE11_CAMERA_QUALITY:-natural}
case "$quality" in
  # Keep chroma untouched: filtering subsampled color erases small color features.
  natural) filter='videoconvert ! video/x-raw,format=I420,colorimetry=bt709 ! videomedian name=surface-denoise filtersize=5 lum-only=true !' ;;
  balanced) filter='videoconvert ! video/x-raw,format=I420,colorimetry=bt709 ! videomedian name=surface-denoise filtersize=5 lum-only=false !' ;;
  detail) filter='' ;;
  *) echo 'SURFACE11_CAMERA_QUALITY must be natural, balanced or detail' >&2; exit 2 ;;
esac
# The CPU ISP crops. A larger 16:9 view followed by downsampling preserves field
# of view and reduces noise. Shared pixels and both APIs declare limited BT.709.
input="libcamerasrc name=surface-sensor camera-name=\"$camera\" ! video/x-raw,width=$width,height=$height,framerate=30/1,pixel-aspect-ratio=1/1 ! videoscale name=surface-scale method=lanczos add-borders=false ! video/x-raw,width=1280,height=720,pixel-aspect-ratio=1/1 ! $filter videoconvert ! videoflip name=surface-orientation method=$rotation ! videorate skip-to-first=true ! video/x-raw,format=YUY2,width=1280,height=720,framerate=30/1,pixel-aspect-ratio=1/1,colorimetry=bt709,chroma-site=mpeg2 ! identity"
if [[ $2 == --describe ]]; then printf '%s\n' "$input"; exit 0; fi
python3 - "$input" "$1" "$quality" <<'PY'
import sys
import gi
gi.require_version('Gst', '1.0')
from gi.repository import Gst
Gst.init(None)
pipeline = Gst.parse_launch_full(sys.argv[1], None, Gst.ParseFlags.FATAL_ERRORS)
expected = r'\_SB_.PC00.I2C5.CAMF' if sys.argv[2] == 'front' else r'\_SB_.PC00.I2C3.CAMR'
assert pipeline.get_by_name('surface-sensor').get_property('camera-name') == expected
assert (pipeline.get_by_name('surface-denoise') is not None) == (sys.argv[3] != 'detail')
if sys.argv[3] != 'detail':
    assert pipeline.get_by_name('surface-denoise').get_property('lum-only') == (sys.argv[3] == 'natural')
assert int(pipeline.get_by_name('surface-orientation').get_property('method')) == (0 if sys.argv[2] == 'front' else 2)
assert Gst.Bin.find_unlinked_pad(pipeline, Gst.PadDirection.SRC) is not None
pipeline.set_state(Gst.State.NULL)
print('PASS: direct capture, downsampling, denoise, orientation and shared HD pipeline parse')
PY
