#!/usr/bin/env bash
# Managed by surface11-camera. Installed by setup-system-cameras.sh.
set -euo pipefail
case "${1:-}" in
  front) node=libcamera_input.__SB_.PC00.I2C5.CAMF; device=/dev/video42; name='Surface Front Camera' ;;
  rear) node=libcamera_input.__SB_.PC00.I2C3.CAMR; device=/dev/video43; name='Surface Rear Camera' ;;
  *) echo 'Expected front or rear' >&2; exit 2 ;;
esac
for ((attempt=0; attempt<30; attempt++)); do
  [[ -w $device ]] && break
  sleep 1
done
[[ -w $device ]] || { echo "No write access to $device" >&2; exit 1; }
[[ $(cat "/sys/class/video4linux/${device##*/}/name") == "$name" ]] || exit 1
# Fixed 640x480 YUYV is a widely supported baseline. No image-quality tuning.
# The relay holds only a black placeholder while idle, opens the physical
# PipeWire source on the loopback client-usage event, and releases it on idle.
# Backend source names cannot match the loopback nodes, avoiding feedback.
exec /usr/local/libexec/surface11-camera/v4l2-relayd \
  -i "pipewiresrc target-object=$node do-timestamp=true ! video/x-raw,width=640,height=480 ! videoconvert ! videorate ! video/x-raw,format=YUY2,width=640,height=480,framerate=30/1" \
  -o "appsrc name=appsrc caps=video/x-raw,format=YUY2,width=640,height=480,framerate=30/1 ! queue max-size-buffers=3 leaky=downstream ! v4l2sink name=v4l2sink device=$device sync=false" \
  -s 'videotestsrc is-live=true pattern=black ! video/x-raw,format=YUY2,width=640,height=480,framerate=30/1'
