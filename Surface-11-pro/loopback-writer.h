/* Surface relay output adapter. SPDX-License-Identifier: GPL-2.0-or-later
 * Included by the pinned relay source after its GStreamer headers.
 * v4l2sink's rw path does not write. Use the driver's file-I/O API directly,
 * retaining one descriptor for both output and client-usage events.
 */
#include <fcntl.h>
#include <gst/video/video-frame.h>

static int loopback_fd = -1;

static GstFlowReturn
loopback_writer_sample (GstAppSink *sink, gpointer data G_GNUC_UNUSED)
{
  GstSample *sample = gst_app_sink_pull_sample (sink);
  GstVideoInfo info;
  GstVideoFrame frame;
  const gsize row_size = 640 * 2, size = row_size * 480;
  guint8 *packed;
  ssize_t written;

  if (sample == NULL)
    return GST_FLOW_EOS;
  if (!gst_video_info_from_caps (&info, gst_sample_get_caps (sample)) ||
      GST_VIDEO_INFO_FORMAT (&info) != GST_VIDEO_FORMAT_YUY2 ||
      info.colorimetry.range != GST_VIDEO_COLOR_RANGE_16_235 ||
      info.colorimetry.matrix != GST_VIDEO_COLOR_MATRIX_BT601 ||
      info.colorimetry.transfer != GST_VIDEO_TRANSFER_BT601 ||
      info.colorimetry.primaries != GST_VIDEO_COLOR_PRIMARIES_SMPTE170M ||
      GST_VIDEO_INFO_WIDTH (&info) != 640 || GST_VIDEO_INFO_HEIGHT (&info) != 480 ||
      !gst_video_frame_map (&frame, &info, gst_sample_get_buffer (sample), GST_MAP_READ)) {
    GST_ELEMENT_ERROR (sink, STREAM, FORMAT, ("Expected a mappable 640x480 limited-range BT.601 YUY2 frame"), (NULL));
    gst_sample_unref (sample);
    return GST_FLOW_ERROR;
  }

  /* PipeWire buffers may have row padding; the V4L2 writer requires packed rows. */
  packed = g_malloc (size);
  for (guint row = 0; row < 480; row++)
    memcpy (packed + row * row_size,
            (guint8 *) GST_VIDEO_FRAME_PLANE_DATA (&frame, 0) +
            row * GST_VIDEO_FRAME_PLANE_STRIDE (&frame, 0), row_size);
  do {
    written = write (loopback_fd, packed, size);
  } while (written < 0 && errno == EINTR);
  int saved_errno = errno;
  g_free (packed);
  gst_video_frame_unmap (&frame);
  gst_sample_unref (sample);
  /* One write is one frame. Retrying a short write would create a second,
   * truncated frame, so fail and let systemd restart the relay instead. */
  if (written != (ssize_t) size) {
    GST_ELEMENT_ERROR (sink, RESOURCE, WRITE, ("Loopback frame write failed"),
                       ("wrote %zd of %zu bytes: %s", written, size,
                        written < 0 ? g_strerror (saved_errno) : "short write"));
    return GST_FLOW_ERROR;
  }
  return GST_FLOW_OK;
}

static gboolean
loopback_writer_attach (GstElement *pipeline)
{
  const gchar *device = g_getenv ("SURFACE11_LOOPBACK_DEVICE");
  struct v4l2_capability cap = { 0 };
  struct v4l2_format fmt = { .type = V4L2_BUF_TYPE_VIDEO_OUTPUT };
  struct v4l2_streamparm parm = { .type = V4L2_BUF_TYPE_VIDEO_OUTPUT };
  const char *stage = "find output sink";
  GstElement *sink = gst_bin_get_by_name (GST_BIN (pipeline), "loopback-writer");

  if (device == NULL || !GST_IS_APP_SINK (sink)) {
    g_printerr ("Direct writer needs SURFACE11_LOOPBACK_DEVICE and loopback-writer appsink\n");
    if (sink != NULL) gst_object_unref (sink);
    return FALSE;
  }
  stage = "open device";
  loopback_fd = open (device, O_RDWR | O_NONBLOCK | O_CLOEXEC);
  if (loopback_fd < 0) goto fail;
  stage = "query capabilities";
  if (ioctl (loopback_fd, VIDIOC_QUERYCAP, &cap) < 0) goto fail;
  guint32 caps = (cap.capabilities & V4L2_CAP_DEVICE_CAPS) ? cap.device_caps : cap.capabilities;
  if (strcmp ((const char *) cap.driver, "v4l2 loopback") != 0 ||
      !(caps & V4L2_CAP_VIDEO_OUTPUT) || !(caps & V4L2_CAP_READWRITE) ||
      !(caps & V4L2_CAP_EXT_PIX_FORMAT)) {
    errno = ENOTSUP;
    goto fail;
  }
  fmt.fmt.pix.width = 640;
  fmt.fmt.pix.height = 480;
  fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
  fmt.fmt.pix.field = V4L2_FIELD_NONE;
  fmt.fmt.pix.bytesperline = 640 * 2;
  fmt.fmt.pix.sizeimage = 640 * 480 * 2;
  fmt.fmt.pix.colorspace = V4L2_COLORSPACE_SMPTE170M;
  /* Without this marker v4l_sanitize_format() clears the extended fields
   * before the driver sees them, making our colour validation fail. */
  fmt.fmt.pix.priv = V4L2_PIX_FMT_PRIV_MAGIC;
  fmt.fmt.pix.ycbcr_enc = V4L2_YCBCR_ENC_601;
  fmt.fmt.pix.quantization = V4L2_QUANTIZATION_LIM_RANGE;
  fmt.fmt.pix.xfer_func = V4L2_XFER_FUNC_709;
  stage = "set pixel format";
  if (ioctl (loopback_fd, VIDIOC_S_FMT, &fmt) < 0) goto fail;
  if (fmt.fmt.pix.width != 640 || fmt.fmt.pix.height != 480 ||
      fmt.fmt.pix.pixelformat != V4L2_PIX_FMT_YUYV ||
      fmt.fmt.pix.bytesperline != 1280 || fmt.fmt.pix.sizeimage != 614400 ||
      fmt.fmt.pix.colorspace != V4L2_COLORSPACE_SMPTE170M ||
      fmt.fmt.pix.ycbcr_enc != V4L2_YCBCR_ENC_601 ||
      fmt.fmt.pix.quantization != V4L2_QUANTIZATION_LIM_RANGE ||
      fmt.fmt.pix.xfer_func != V4L2_XFER_FUNC_709) {
    g_printerr ("Loopback returned %ux%u stride=%u size=%u colour=%u encoding=%u range=%u transfer=%u\n",
                fmt.fmt.pix.width, fmt.fmt.pix.height, fmt.fmt.pix.bytesperline,
                fmt.fmt.pix.sizeimage, fmt.fmt.pix.colorspace, fmt.fmt.pix.ycbcr_enc,
                fmt.fmt.pix.quantization, fmt.fmt.pix.xfer_func);
    stage = "validate returned pixel format (close camera apps if the old format is held open)";
    errno = EINVAL;
    goto fail;
  }
  parm.parm.output.timeperframe.numerator = 1;
  parm.parm.output.timeperframe.denominator = 30;
  stage = "set frame rate";
  if (ioctl (loopback_fd, VIDIOC_S_PARM, &parm) < 0) goto fail;
  g_signal_connect (sink, "new-sample", G_CALLBACK (loopback_writer_sample), NULL);
  gst_object_unref (sink);
  return TRUE;

fail:
  g_printerr ("Cannot configure loopback writer %s at %s: %s\n", device, stage, g_strerror (errno));
  if (loopback_fd >= 0) close (loopback_fd);
  loopback_fd = -1;
  gst_object_unref (sink);
  return FALSE;
}
