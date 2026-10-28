/* Exercise actual GstSamples with a simulated V4L2 file-I/O endpoint. */
#include <errno.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/videodev2.h>
#include <fcntl.h>
#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include <gst/video/video.h>
#include <stdarg.h>
#include <stddef.h>

static GstSample *next_sample;
static int writes, closes, opens, write_mode, ioctl_mode;
static struct v4l2_format stored_format;
static GstSample *fake_pull (GstAppSink *sink) { return gst_sample_ref (next_sample); }
static int fake_open (const char *path, int flags, ...) {
  g_assert_cmpstr (path, ==, "/dev/test-loopback");
  g_assert_true ((flags & (O_RDWR | O_NONBLOCK | O_CLOEXEC)) == (O_RDWR | O_NONBLOCK | O_CLOEXEC));
  opens++;
  return 77;
}
static int fake_close (int fd) { g_assert_cmpint (fd, ==, 77); closes++; return 0; }
static int fake_ioctl (int fd, unsigned long request, ...) {
  va_list args;
  va_start (args, request);
  void *arg = va_arg (args, void *);
  va_end (args);
  g_assert_cmpint (fd, ==, 77);
  if (ioctl_mode == 1) { errno = EIO; return -1; }
  if (request == VIDIOC_QUERYCAP) {
    struct v4l2_capability *cap = arg;
    strcpy ((char *) cap->driver, "v4l2 loopback");
    cap->capabilities = V4L2_CAP_DEVICE_CAPS;
    cap->device_caps = V4L2_CAP_VIDEO_OUTPUT | V4L2_CAP_READWRITE | V4L2_CAP_EXT_PIX_FORMAT;
    if (ioctl_mode == 5) cap->device_caps &= ~V4L2_CAP_EXT_PIX_FORMAT;
    if (ioctl_mode == 3) strcpy ((char *) cap->driver, "unrelated");
  } else if (request == VIDIOC_S_FMT) {
    struct v4l2_format *fmt = arg;
    /* Model the kernel's v4l_sanitize_format(): extended colour fields are
     * discarded unless applications mark them as initialized. The previous
     * fake ioctl skipped this step and let the startup regression pass. */
    if (fmt->fmt.pix.priv != V4L2_PIX_FMT_PRIV_MAGIC) {
      fmt->fmt.pix.priv = V4L2_PIX_FMT_PRIV_MAGIC;
      size_t offset = offsetof (struct v4l2_pix_format, priv) + sizeof (fmt->fmt.pix.priv);
      memset ((guint8 *) &fmt->fmt.pix + offset, 0, sizeof (fmt->fmt.pix) - offset);
    }
    g_assert_cmpint (fmt->type, ==, V4L2_BUF_TYPE_VIDEO_OUTPUT);
    g_assert_cmpint (fmt->fmt.pix.pixelformat, ==, V4L2_PIX_FMT_YUYV);
    g_assert_cmpint (fmt->fmt.pix.colorspace, ==, V4L2_COLORSPACE_REC709);
    g_assert_cmpint (fmt->fmt.pix.ycbcr_enc, ==, V4L2_YCBCR_ENC_709);
    g_assert_cmpint (fmt->fmt.pix.quantization, ==, V4L2_QUANTIZATION_LIM_RANGE);
    g_assert_cmpint (fmt->fmt.pix.xfer_func, ==, V4L2_XFER_FUNC_709);
    if (ioctl_mode == 4) fmt->fmt.pix.quantization = V4L2_QUANTIZATION_FULL_RANGE;
    if (ioctl_mode == 2) fmt->fmt.pix.width = 320;
    stored_format = *fmt;
    if (ioctl_mode == 6) {
      stored_format.fmt.pix.colorspace = V4L2_COLORSPACE_SMPTE170M;
      stored_format.fmt.pix.ycbcr_enc = V4L2_YCBCR_ENC_601;
    }
  } else if (request == VIDIOC_G_FMT) {
    *(struct v4l2_format *)arg = stored_format;
  } else {
    g_assert_cmpuint (request, ==, VIDIOC_S_PARM);
    struct v4l2_streamparm *parm = arg;
    g_assert_cmpint (parm->parm.output.timeperframe.denominator, ==, 30);
  }
  return 0;
}
static ssize_t fake_write (int fd, const void *buf, size_t size) {
  g_assert_cmpint (fd, ==, 77);
  g_assert_cmpuint (size, ==, 1843200);
  writes++;
  if (write_mode == 1 && writes == 1) { errno = EINTR; return -1; }
  if (write_mode == 2) return size - 1;
  if (write_mode == 3) { errno = EIO; return -1; }
  for (guint row = 0; row < 720; row++)
    for (guint col = 0; col < 2560; col++)
      g_assert_cmpuint (((const guint8 *) buf)[row * 2560 + col], ==, row % 251);
  return size;
}
#define open fake_open
#define close fake_close
#define ioctl fake_ioctl
#define write fake_write
#define gst_app_sink_pull_sample fake_pull
#include "../camera/loopback-writer.h"
#undef close

int main (int argc, char **argv) {
  gst_init (&argc, &argv);
  struct loopback_writer writer = { .fd = -1 };
  GstElement *pipeline = gst_parse_launch ("appsrc ! appsink name=loopback-writer", NULL);
  GstAppSink *sink = GST_APP_SINK (gst_bin_get_by_name (GST_BIN (pipeline), "loopback-writer"));
  g_assert_false (loopback_writer_attach (pipeline, &writer, NULL));
  g_assert_cmpint (opens, ==, 0);
  for (ioctl_mode = 1; ioctl_mode <= 6; ioctl_mode++) {
    g_assert_false (loopback_writer_attach (pipeline, &writer, "/dev/test-loopback"));
    g_assert_cmpint (writer.fd, ==, -1);
    g_assert_cmpint (closes, ==, ioctl_mode);
  }
  ioctl_mode = 0;
  g_assert_true (loopback_writer_attach (pipeline, &writer, "/dev/test-loopback"));

  GstCaps *caps = gst_caps_from_string ("video/x-raw,format=YUY2,width=1280,height=720,framerate=30/1,colorimetry=bt709");
  /* Verify both packed frames and frames with eight padding bytes per row. */
  for (gint stride = 2560; stride <= 2568; stride += 8) {
    GstBuffer *buffer = gst_buffer_new_allocate (NULL, stride * 720, NULL);
    GstMapInfo map;
    gst_buffer_map (buffer, &map, GST_MAP_WRITE);
    memset (map.data, 0xff, map.size);
    for (guint row = 0; row < 720; row++) memset (map.data + row * stride, row % 251, 2560);
    gst_buffer_unmap (buffer, &map);
    gsize offsets[GST_VIDEO_MAX_PLANES] = { 0 };
    gint strides[GST_VIDEO_MAX_PLANES] = { stride };
    gst_buffer_add_video_meta_full (buffer, GST_VIDEO_FRAME_FLAG_NONE, GST_VIDEO_FORMAT_YUY2,
                                   1280, 720, 1, offsets, strides);
    next_sample = gst_sample_new (buffer, caps, NULL, NULL);
    for (write_mode = 0; write_mode <= 3; write_mode++) {
      writes = 0;
      GstFlowReturn result = loopback_writer_sample (sink, &writer);
      g_assert_cmpint (result, ==, write_mode >= 2 ? GST_FLOW_ERROR : GST_FLOW_OK);
      g_assert_cmpint (writes, ==, write_mode == 1 ? 2 : 1);
    }
    gst_sample_unref (next_sample);
    gst_buffer_unref (buffer);
  }
  GstCaps *wrong_color = gst_caps_from_string ("video/x-raw,format=YUY2,width=1280,height=720,framerate=30/1,colorimetry=bt601");
  GstBuffer *color_buffer = gst_buffer_new_allocate (NULL, 1280 * 720 * 2, NULL);
  next_sample = gst_sample_new (color_buffer, wrong_color, NULL, NULL);
  writes = 0;
  g_assert_cmpint (loopback_writer_sample (sink, &writer), ==, GST_FLOW_ERROR);
  g_assert_cmpint (writes, ==, 0);
  gst_sample_unref (next_sample);
  gst_buffer_unref (color_buffer);
  gst_caps_unref (wrong_color);
  GstCaps *bad_caps = gst_caps_from_string ("video/x-raw,format=RGB,width=1280,height=720,framerate=30/1,colorimetry=bt709");
  GstBuffer *buffer = gst_buffer_new_allocate (NULL, 1280 * 720 * 3, NULL);
  next_sample = gst_sample_new (buffer, bad_caps, NULL, NULL);
  writes = 0;
  g_assert_cmpint (loopback_writer_sample (sink, &writer), ==, GST_FLOW_ERROR);
  g_assert_cmpint (writes, ==, 0);
  gst_sample_unref (next_sample);
  gst_buffer_unref (buffer);
  gst_caps_unref (bad_caps);
  gst_caps_unref (caps);
  fake_close (writer.fd);
  gst_object_unref (sink);
  gst_object_unref (pipeline);
  g_print ("PASS: configuration, packed/padded frames, interrupted/short/failed writes, invalid caps\n");
  return 0;
}
