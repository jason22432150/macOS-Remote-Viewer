/* Decode a bounded deterministic fixture using the actual bundled plugins. */
#include <gst/gst.h>
#include <gst/app/gstappsrc.h>
#include <gst/app/gstappsink.h>
#include <stdio.h>
#include <string.h>

#define FRAMES 6
#define W 64
#define H 48
#define MAX_INPUT (1024 * 1024)

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
    if (argc != 5) return 2; /* path, caps, parser-or-dash, decoder */
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
    GstCaps *out = gst_caps_from_string("video/x-raw,format=RGB,width=64,height=48");
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
    if (!linked || gst_element_set_state(pipe, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) goto done;
    if (len >= 32 && !memcmp(data, "DKIF", 4)) {
        gsize off = 32;
        guint index = 0;
        while (off < len) {
            if (len - off < 12 || index >= FRAMES) goto done;
            guint32 n = le32((guint8 *)data + off);
            off += 12;
            if (!n || n > len - off || !push(GST_APP_SRC(src), (guint8 *)data + off, n, index++, TRUE)) goto done;
            off += n;
        }
        if (index != FRAMES) goto done;
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
        GstMapInfo map;
        GstBuffer *buf = gst_sample_get_buffer(sample);
        gboolean valid = gst_structure_get_int(st, "width", &width) &&
                         gst_structure_get_int(st, "height", &height) &&
                         width == W && height == H &&
                         g_strcmp0(gst_structure_get_string(st, "format"), "RGB") == 0 &&
                         gst_buffer_map(buf, &map, GST_MAP_READ);
        if (valid) {
            /* RGB row width 192 is naturally aligned. Check whole frame,
               not merely decoder creation or first pixel. */
            valid = map.size == W * H * 3;
            if (valid) for (gsize i = 0; i < map.size; i += 3) {
                if (map.data[i] < 180 || map.data[i+1] > 70 || map.data[i+2] > 70) {
                    valid = FALSE;
                    break;
                }
            }
            gst_buffer_unmap(buf, &map);
        }
        gst_sample_unref(sample);
        if (!valid || ++count > FRAMES) goto done;
    }
    if (count != FRAMES) goto done;
    printf("MRV_DECODE_OK frames=%u width=%d height=%d red_pixels=%u elapsed_us=%lld\n",
           count, W, H, count * W * H, (long long)(g_get_monotonic_time() - start));
    code = 0;
done:
    gst_element_set_state(pipe, GST_STATE_NULL);
    gst_object_unref(pipe);
    g_free(data);
    return code;
}
