/* Test-only TLS SPICE main-channel server; no VM, display or external listener. */
#include <glib.h>
#include <glib-unix.h>
#include <spice.h>
#include <stdint.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>

struct SpiceTimer {
    SpiceTimerFunc callback;
    void *opaque;
    guint source;
};

struct SpiceWatch {
    SpiceWatchFunc callback;
    void *opaque;
    int fd;
    guint source;
};

static void remove_source(guint *source) {
    if (*source) {
        guint id = *source;
        *source = 0;
        g_source_remove(id);
    }
}

static SpiceTimer *timer_add(SpiceTimerFunc callback, void *opaque) {
    SpiceTimer *timer = g_new0(SpiceTimer, 1);
    timer->callback = callback;
    timer->opaque = opaque;
    return timer;
}

static gboolean timer_fire(gpointer data) {
    SpiceTimer *timer = data;
    timer->source = 0;
    timer->callback(timer->opaque);
    return G_SOURCE_REMOVE;
}

static void timer_cancel(SpiceTimer *timer) {
    remove_source(&timer->source);
}

static void timer_start(SpiceTimer *timer, uint32_t ms) {
    timer_cancel(timer);
    timer->source = g_timeout_add(ms, timer_fire, timer);
}

static void timer_remove(SpiceTimer *timer) {
    timer_cancel(timer);
    g_free(timer);
}

static gboolean watch_fire(gint fd, GIOCondition condition, gpointer data) {
    SpiceWatch *watch = data;
    int event = 0;
    if (condition & (G_IO_IN | G_IO_HUP | G_IO_ERR | G_IO_NVAL))
        event |= SPICE_WATCH_EVENT_READ;
    if (condition & G_IO_OUT)
        event |= SPICE_WATCH_EVENT_WRITE;
    watch->callback(fd, event, watch->opaque);
    return G_SOURCE_CONTINUE;
}

static void watch_update_mask(SpiceWatch *watch, int mask) {
    remove_source(&watch->source);
    GIOCondition condition = G_IO_ERR | G_IO_HUP | G_IO_NVAL;
    if (mask & SPICE_WATCH_EVENT_READ) condition |= G_IO_IN;
    if (mask & SPICE_WATCH_EVENT_WRITE) condition |= G_IO_OUT;
    if (mask) watch->source = g_unix_fd_add(watch->fd, condition, watch_fire, watch);
}

static SpiceWatch *watch_add(int fd, int mask, SpiceWatchFunc callback, void *opaque) {
    SpiceWatch *watch = g_new0(SpiceWatch, 1);
    watch->fd = fd;
    watch->callback = callback;
    watch->opaque = opaque;
    watch_update_mask(watch, mask);
    return watch;
}

static void watch_remove(SpiceWatch *watch) {
    remove_source(&watch->source);
    g_free(watch);
}

static void channel_event(int event, SpiceChannelEventInfo *info) {
    if (event == SPICE_CHANNEL_EVENT_INITIALIZED && info->type == 1) {
        printf("MAIN_INITIALIZED tls=%d\n", !!(info->flags & SPICE_CHANNEL_EVENT_FLAG_TLS));
        fflush(stdout);
    }
}

static SpiceCoreInterface core = {
    .base = {
        .type = SPICE_INTERFACE_CORE,
        .description = "MRV loopback integration fixture",
        .major_version = SPICE_INTERFACE_CORE_MAJOR,
        .minor_version = SPICE_INTERFACE_CORE_MINOR,
    },
    .timer_add = timer_add,
    .timer_start = timer_start,
    .timer_cancel = timer_cancel,
    .timer_remove = timer_remove,
    .watch_add = watch_add,
    .watch_update_mask = watch_update_mask,
    .watch_remove = watch_remove,
    .channel_event = channel_event,
};

static gboolean quit_loop(gpointer data) {
    g_main_loop_quit(data);
    return G_SOURCE_CONTINUE;
}

int main(int argc, char **argv) {
    if (argc != 6) return 2;
    int port = atoi(argv[1]);
    if (port < 1 || port > 65535) return 2;
    SpiceServer *server = spice_server_new();
    if (!server) return 1;
    spice_server_set_addr(server, "127.0.0.1", SPICE_ADDR_FLAG_IPV4_ONLY);
    if (spice_server_set_tls(server, port, argv[2], argv[3], argv[4], NULL, NULL, NULL) ||
        spice_server_set_ticket(server, argv[5], 180, 0, 0) ||
        spice_server_set_channel_security(server, NULL, SPICE_CHANNEL_SECURITY_SSL) ||
        spice_server_init(server, &core)) {
        fprintf(stderr, "SPICE fixture initialization failed\n");
        return 1;
    }
    GMainLoop *loop = g_main_loop_new(NULL, FALSE);
    guint signal_source = g_unix_signal_add(SIGTERM, quit_loop, loop);
    printf("READY\n");
    fflush(stdout);
    g_main_loop_run(loop);
    g_source_remove(signal_source);
    spice_server_destroy(server);
    g_main_loop_unref(loop);
    return 0;
}
