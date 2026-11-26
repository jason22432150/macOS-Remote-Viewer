/* Test-only real concurrent SpiceSession ownership probe. */
#include <spice-client.h>
#include <glib.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

enum { COUNT = 7 };
typedef struct {
    SpiceSession *session;
    const char *port;
    guint index;
    guint opened;
    SpiceChannelEvent terminal;
} Peer;

static Peer peers[COUNT];
static GMainLoop *loop;
static GByteArray *ca;
static const char *gate;
static gboolean closing;
static gboolean failed;
static int result = 1;
static gint64 deadline;

static void on_event(SpiceChannel *channel, SpiceChannelEvent event, gpointer data)
{
    Peer *peer = data;
    if (closing || !SPICE_IS_MAIN_CHANNEL(channel)) return;
    if (event == SPICE_CHANNEL_OPENED) {
        if (++peer->opened != 1) failed = TRUE;
        printf("MRV_BUDGET_OPENED peer=%u\n", peer->index);
        fflush(stdout);
    } else if (event == SPICE_CHANNEL_ERROR_IO || event == SPICE_CHANNEL_CLOSED ||
               event == SPICE_CHANNEL_ERROR_CONNECT || event == SPICE_CHANNEL_ERROR_TLS ||
               event == SPICE_CHANNEL_ERROR_AUTH || event == SPICE_CHANNEL_ERROR_LINK) {
        if (!peer->terminal) {
            peer->terminal = event;
            printf("MRV_BUDGET_TERMINAL peer=%u io=%d\n", peer->index,
                   event == SPICE_CHANNEL_ERROR_IO);
            fflush(stdout);
        }
    }
}

static void on_new(SpiceSession *session, SpiceChannel *channel, gpointer data)
{
    (void)session;
    g_signal_connect(channel, "channel-event", G_CALLBACK(on_event), data);
}

static gboolean gate_exists(const char *name, guint index)
{
    gchar *file = g_strdup_printf("%s/%s-%u", gate, name, index);
    gboolean exists = g_file_test(file, G_FILE_TEST_IS_REGULAR);
    g_free(file);
    return exists;
}

static gboolean tick(gpointer unused)
{
    (void)unused;
    if (failed || g_get_monotonic_time() >= deadline) {
        g_main_loop_quit(loop);
        return G_SOURCE_REMOVE;
    }
    for (guint i = 0; i < COUNT; ++i) {
        Peer *peer = &peers[i];
        if (peer->session || !gate_exists("start", i)) continue;
        peer->session = spice_session_new();
        char *secure[] = {"all", NULL};
        g_object_set(peer->session, "host", "127.0.0.1", "port", NULL,
                     "tls-port", peer->port, "password", "mrv-ci-synthetic-ticket",
                     "cert-subject", "CN=mrv-ci.test", "ca", ca,
                     "secure-channels", secure, "verify", SPICE_SESSION_VERIFY_SUBJECT,
                     "proxy", NULL, "pubkey", NULL, "enable-audio", FALSE,
                     "enable-usbredir", FALSE, NULL);
        g_signal_connect(peer->session, "channel-new", G_CALLBACK(on_new), peer);
        if (!spice_session_connect(peer->session)) failed = TRUE;
    }
    if (gate_exists("finish", 0)) {
        gboolean ok = !failed;
        for (guint i = 0; i < COUNT; ++i)
            ok = ok && peers[i].session && peers[i].opened == 1 && peers[i].terminal != 0;
        ok = ok && peers[5].terminal == SPICE_CHANNEL_ERROR_IO;
        result = ok ? 0 : 1;
        g_main_loop_quit(loop);
        return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}

static gboolean drain(gpointer unused)
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
    deadline = g_get_monotonic_time() + 90 * G_USEC_PER_SEC;
    g_timeout_add(20, tick, NULL);
    g_main_loop_run(loop);
    closing = TRUE;
    for (guint i = 0; i < COUNT; ++i)
        if (peers[i].session) spice_session_disconnect(peers[i].session);
    g_timeout_add(500, drain, NULL);
    g_main_loop_run(loop);
    for (guint i = 0; i < COUNT; ++i)
        g_clear_object(&peers[i].session);
    g_main_loop_unref(loop);
    g_main_context_pop_thread_default(ctx);
    g_main_context_release(ctx);
    return NULL;
}

int main(int argc, char **argv)
{
    if (argc != COUNT + 3) return 2;
    gchar *bytes = NULL;
    gsize length = 0;
    if (!g_file_get_contents(argv[1], &bytes, &length, NULL) || !length || length > 512 * 1024) {
        g_free(bytes);
        return 2;
    }
    ca = g_byte_array_new();
    g_byte_array_append(ca, (const guint8 *)bytes, (guint)length);
    g_free(bytes);
    gate = argv[2];
    for (guint i = 0; i < COUNT; ++i) {
        char *end = NULL;
        long n = strtol(argv[i + 3], &end, 10);
        if (!end || *end || n < 1 || n > 65535) return 2;
        peers[i].port = argv[i + 3];
        peers[i].index = i;
    }
    pthread_t thread;
    if (pthread_create(&thread, NULL, worker, NULL)) return 2;
    pthread_join(thread, NULL);
    g_byte_array_unref(ca);
    if (!result) puts("MRV_NATIVE_BUDGET_SESSIONS_OK");
    return result;
}
