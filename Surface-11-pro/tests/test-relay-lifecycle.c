/* Exercise the maintained relay with synthetic input; no camera or loopback. */
#include <assert.h>
#include <fcntl.h>
#define main original_relay_main
#include "../camera/surface-camera-relay.c"
#undef main
int main(int argc, char **argv) {
    gst_init(&argc, &argv);
    loop = g_main_loop_new(NULL, FALSE);
    struct camera camera = { .name = "test", .writer.fd = open("/dev/null", O_WRONLY) };
    assert(camera.writer.fd >= 0);
    camera.pipeline = gst_parse_launch("videotestsrc is-live=true ! fakesink", NULL);
    assert(camera.pipeline);
    for (int n = 0; n < 4; n++) {
        set_demand(&camera, TRUE);
        assert(camera.active);
        set_demand(&camera, FALSE);
        GstState state;
        gst_element_get_state(camera.pipeline, &state, NULL, GST_SECOND);
        assert(!camera.active && state == GST_STATE_NULL);
    }
    GError *error = g_error_new_literal(GST_STREAM_ERROR, GST_STREAM_ERROR_FAILED, "Synthetic capture failure");
    GstMessage *message = gst_message_new_error(GST_OBJECT(camera.pipeline), error, "test");
    g_error_free(error);
    bus_message(NULL, message, &camera);
    assert(result == 1);
    gst_message_unref(message);
    gst_object_unref(camera.pipeline);
    close(camera.writer.fd);
    g_main_loop_unref(loop);
    g_print("PASS: maintained relay stops capture across reopen and reports backend failures\n");
    return 0;
}
