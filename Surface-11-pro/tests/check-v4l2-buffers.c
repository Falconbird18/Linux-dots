/* SPDX-License-Identifier: MIT
 * Hardware regression: never dequeue unqueued buffers or overwrite held pixels.
 * Run with a managed webcam, after closing other capture clients.
 */
#include <errno.h>
#include <fcntl.h>
#include <linux/videodev2.h>
#include <poll.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>

static void die(const char *what) { perror(what); exit(1); }
static void xioctl(int fd, unsigned long request, void *arg) {
    int ret;
    do { ret = ioctl(fd, request, arg); } while (ret < 0 && errno == EINTR);
    if (ret < 0) die("camera ioctl");
}
static uint64_t hash(const unsigned char *pixels, size_t size) {
    uint64_t value = UINT64_C(14695981039346656037);
    for (size_t i = 0; i < size; i++) value = (value ^ pixels[i]) * UINT64_C(1099511628211);
    return value;
}
static long milliseconds(void) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    return now.tv_sec * 1000L + now.tv_nsec / 1000000L;
}
static void dequeue(int fd, struct v4l2_buffer *buffer) {
    long end = milliseconds() + 5000;
    while (milliseconds() < end) {
        struct pollfd wait = { .fd = fd, .events = POLLIN };
        int ready = poll(&wait, 1, (int)(end - milliseconds()));
        if (ready < 0 && errno == EINTR) continue;
        if (ready < 0) die("poll camera");
        if (!ready) break;
        if (ioctl(fd, VIDIOC_DQBUF, buffer) == 0) return;
        if (errno != EAGAIN && errno != EINTR) die("dequeue camera frame");
        /* Nonblocking DQBUF may race a producer/poll wakeup. Retry normally. */
    }
    fprintf(stderr, "FAIL: timed out waiting for a queued capture buffer\n");
    exit(1);
}
int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "Usage: %s /dev/video42-or-43\n", argv[0]); return 2; }
    for (int reopen = 0; reopen < 2; reopen++) {
        int fd = open(argv[1], O_RDWR | O_NONBLOCK | O_CLOEXEC);
        if (fd < 0) die("open camera");
        struct v4l2_format fmt = { .type = V4L2_BUF_TYPE_VIDEO_CAPTURE };
        xioctl(fd, VIDIOC_G_FMT, &fmt);
        if (fmt.fmt.pix.pixelformat != V4L2_PIX_FMT_YUYV) {
            fprintf(stderr, "Expected packed YUYV\n"); return 1;
        }
        struct v4l2_requestbuffers req = { .count = 4, .type = V4L2_BUF_TYPE_VIDEO_CAPTURE,
                                          .memory = V4L2_MEMORY_MMAP };
        xioctl(fd, VIDIOC_REQBUFS, &req);
        if (req.count < 2 || req.count > 32) { fprintf(stderr, "Invalid buffer count\n"); return 1; }
        void *pixels[32]; size_t lengths[32]; uint64_t hashes[32]; bool queued[32] = { false };
        for (unsigned i = 0; i < req.count; i++) {
            struct v4l2_buffer b = { .type = req.type, .memory = req.memory, .index = i };
            xioctl(fd, VIDIOC_QUERYBUF, &b);
            lengths[i] = b.length;
            pixels[i] = mmap(NULL, b.length, PROT_READ, MAP_SHARED, fd, b.m.offset);
            if (pixels[i] == MAP_FAILED) die("map camera buffer");
            xioctl(fd, VIDIOC_QBUF, &b); queued[i] = true;
        }
        enum v4l2_buf_type type = req.type;
        xioctl(fd, VIDIOC_STREAMON, &type);
        for (int round = 0; round < 8; round++) {
            for (unsigned n = 0; n < req.count; n++) {
                struct v4l2_buffer b = { .type = req.type, .memory = req.memory };
                dequeue(fd, &b);
                if (b.index >= req.count || !queued[b.index]) {
                    fprintf(stderr, "FAIL: driver dequeued an unqueued buffer\n"); return 1;
                }
                queued[b.index] = false;
                hashes[b.index] = hash(pixels[b.index], lengths[b.index]);
            }
            /* Hold every capture buffer while many producer frames arrive. */
            usleep(200000);
            for (unsigned i = 0; i < req.count; i++) {
                if (hash(pixels[i], lengths[i]) != hashes[i]) {
                    fprintf(stderr, "FAIL: driver overwrote pixels while held by the application\n"); return 1;
                }
            }
            for (unsigned i = 0; i < req.count; i++) {
                struct v4l2_buffer b = { .type = req.type, .memory = req.memory, .index = i };
                xioctl(fd, VIDIOC_QBUF, &b); queued[i] = true;
            }
        }
        xioctl(fd, VIDIOC_STREAMOFF, &type);
        for (unsigned i = 0; i < req.count; i++) munmap(pixels[i], lengths[i]);
        close(fd);
    }
    printf("PASS: %s: queued buffers only; held pixels unchanged under producer load; reopen works\n", argv[1]);
    return 0;
}
