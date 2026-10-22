#!/usr/bin/env bash
# Managed by surface11-camera. Publish the same V4L2 frames to portal apps.
set -euo pipefail
case "${1:-}" in
  front) number=42; name='Surface Front Camera'; priority=1100 ;;
  rear) number=43; name='Surface Rear Camera'; priority=1050 ;;
  *) echo 'Expected front or rear' >&2; exit 2 ;;
esac
for ((attempt=0; attempt<120; attempt++)); do
  state=$(cat "/sys/devices/virtual/video4linux/video$number/state" 2>/dev/null || true)
  format=$(cat "/sys/devices/virtual/video4linux/video$number/format" 2>/dev/null || true)
  [[ $state == capture && $format == YUYV:640x480@* ]] && break
  sleep 0.25
done
[[ $state == capture && $format == YUYV:640x480@* ]] || {
  echo "video$number writer is not ready; refusing to publish stale output-only capabilities" >&2
  exit 1
}
[[ $(cat "/sys/class/video4linux/video$number/name") == "$name" ]] || exit 1
# The publisher copies local mmap frames into PipeWire shared-memory buffers.
# Its capture pipeline opens only while a PipeWire client is streaming.
exec /usr/local/libexec/surface11-camera/surface-camera-publisher "$1"
