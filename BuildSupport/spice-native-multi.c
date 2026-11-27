/* Independent, test-only probe of the exact packaged spice-client-glib.
 * No CocoaSpice, Swift, AppKit, renderer, guest agent or clipboard.
 * All SPICE operations and the default GLib loop belong to one pthread.
 */
#include <spice-client.h>
#include <glib.h>
#include <gio/gio.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { SESSION_COUNT = 4 };
typedef struct {
    SpiceSession *session;
    unsigned index;
    unsigned main_opened;
    unsigned display_opened;
} Peer;

typedef struct {
    GMainLoop *loop;
    Peer peers[SESSION_COUNT];
    gboolean closing;
    gboolean failed;
    gint64 ready_since;
    gint64 deadline;
    GByteArray *ca;
    const char *ports[SESSION_COUNT];
    int result;
} Probe;

static Probe probe;

/* The read-only SpiceChannel:socket property is documented for connection
 * details. Never read/write its stream or change any socket options here.
 * Inspect the actual kernel values instead of assuming setsockopt succeeded. */
static gboolean verify_keepalive(SpiceChannel *channel, unsigned index, int type, int id) {
    GSocket *sock = NULL;
    gint enabled = -1, idle = -1, interval = -1, count = -1;
    g_object_get(channel, "socket", &sock, NULL);
    gboolean ok = FALSE;
    if (sock) {
        GSocketFamily family = g_socket_get_family(sock);
        ok = (family == G_SOCKET_FAMILY_IPV4 || family == G_SOCKET_FAMILY_IPV6) &&
             g_socket_get_option(sock, SOL_SOCKET, SO_KEEPALIVE, &enabled, NULL) &&
             g_socket_get_option(sock, IPPROTO_TCP, TCP_KEEPALIVE, &idle, NULL) &&
             g_socket_get_option(sock, IPPROTO_TCP, TCP_KEEPINTVL, &interval, NULL) &&
             g_socket_get_option(sock, IPPROTO_TCP, TCP_KEEPCNT, &count, NULL) &&
             enabled == 1 && idle == 30 && interval == 15 && count == 3;
    }
    g_clear_object(&sock);
    printf("MRV_NATIVE_KEEPALIVE session=%u type=%d id=%d enabled=%d idle=%d interval=%d count=%d ok=%d\n",
           index, type, id, enabled, idle, interval, count, ok ? 1 : 0);
    fflush(stdout);
    return ok;
}

static void channel_event(SpiceChannel *channel, SpiceChannelEvent event, gpointer data) {
    Peer *peer = data;
    int type = 0, id = 0;
    g_object_get(channel, "channel-type", &type, "channel-id", &id, NULL);
    printf("MRV_NATIVE_CHANNEL session=%u type=%d id=%d event=%d\n",
           peer->index, type, id, event);
    fflush(stdout);
    if (probe.closing) return;
    switch (event) {
    case SPICE_CHANNEL_OPENED:
        if ((SPICE_IS_MAIN_CHANNEL(channel) || SPICE_IS_DISPLAY_CHANNEL(channel)) &&
            !verify_keepalive(channel, peer->index, type, id))
            probe.failed = TRUE;
        if (SPICE_IS_MAIN_CHANNEL(channel) && ++peer->main_opened != 1)
            probe.failed = TRUE;
        if (SPICE_IS_DISPLAY_CHANNEL(channel) && ++peer->display_opened != 1)
            probe.failed = TRUE;
        break;
    case SPICE_CHANNEL_CLOSED:
    case SPICE_CHANNEL_ERROR_CONNECT:
    case SPICE_CHANNEL_ERROR_TLS:
    case SPICE_CHANNEL_ERROR_LINK:
    case SPICE_CHANNEL_ERROR_AUTH:
    case SPICE_CHANNEL_ERROR_IO:
    case SPICE_CHANNEL_SWITCHING:
        probe.failed = TRUE;
        break;
    default:
        break;
    }
}

static void channel_new(SpiceSession *session, SpiceChannel *channel, gpointer data) {
    Peer *peer = data;
    (void)session;
    g_signal_connect(channel, "channel-event", G_CALLBACK(channel_event), peer);
    if (SPICE_IS_DISPLAY_CHANNEL(channel) || SPICE_IS_CURSOR_CHANNEL(channel) ||
        SPICE_IS_INPUTS_CHANNEL(channel)) {
        if (!spice_channel_connect(channel)) probe.failed = TRUE;
    }
}

static gboolean tick(gpointer unused) {
    (void)unused;
    gint64 now = g_get_monotonic_time();
    gboolean ready = TRUE;
    for (unsigned i = 0; i < SESSION_COUNT; ++i)
        ready = ready && probe.peers[i].main_opened == 1 && probe.peers[i].display_opened == 1;
    if (ready && !probe.ready_since) probe.ready_since = now;
    if (probe.failed || now >= probe.deadline ||
        (ready && now - probe.ready_since >= 2 * G_USEC_PER_SEC)) {
        probe.result = (!probe.failed && ready &&
                        now - probe.ready_since >= 2 * G_USEC_PER_SEC) ? 0 : 1;
        for (unsigned i = 0; i < SESSION_COUNT; ++i) {
            printf("MRV_NATIVE_STATE session=%u main=%u display=%u\n", i,
                   probe.peers[i].main_opened, probe.peers[i].display_opened);
        }
        fflush(stdout);
        g_main_loop_quit(probe.loop);
        return G_SOURCE_REMOVE;
    }
    return G_SOURCE_CONTINUE;
}

static gboolean drain_done(gpointer unused) {
    (void)unused;
    g_main_loop_quit(probe.loop);
    return G_SOURCE_REMOVE;
}

static void *run_worker(void *unused) {
    (void)unused;
    GMainContext *ctx = g_main_context_default();
    if (!g_main_context_acquire(ctx)) return NULL;
    g_main_context_push_thread_default(ctx);
    probe.loop = g_main_loop_new(ctx, FALSE);
    char *secure_channels[] = { "all", NULL };
    for (unsigned i = 0; i < SESSION_COUNT; ++i) {
        Peer *peer = &probe.peers[i];
        peer->index = i;
        peer->session = spice_session_new();
        g_object_set(peer->session,
                     "host", "127.0.0.1", "port", NULL,
                     "tls-port", probe.ports[i],
                     "password", "mrv-ci-synthetic-ticket",
                     "cert-subject", "CN=mrv-ci.test",
                     "ca", probe.ca,
                     "secure-channels", secure_channels,
                     "verify", SPICE_SESSION_VERIFY_SUBJECT,
                     "proxy", NULL, "pubkey", NULL,
                     "enable-audio", FALSE, "enable-usbredir", FALSE, NULL);
        g_signal_connect(peer->session, "channel-new", G_CALLBACK(channel_new), peer);
    }
    probe.deadline = g_get_monotonic_time() + 15 * G_USEC_PER_SEC;
    for (unsigned i = 0; i < SESSION_COUNT; ++i)
        if (!spice_session_connect(probe.peers[i].session)) probe.failed = TRUE;
    g_timeout_add(25, tick, NULL);
    g_main_loop_run(probe.loop);
    probe.closing = TRUE;
    for (unsigned i = 0; i < SESSION_COUNT; ++i)
        spice_session_disconnect(probe.peers[i].session);
    g_timeout_add(500, drain_done, NULL);
    g_main_loop_run(probe.loop);
    for (unsigned i = 0; i < SESSION_COUNT; ++i)
        g_object_unref(probe.peers[i].session);
    g_main_loop_unref(probe.loop);
    g_main_context_pop_thread_default(ctx);
    g_main_context_release(ctx);
    return NULL;
}

int main(int argc, char **argv) {
    if (argc != 6) return 2;
    gchar *bytes = NULL;
    gsize length = 0;
    if (!g_file_get_contents(argv[1], &bytes, &length, NULL) ||
        !length || length > 512 * 1024) {
        g_free(bytes);
        return 2;
    }
    probe.ca = g_byte_array_new();
    g_byte_array_append(probe.ca, (const guint8 *)bytes, (guint)length);
    g_free(bytes);
    for (unsigned i = 0; i < SESSION_COUNT; ++i) {
        char *end = NULL;
        long port = strtol(argv[i + 2], &end, 10);
        if (!end || *end || port < 1 || port > 65535) return 2;
        probe.ports[i] = argv[i + 2];
    }
    probe.result = 1;
    pthread_t thread;
    if (pthread_create(&thread, NULL, run_worker, NULL) != 0) return 2;
    pthread_join(thread, NULL);
    g_byte_array_unref(probe.ca);
    if (!probe.result) puts("MRV_NATIVE_MULTI_OK");
    return probe.result;
}
