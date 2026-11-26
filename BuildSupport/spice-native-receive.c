/* Independent candidate-only native receive probe. No GUI or guest access. */
#include <spice-client.h>
#include <spice/protocol.h>
#include <spice/enums.h>
#include <spice/vd_agent.h>
#include <glib.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <stddef.h>

static GMainLoop *loop;
static GByteArray *ca;
static const char *port;
static gboolean closing;
static guint opened;
static SpiceChannelEvent terminal;
static int result = 1;
static gboolean expect_io;

static void on_event(SpiceChannel *channel, SpiceChannelEvent event, gpointer unused)
{
    (void)unused;
    if (closing || !SPICE_IS_MAIN_CHANNEL(channel)) return;
    if (event == SPICE_CHANNEL_OPENED) {
        ++opened;
    } else if (event == SPICE_CHANNEL_ERROR_IO || event == SPICE_CHANNEL_CLOSED ||
               event == SPICE_CHANNEL_ERROR_CONNECT || event == SPICE_CHANNEL_ERROR_TLS ||
               event == SPICE_CHANNEL_ERROR_AUTH || event == SPICE_CHANNEL_ERROR_LINK) {
        if (!terminal) terminal = event;
    }
}

static void on_new(SpiceSession *session, SpiceChannel *channel, gpointer unused)
{
    (void)session;
    (void)unused;
    g_signal_connect(channel, "channel-event", G_CALLBACK(on_event), NULL);
}

static gboolean tick(gpointer unused)
{
    (void)unused;
    if (!terminal) return G_SOURCE_CONTINUE;
    printf("MRV_NATIVE_WIRE_STATE opened=%u event=%d\n", opened, terminal);
    if (opened == 1 && (!expect_io || terminal == SPICE_CHANNEL_ERROR_IO)) result = 0;
    g_main_loop_quit(loop);
    return G_SOURCE_REMOVE;
}

static gboolean timeout(gpointer unused)
{
    (void)unused;
    g_main_loop_quit(loop);
    return G_SOURCE_REMOVE;
}

static void *worker(void *unused)
{
    (void)unused;
    GMainContext *ctx = g_main_context_default();
    if (!g_main_context_acquire(ctx)) return NULL;
    g_main_context_push_thread_default(ctx);
    loop = g_main_loop_new(ctx, FALSE);
    SpiceSession *session = spice_session_new();
    char *secure[] = {"all", NULL};
    g_object_set(session, "host", "127.0.0.1", "port", NULL,
                 "tls-port", port, "password", "mrv-ci-synthetic-ticket",
                 "cert-subject", "CN=mrv-ci.test", "ca", ca,
                 "secure-channels", secure, "verify", SPICE_SESSION_VERIFY_SUBJECT,
                 "proxy", NULL, "pubkey", NULL, "enable-audio", FALSE,
                 "enable-usbredir", FALSE, NULL);
    g_signal_connect(session, "channel-new", G_CALLBACK(on_new), NULL);
    guint poll = g_timeout_add(20, tick, NULL);
    guint deadline = g_timeout_add_seconds(12, timeout, NULL);
    if (spice_session_connect(session)) g_main_loop_run(loop);
    if (g_main_context_find_source_by_id(ctx, poll)) g_source_remove(poll);
    if (g_main_context_find_source_by_id(ctx, deadline)) g_source_remove(deadline);
    closing = TRUE;
    spice_session_disconnect(session);
    g_timeout_add(500, timeout, NULL);
    g_main_loop_run(loop);
    g_object_unref(session);
    g_main_loop_unref(loop);
    g_main_context_pop_thread_default(ctx);
    g_main_context_release(ctx);
    return NULL;
}

int main(int argc, char **argv)
{
    if (argc == 2 && g_strcmp0(argv[1], "--agent-layout") == 0) {
        printf("%u %zu %zu %zu %zu %u\n", SPICE_MSG_MAIN_AGENT_DATA,
               sizeof(VDAgentMessage), offsetof(VDAgentMessage, size),
               offsetof(SpiceMiniDataHeader, type), sizeof(SpiceMiniDataHeader),
               SPICE_MSG_PING);
        return 0;
    }
    if (argc == 2 && g_strcmp0(argv[1], "--layout") == 0) {
        /* Derive offsets and negotiated flags from actual installed headers. */
        printf("%zu %zu %zu %zu %zu %zu %zu %zu %zu %u %u\n",
               sizeof(SpiceLinkHeader), offsetof(SpiceLinkMess, num_common_caps),
               offsetof(SpiceLinkMess, caps_offset), offsetof(SpiceLinkReply, num_common_caps),
               offsetof(SpiceLinkReply, caps_offset), sizeof(SpiceMiniDataHeader),
               offsetof(SpiceMiniDataHeader, size), sizeof(SpiceDataHeader),
               offsetof(SpiceDataHeader, size), SPICE_COMMON_CAP_MINI_HEADER,
               SPICE_COMMON_CAP_PROTOCOL_AUTH_SELECTION);
        return 0;
    }
    if (argc != 4) return 2;
    gchar *bytes = NULL;
    gsize length = 0;
    if (!g_file_get_contents(argv[1], &bytes, &length, NULL) || !length || length > 512 * 1024) {
        g_free(bytes);
        return 2;
    }
    ca = g_byte_array_new();
    g_byte_array_append(ca, (const guint8 *)bytes, (guint)length);
    g_free(bytes);
    char *end = NULL;
    long n = strtol(argv[2], &end, 10);
    if (!end || *end || n < 1 || n > 65535) return 2;
    port = argv[2];
    if (g_strcmp0(argv[3], "reject") == 0) expect_io = TRUE;
    else if (g_strcmp0(argv[3], "control") != 0) return 2;
    pthread_t thread;
    if (pthread_create(&thread, NULL, worker, NULL)) return 2;
    pthread_join(thread, NULL);
    g_byte_array_unref(ca);
    if (!result) puts("MRV_NATIVE_WIRE_TERMINAL_OK");
    return result;
}
