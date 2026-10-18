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
      GST_VIDEO_INFO_WIDTH (&info) != 640 || GST_VIDEO_INFO_HEIGHT (&info) != 480 ||
      !gst_video_frame_map (&frame, &info, gst_sample_get_buffer (sample), GST_MAP_READ)) {
    GST_ELEMENT_ERROR (sink, STREAM, FORMAT, ("Expected a mappable 640x480 YUY2 frame"), (NULL));
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
  GstElement *sink = gst_bin_get_by_name (GST_BIN (pipeline), "loopback-writer");

  if (device == NULL || !GST_IS_APP_SINK (sink)) {
    g_printerr ("Direct writer needs SURFACE11_LOOPBACK_DEVICE and loopback-writer appsink\n");
    if (sink != NULL) gst_object_unref (sink);
    return FALSE;
  }
  loopback_fd = open (device, O_RDWR | O_NONBLOCK | O_CLOEXEC);
  if (loopback_fd < 0) goto fail;
  if (ioctl (loopback_fd, VIDIOC_QUERYCAP, &cap) < 0) goto fail;
  guint32 caps = (cap.capabilities & V4L2_CAP_DEVICE_CAPS) ? cap.device_caps : cap.capabilities;
  if (strcmp ((const char *) cap.driver, "v4l2 loopback") != 0 ||
      !(caps & V4L2_CAP_VIDEO_OUTPUT) || !(caps & V4L2_CAP_READWRITE)) {
    errno = ENOTSUP;
    goto fail;
  }
  fmt.fmt.pix.width = 640;
  fmt.fmt.pix.height = 480;
  fmt.fmt.pix.pixelformat = V4L2_PIX_FMT_YUYV;
  fmt.fmt.pix.field = V4L2_FIELD_NONE;
  fmt.fmt.pix.bytesperline = 640 * 2;
  fmt.fmt.pix.sizeimage = 640 * 480 * 2;
  fmt.fmt.pix.colorspace = V4L2_COLORSPACE_SRGB;
  if (ioctl (loopback_fd, VIDIOC_S_FMT, &fmt) < 0) goto fail;
  if (fmt.fmt.pix.width != 640 || fmt.fmt.pix.height != 480 ||
      fmt.fmt.pix.pixelformat != V4L2_PIX_FMT_YUYV ||
      fmt.fmt.pix.bytesperline != 1280 || fmt.fmt.pix.sizeimage != 614400) {
    errno = EINVAL;
    goto fail;
  }
  parm.parm.output.timeperframe.numerator = 1;
  parm.parm.output.timeperframe.denominator = 30;
  if (ioctl (loopback_fd, VIDIOC_S_PARM, &parm) < 0) goto fail;
  g_signal_connect (sink, "new-sample", G_CALLBACK (loopback_writer_sample), NULL);
  gst_object_unref (sink);
  return TRUE;

fail:
  g_printerr ("Cannot configure loopback writer %s: %s\n", device, g_strerror (errno));
  if (loopback_fd >= 0) close (loopback_fd);
  loopback_fd = -1;
  gst_object_unref (sink);
  return FALSE;
}
