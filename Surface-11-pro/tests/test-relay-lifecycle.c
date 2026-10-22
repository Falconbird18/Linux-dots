/* Test the actual adapted relay with synthetic input; no camera or loopback. */
#include <assert.h>
#define main original_relay_main
#include RELAY_SOURCE
#undef main
static void destroyed(gpointer data, GObject *object) { (void)object; *(gboolean *)data = TRUE; }
int main(int argc, char **argv) {
  gst_init(&argc, &argv);
  loop = g_main_loop_new(NULL, FALSE);
  output_pipeline = gst_parse_launch("appsrc name=appsrc caps=video/x-raw,format=YUY2,width=640,height=480,framerate=30/1,colorimetry=bt601 ! fakesink", NULL);
  opt_input = "videotestsrc is-live=true ! video/x-raw,format=YUY2,width=640,height=480,framerate=30/1,colorimetry=bt601 ! identity";
  for (int n = 0; n < 4; n++) {
    GstElement *input = input_pipeline_get();
    assert(input && input_bus_watch_id != 0);
    gboolean gone = FALSE;
    g_object_weak_ref(G_OBJECT(input), destroyed, &gone);
    input_pipeline_disable();
    assert(gone && input_pipeline == NULL && input_bus_watch_id == 0);
  }
  GstElement *input = input_pipeline_get();
  GError *error = g_error_new_literal(GST_STREAM_ERROR, GST_STREAM_ERROR_FAILED, "Synthetic native capture failure");
  GstMessage *message = gst_message_new_error(GST_OBJECT(input), error, "test");
  g_error_free(error);
  backend_pipeline_bus_call(NULL, message, input);
  assert(backend_failed);
  gst_message_unref(message);
  input_pipeline_disable();
  gst_object_unref(output_pipeline); g_main_loop_unref(loop);
  g_print("PASS: native inputs/watches released across reopen; backend errors mark relay failure\n");
  return 0;
}
