/* Exercise the maintained relay with synthetic input; no camera or loopback. */
#include <assert.h>
#include <fcntl.h>
#include <stdarg.h>
#define ioctl test_ioctl
#define main original_relay_main
#include "../camera/surface-camera-relay.c"
#undef main
#undef ioctl
static int pending_events, empty_errno;
int test_ioctl(int fd, unsigned long request, ...) {
    (void)fd;
    assert(request == VIDIOC_DQEVENT);
    if (!pending_events) { errno = empty_errno; return -1; }
    va_list args;
    va_start(args, request);
    struct v4l2_event *event = va_arg(args, struct v4l2_event *);
    va_end(args);
    memset(event, 0, sizeof(*event));
    event->type = CLIENT_USAGE_EVENT;
    guint32 count = --pending_events % 2;
    memcpy(&event->u, &count, sizeof(count));
    return 0;
}
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
    for (int n = 0; n < 3; n++) {
        empty_errno = (int[]){ ENOENT, EAGAIN, EINTR }[n];
        /* A batch ending in zero demand must use the latest event, and an
         * empty queue must not kill the service after handling it. */
        pending_events = 2;
        set_demand(&camera, TRUE);
        usage_event(camera.writer.fd, G_IO_PRI, &camera);
        assert(!camera.active && result == 0);
    }
    empty_errno = EIO;
    usage_event(camera.writer.fd, G_IO_PRI, &camera);
    assert(result == 1);
    result = 0;
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
