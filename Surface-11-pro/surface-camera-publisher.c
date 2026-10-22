/* SPDX-License-Identifier: MIT
 * Publish packed loopback pixels through mapped PipeWire MemFd buffers.
 * Read loopback frames through file I/O; never export its mmap/DMA buffers.
 * Open the loopback only while PipeWire consumers are streaming.
 */
#include <errno.h>
#include <signal.h>
#include <string.h>
#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>
#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include <gst/video/video.h>
#define WIDTH 640
#define HEIGHT 480
#define STRIDE (WIDTH * 2)
#define FRAME_SIZE (STRIDE * HEIGHT)
struct publisher {
  struct pw_main_loop *loop;
  struct pw_stream *stream;
  struct spa_source *timer;
  GstElement *input;
  GstAppSink *sink;
  unsigned char *pixels;
  uint64_t sequence;
  int result;
  bool active;
  bool pending;
  gint64 start_after;
  char *description;
};
static void stop_input(struct publisher *p) {
  p->pending = false;
  if (!p->input) return;
  gst_element_set_state(p->input, GST_STATE_NULL);
  gst_element_get_state(p->input, NULL, NULL, 2 * GST_SECOND);
  if (p->sink) gst_object_unref(p->sink);
  p->sink = NULL;
  gst_object_unref(p->input); p->input = NULL;
  p->active = false;
  fprintf(stderr, "Surface publisher: capture idle\n");
}
static void fail(struct publisher *p, const char *message) {
  fprintf(stderr, "Surface publisher: %s\n", message);
  p->result = 1;
  pw_main_loop_quit(p->loop);
}
static bool start_input(struct publisher *p) {
  GError *error = NULL;
  p->pending = false;
  p->input = gst_parse_launch(p->description, &error);
  if (error) {
    fail(p, error->message); g_clear_error(&error); return false;
  }
  p->sink = GST_APP_SINK(gst_bin_get_by_name(GST_BIN(p->input), "frames"));
  if (gst_element_set_state(p->input, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
    fail(p, "Cannot open shared V4L2 capture"); return false;
  }
  p->active = true;
  fprintf(stderr, "Surface publisher: capture active\n");
  return true;
}
static void process(void *userdata) {
  struct publisher *p = userdata;
  GstSample *sample = p->sink ? gst_app_sink_try_pull_sample(p->sink, 0) : NULL;
  if (sample) {
    GstVideoInfo info;
    GstVideoFrame frame;
    if (!gst_video_info_from_caps(&info, gst_sample_get_caps(sample)) ||
        GST_VIDEO_INFO_FORMAT(&info) != GST_VIDEO_FORMAT_YUY2 ||
        GST_VIDEO_INFO_WIDTH(&info) != WIDTH || GST_VIDEO_INFO_HEIGHT(&info) != HEIGHT ||
        !gst_video_frame_map(&frame, &info, gst_sample_get_buffer(sample), GST_MAP_READ)) {
      gst_sample_unref(sample);
      fail(p, "Invalid loopback frame layout");
      return;
    }
    if (GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0) < STRIDE) {
      gst_video_frame_unmap(&frame); gst_sample_unref(sample);
      fail(p, "Loopback row is shorter than packed YUYV"); return;
    }
    for (unsigned row = 0; row < HEIGHT; row++)
      memcpy(p->pixels + row * STRIDE,
             (char *) GST_VIDEO_FRAME_PLANE_DATA(&frame, 0) + row * GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0), STRIDE);
    gst_video_frame_unmap(&frame);
    gst_sample_unref(sample);
  }
  struct pw_buffer *buffer = pw_stream_dequeue_buffer(p->stream);
  if (!buffer) return;
  struct spa_buffer *spa = buffer->buffer;
  if (spa->n_datas != 1 || !spa->datas[0].data || spa->datas[0].maxsize < FRAME_SIZE) {
    pw_stream_queue_buffer(p->stream, buffer);
    fail(p, "Expected one mapped shared-memory output buffer");
    return;
  }
  memcpy(spa->datas[0].data, p->pixels, FRAME_SIZE);
  spa->datas[0].chunk->offset = 0;
  spa->datas[0].chunk->size = FRAME_SIZE;
  spa->datas[0].chunk->stride = STRIDE;
  struct spa_meta_header *header = spa_buffer_find_meta_data(spa, SPA_META_Header, sizeof(*header));
  if (header) {
    header->flags = 0; header->pts = -1; header->dts_offset = 0; header->seq = p->sequence++;
  }
  pw_stream_queue_buffer(p->stream, buffer);
}
static void tick(void *userdata, uint64_t expirations) {
  struct publisher *p = userdata;
  (void) expirations;
  if (p->pending && g_get_monotonic_time() >= p->start_after && !start_input(p)) return;
  GstMessage *msg = NULL;
  if (p->input) {
    GstBus *bus = gst_element_get_bus(p->input);
    msg = gst_bus_pop_filtered(bus, GST_MESSAGE_ERROR | GST_MESSAGE_EOS);
    gst_object_unref(bus);
  }
  if (msg) {
    if (GST_MESSAGE_TYPE(msg) == GST_MESSAGE_ERROR) {
      GError *error = NULL; gchar *debug = NULL;
      gst_message_parse_error(msg, &error, &debug);
      fprintf(stderr, "Surface capture details: %s\n", debug ? debug : "none");
      fail(p, error->message);
      g_clear_error(&error); g_free(debug);
    } else fail(p, "Loopback capture ended unexpectedly");
    gst_message_unref(msg);
    return;
  }
  pw_stream_trigger_process(p->stream);
}
static void state_changed(void *userdata, enum pw_stream_state old,
                          enum pw_stream_state state, const char *error) {
  struct publisher *p = userdata;
  (void) old;
  if (state == PW_STREAM_STATE_ERROR) { fail(p, error ? error : "PipeWire error"); return; }
  if (state == PW_STREAM_STATE_PAUSED || state == PW_STREAM_STATE_UNCONNECTED) {
    pw_loop_update_timer(pw_main_loop_get_loop(p->loop), p->timer, NULL, NULL, false);
    stop_input(p);
  } else if (state == PW_STREAM_STATE_STREAMING) {
    /* Clear the previous user's last image before a fresh capture. */
    for (unsigned i = 0; i < FRAME_SIZE; i += 2) { p->pixels[i] = 16; p->pixels[i+1] = 128; }
    /* PipeWire may STREAM/PAUSE/STREAM during initial link negotiation.
     * Open capture only once that negotiation has remained stable for 150ms. */
    p->pending = true;
    p->start_after = g_get_monotonic_time() + 150000;
    struct timespec first = { .tv_nsec = 1 }, interval = { .tv_nsec = 1000000000 / 30 };
    pw_loop_update_timer(pw_main_loop_get_loop(p->loop), p->timer, &first, &interval, false);
  }
}
static void param_changed(void *userdata, uint32_t id, const struct spa_pod *param) {
  struct publisher *p = userdata;
  if (id != SPA_PARAM_Format || !param) return;
  struct spa_video_info_raw info = { 0 };
  if (spa_format_video_raw_parse(param, &info) < 0 || info.format != SPA_VIDEO_FORMAT_YUY2 ||
      info.size.width != WIDTH || info.size.height != HEIGHT) {
    fail(p, "Unsupported public format"); return;
  }
  unsigned char storage[512];
  struct spa_pod_builder b = SPA_POD_BUILDER_INIT(storage, sizeof(storage));
  const struct spa_pod *params[2];
  params[0] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamBuffers, SPA_PARAM_Buffers,
      SPA_PARAM_BUFFERS_buffers, SPA_POD_CHOICE_RANGE_Int(4, 2, 8),
      SPA_PARAM_BUFFERS_blocks, SPA_POD_Int(1),
      SPA_PARAM_BUFFERS_size, SPA_POD_Int(FRAME_SIZE),
      SPA_PARAM_BUFFERS_stride, SPA_POD_Int(STRIDE),
      SPA_PARAM_BUFFERS_dataType, SPA_POD_CHOICE_FLAGS_Int(1 << SPA_DATA_MemFd));
  params[1] = spa_pod_builder_add_object(&b, SPA_TYPE_OBJECT_ParamMeta, SPA_PARAM_Meta,
      SPA_PARAM_META_type, SPA_POD_Id(SPA_META_Header),
      SPA_PARAM_META_size, SPA_POD_Int(sizeof(struct spa_meta_header)));
  pw_stream_update_params(p->stream, params, 2);
}
static const struct pw_stream_events events = {
  PW_VERSION_STREAM_EVENTS, .state_changed = state_changed,
  .param_changed = param_changed, .process = process,
};
static void quit(void *userdata, int sig) { (void) sig; pw_main_loop_quit(((struct publisher *)userdata)->loop); }
int main(int argc, char **argv) {
  if (argc < 2 || argc > 3 || (strcmp(argv[1], "front") && strcmp(argv[1], "rear")) ||
      (argc == 3 && strcmp(argv[2], "--test-source"))) return 2;
  bool front = strcmp(argv[1], "front") == 0;
  gst_init(NULL, NULL); pw_init(NULL, NULL);
  struct publisher p = { 0 };
  p.loop = pw_main_loop_new(NULL);
  p.pixels = g_malloc0(FRAME_SIZE);
  p.description = g_strdup_printf("%s ! video/x-raw,format=YUY2,width=640,height=480,framerate=30/1,pixel-aspect-ratio=1/1,colorimetry=bt601 ! appsink name=frames max-buffers=2 drop=true sync=false enable-last-sample=false",
      argc == 3 ? "videotestsrc is-live=true pattern=ball" :
      (front ? "v4l2src device=/dev/video42 io-mode=rw" : "v4l2src device=/dev/video43 io-mode=rw"));
  struct pw_properties *props = pw_properties_new(
      PW_KEY_MEDIA_CLASS, "Video/Source", PW_KEY_MEDIA_TYPE, "Video", PW_KEY_MEDIA_ROLE, "Camera",
      PW_KEY_NODE_NAME, front ? "surface11-camera-front" : "surface11-camera-rear",
      PW_KEY_NODE_DESCRIPTION, front ? "Surface Front Camera" : "Surface Rear Camera",
      "api.v4l2.path", front ? "/dev/video42" : "/dev/video43",
      "node.driver", "true", "node.pause-on-idle", "true", "priority.session", front ? "1100" : "1050", NULL);
  p.timer = pw_loop_add_timer(pw_main_loop_get_loop(p.loop), tick, &p);
  p.stream = pw_stream_new_simple(pw_main_loop_get_loop(p.loop), "Surface shared webcam", props, &events, &p);
  struct spa_video_info_raw format = { .format = SPA_VIDEO_FORMAT_YUY2,
      .size = SPA_RECTANGLE(WIDTH, HEIGHT), .framerate = SPA_FRACTION(30, 1),
      .color_range = SPA_VIDEO_COLOR_RANGE_16_235, .color_matrix = SPA_VIDEO_COLOR_MATRIX_BT601,
      .transfer_function = SPA_VIDEO_TRANSFER_BT709, .color_primaries = SPA_VIDEO_COLOR_PRIMARIES_SMPTE170M };
  unsigned char storage[512]; struct spa_pod_builder b = SPA_POD_BUILDER_INIT(storage, sizeof(storage));
  const struct spa_pod *param = spa_format_video_raw_build(&b, SPA_PARAM_EnumFormat, &format);
  if (pw_stream_connect(p.stream, PW_DIRECTION_OUTPUT, PW_ID_ANY,
      PW_STREAM_FLAG_DRIVER | PW_STREAM_FLAG_MAP_BUFFERS, &param, 1) < 0) return 1;
  pw_loop_add_signal(pw_main_loop_get_loop(p.loop), SIGINT, quit, &p);
  pw_loop_add_signal(pw_main_loop_get_loop(p.loop), SIGTERM, quit, &p);
  pw_main_loop_run(p.loop);
  stop_input(&p); g_free(p.description);
  pw_stream_destroy(p.stream); pw_loop_destroy_source(pw_main_loop_get_loop(p.loop), p.timer);
  pw_main_loop_destroy(p.loop); g_free(p.pixels);
  return p.result;
}
