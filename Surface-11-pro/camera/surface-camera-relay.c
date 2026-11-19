/* SPDX-License-Identifier: GPL-2.0-or-later
 * One process shares libcamera's manager across both IPU7 sensors. Each camera
 * has its own loopback writer, pipeline, event subscription, and demand state.
 */
#include <errno.h>
#include <signal.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <linux/videodev2.h>
#include <glib-unix.h>
#include <gst/gst.h>
#include <gst/app/gstappsink.h>
#include "loopback-writer.h"

#define CLIENT_USAGE_EVENT (V4L2_EVENT_PRIVATE_START + 0x08E00000 + 1)
struct camera {
    const char *name;
    struct loopback_writer writer;
    GstElement *pipeline;
    guint events, bus;
    gboolean active;
};
static GMainLoop *loop;
static int result;
static void fail(const char *message) {
    g_printerr("Surface capture: %s\n", message);
    result = 1;
    g_main_loop_quit(loop);
}
static gboolean clear_image(struct camera *camera) {
    const gsize size = 1280 * 720 * 2;
    guint8 *black = g_malloc(size);
    for (gsize i = 0; i < size; i += 2) { black[i] = 16; black[i + 1] = 128; }
    ssize_t written;
    do { written = write(camera->writer.fd, black, size); } while (written < 0 && errno == EINTR);
    g_free(black);
    if (written != (ssize_t)size) { fail("Cannot write idle camera frame"); return FALSE; }
    return TRUE;
}
static void set_demand(struct camera *camera, gboolean active) {
    if (camera->active == active) return;
    if (active) {
        if (gst_element_set_state(camera->pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
            fail("Cannot start physical camera capture"); return;
        }
        camera->active = TRUE;
    } else {
        gst_element_set_state(camera->pipeline, GST_STATE_NULL);
        camera->active = FALSE;
        clear_image(camera);
    }
    g_printerr("Surface %s capture %s\n", camera->name, active ? "active" : "idle");
}
static gboolean usage_event(gint fd, GIOCondition condition, gpointer data) {
    struct camera *camera = data;
    struct v4l2_event event;
    guint32 count = 0;
    gboolean received = FALSE;
    if (condition & (G_IO_ERR | G_IO_HUP | G_IO_NVAL)) {
        fail("Loopback event descriptor closed"); return G_SOURCE_CONTINUE;
    }
    /* Apply only the newest demand after format probes/rapid STREAMON/OFF. */
    while (ioctl(fd, VIDIOC_DQEVENT, &event) == 0) {
        if (event.type == CLIENT_USAGE_EVENT) {
            memcpy(&count, &event.u, sizeof(count));
            received = TRUE;
        }
    }
    /* V4L2's nonblocking event queue returns ENOENT when drained, unlike
     * read()/DQBUF's EAGAIN. Neither means that the device disappeared. */
    if (errno != ENOENT && errno != EAGAIN && errno != EINTR) {
        g_printerr("Surface %s loopback events: %s\n", camera->name, g_strerror(errno));
        fail("Cannot read loopback client events"); return G_SOURCE_CONTINUE;
    }
    if (received) set_demand(camera, count != 0);
    return G_SOURCE_CONTINUE;
}
static gboolean bus_message(GstBus *bus, GstMessage *message, gpointer data) {
    struct camera *camera = data;
    (void)bus;
    if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR) {
        GError *error = NULL; gchar *debug = NULL;
        gst_message_parse_error(message, &error, &debug);
        g_printerr("Surface %s: %s\n", camera->name, debug ? debug : "no details");
        fail(error->message);
        g_clear_error(&error); g_free(debug);
    } else if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_EOS && camera->active) {
        fail("Physical camera capture ended unexpectedly");
    }
    return G_SOURCE_CONTINUE;
}
static gboolean quit(gpointer data) { (void)data; g_main_loop_quit(loop); return G_SOURCE_REMOVE; }
int main(int argc, char **argv) {
    if (argc != 3) { g_printerr("Expected front and rear input pipeline descriptions\n"); return 2; }
    gst_init(NULL, NULL);
    loop = g_main_loop_new(NULL, FALSE);
    struct camera cameras[2] = {
        { .name = "front", .writer.fd = -1 },
        { .name = "rear", .writer.fd = -1 },
    };
    for (unsigned i = 0; i < 2; i++) {
        struct camera *camera = &cameras[i];
        GError *error = NULL;
        gchar *description = g_strdup_printf("%s ! appsink name=loopback-writer emit-signals=true max-buffers=2 drop=true sync=false enable-last-sample=false", argv[i + 1]);
        camera->pipeline = gst_parse_launch(description, &error);
        g_free(description);
        if (error) { fail(error->message); g_clear_error(&error); goto cleanup; }
        if (!loopback_writer_attach(camera->pipeline, &camera->writer, i ? "/dev/video43" : "/dev/video42")) {
            fail("Cannot configure managed webcam output"); goto cleanup;
        }
        struct v4l2_event_subscription subscription = {
            .type = CLIENT_USAGE_EVENT, .flags = V4L2_EVENT_SUB_FL_SEND_INITIAL,
        };
        if (ioctl(camera->writer.fd, VIDIOC_SUBSCRIBE_EVENT, &subscription) < 0) {
            fail("Loopback client-usage events are unavailable"); goto cleanup;
        }
        camera->events = g_unix_fd_add(camera->writer.fd, G_IO_PRI | G_IO_ERR | G_IO_HUP,
                                        usage_event, camera);
        GstBus *bus = gst_element_get_bus(camera->pipeline);
        camera->bus = gst_bus_add_watch(bus, bus_message, camera);
        gst_object_unref(bus);
        if (!clear_image(camera)) goto cleanup;
    }
    g_unix_signal_add(SIGTERM, quit, NULL);
    g_unix_signal_add(SIGINT, quit, NULL);
    g_main_loop_run(loop);
cleanup:
    for (unsigned i = 0; i < 2; i++) {
        struct camera *camera = &cameras[i];
        if (camera->events) g_source_remove(camera->events);
        if (camera->bus) g_source_remove(camera->bus);
        if (camera->pipeline) {
            gst_element_set_state(camera->pipeline, GST_STATE_NULL);
            gst_object_unref(camera->pipeline);
        }
        if (camera->writer.fd >= 0) close(camera->writer.fd);
    }
    g_main_loop_unref(loop);
    return result;
}
