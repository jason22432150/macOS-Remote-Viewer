/* Decode a bounded deterministic fixture using the actual bundled plugins. */
#include <gst/gst.h>
#include <gst/app/gstappsrc.h>
#include <gst/app/gstappsink.h>
#include <gst/video/video.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

#define MAX_INPUT (32 * 1024 * 1024)

static gint bounded_int(const char *s, gint max) {
    char *end = NULL;
    long value = strtol(s, &end, 10);
    return (end && end != s && !*end && value > 0 && value <= max) ? (gint)value : 0;
}
static long long cpu_us(struct timeval t) {
    return (long long)t.tv_sec * 1000000 + t.tv_usec;
}

static guint32 le32(const guint8 *p) {
    return (guint32)p[0] | ((guint32)p[1]<<8) | ((guint32)p[2]<<16) | ((guint32)p[3]<<24);
}
static gboolean push(GstAppSrc *src, const guint8 *data, gsize size, guint index, gboolean timed) {
    GstBuffer *buf = gst_buffer_new_allocate(NULL, size, NULL);
    if (!buf || gst_buffer_fill(buf, 0, data, size) != size) {
        if (buf) gst_buffer_unref(buf);
        return FALSE;
    }
    if (timed) {
        GST_BUFFER_PTS(buf) = index * GST_SECOND / 10;
        GST_BUFFER_DURATION(buf) = GST_SECOND / 10;
    }
    return gst_app_src_push_buffer(src, buf) == GST_FLOW_OK;
}
int main(int argc, char **argv) {
    if (argc != 5 && argc != 9) return 2;
    gint width_expected = argc == 9 ? bounded_int(argv[5], 3840) : 64;
    gint height_expected = argc == 9 ? bounded_int(argv[6], 2160) : 48;
    guint frames_expected = argc == 9 ? bounded_int(argv[7], 60) : 6;
    gboolean split = argc == 9 && !strcmp(argv[8], "split");
    if (!width_expected || !height_expected || !frames_expected ||
        width_expected % 4 || height_expected % 2 || (argc == 9 && !split)) return 2;
    struct stat input_stat;
    if (stat(argv[1], &input_stat) || !S_ISREG(input_stat.st_mode) ||
        input_stat.st_size <= 0 || input_stat.st_size > MAX_INPUT) return 2;
    gst_init(NULL, NULL);
    gchar *data = NULL;
    gsize len = 0;
    if (!g_file_get_contents(argv[1], &data, &len, NULL) || !len || len > MAX_INPUT) return 2;
    GstElement *pipe = gst_pipeline_new("probe");
    GstElement *src = gst_element_factory_make("appsrc", "src");
    GstElement *parser = strcmp(argv[3], "-") ? gst_element_factory_make(argv[3], "parser") : NULL;
    GstElement *decoder = gst_element_factory_make(argv[4], "decoder");
    GstElement *convert = gst_element_factory_make("videoconvert", "convert");
    GstElement *sink = gst_element_factory_make("appsink", "sink");
    if (!pipe || !src || (strcmp(argv[3], "-") && !parser) || !decoder || !convert || !sink) return 3;
    GstCaps *caps = gst_caps_from_string(argv[2]);
    GstCaps *out = gst_caps_new_simple("video/x-raw", "format", G_TYPE_STRING, "RGB",
                                       "width", G_TYPE_INT, width_expected,
                                       "height", G_TYPE_INT, height_expected, NULL);
    if (!caps || !out) return 3;
    g_object_set(src, "caps", caps, "format", GST_FORMAT_TIME, NULL);
    g_object_set(sink, "caps", out, "sync", FALSE, "max-buffers", 12u, NULL);
    gst_caps_unref(caps);
    gst_caps_unref(out);
    gst_bin_add_many(GST_BIN(pipe), src, decoder, convert, sink, NULL);
    if (parser) gst_bin_add(GST_BIN(pipe), parser);
    gboolean linked = parser ? gst_element_link_many(src, parser, decoder, convert, sink, NULL)
                             : gst_element_link_many(src, decoder, convert, sink, NULL);
    int code = 4;
    struct rusage before, after;
    if (getrusage(RUSAGE_SELF, &before)) goto done;
    gint64 total_start = g_get_monotonic_time();
    if (!linked || gst_element_set_state(pipe, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) goto done;
    if (len >= 32 && !memcmp(data, "DKIF", 4)) {
        gsize off = 32;
        guint index = 0;
        while (off < len) {
            if (len - off < 12 || index >= frames_expected) goto done;
            guint32 n = le32((guint8 *)data + off);
            off += 12;
            if (!n || n > len - off || !push(GST_APP_SRC(src), (guint8 *)data + off, n, index++, TRUE)) goto done;
            off += n;
        }
        if (index != frames_expected) goto done;
    } else if (!push(GST_APP_SRC(src), (guint8 *)data, len, 0, FALSE)) goto done;
    if (gst_app_src_end_of_stream(GST_APP_SRC(src)) != GST_FLOW_OK) goto done;
    guint count = 0;
    gint64 start = g_get_monotonic_time();
    for (;;) {
        GstSample *sample = gst_app_sink_try_pull_sample(GST_APP_SINK(sink), GST_SECOND);
        if (!sample) {
            GstBus *bus = gst_element_get_bus(pipe);
            GstMessage *msg = gst_bus_pop_filtered(bus, GST_MESSAGE_ERROR);
            gst_object_unref(bus);
            if (msg) {
                GError *err = NULL;
                gst_message_parse_error(msg, &err, NULL);
                fprintf(stderr, "decoder pipeline error: %s\n", err ? err->message : "unknown");
                if (err) g_error_free(err);
                gst_message_unref(msg);
                goto done;
            }
            if (gst_app_sink_is_eos(GST_APP_SINK(sink))) break;
            if (g_get_monotonic_time() - start > 15000000) goto done;
            continue;
        }
        GstStructure *st = gst_caps_get_structure(gst_sample_get_caps(sample), 0);
        gint width = 0, height = 0;
        GstVideoInfo info;
        GstVideoFrame frame;
        GstBuffer *buf = gst_sample_get_buffer(sample);
        gboolean valid = gst_structure_get_int(st, "width", &width) &&
                         gst_structure_get_int(st, "height", &height) &&
                         width == width_expected && height == height_expected &&
                         g_strcmp0(gst_structure_get_string(st, "format"), "RGB") == 0 &&
                         gst_video_info_from_caps(&info, gst_sample_get_caps(sample)) &&
                         gst_video_frame_map(&frame, &info, buf, GST_MAP_READ);
        if (valid) {
            const guint8 *pixels = GST_VIDEO_FRAME_PLANE_DATA(&frame, 0);
            gint stride = GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0);
            valid = stride >= width * 3;
            for (gint y = 0; valid && y < height; ++y) {
                const guint8 *row = pixels + (gsize)y * stride;
                for (gint x = 0; x < width; ++x) {
                    const guint8 *p = row + 3 * x;
                    gboolean blue = split && x >= width / 2;
                    if (p[blue ? 2 : 0] < 180 || p[1] > 70 || p[blue ? 0 : 2] > 70) {
                        valid = FALSE;
                        break;
                    }
                }
            }
            gst_video_frame_unmap(&frame);
        }
        gst_sample_unref(sample);
        if (!valid || ++count > frames_expected) goto done;
    }
    if (count != frames_expected || getrusage(RUSAGE_SELF, &after)) goto done;
    long long elapsed = g_get_monotonic_time() - total_start;
    if (!split)
        printf("MRV_DECODE_OK frames=%u width=%d height=%d red_pixels=%u elapsed_us=%lld\n",
               count, width_expected, height_expected, count * width_expected * height_expected,
               (long long)(g_get_monotonic_time() - start));
    printf("MRV_DECODE_METRICS frames=%u width=%d height=%d validated_pixels=%llu wall_us=%lld cpu_us=%lld peak_rss_bytes=%lld\n",
           count, width_expected, height_expected,
           (unsigned long long)count * width_expected * height_expected, elapsed,
           cpu_us(after.ru_utime) + cpu_us(after.ru_stime) -
           cpu_us(before.ru_utime) - cpu_us(before.ru_stime), (long long)after.ru_maxrss);
    code = 0;
done:
    gst_element_set_state(pipe, GST_STATE_NULL);
    gst_object_unref(pipe);
    g_free(data);
    return code;
}
