/* Test-only TLS SPICE main-channel server; no VM, display or external listener. */
#include <glib.h>
#include <glib-unix.h>
#include <spice.h>
#include <spice/enums.h>
#include <spice/qxl_dev.h>
#include <string.h>
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
    if (event == SPICE_CHANNEL_EVENT_INITIALIZED && info->type == SPICE_CHANNEL_MAIN) {
        printf("MAIN_INITIALIZED tls=%d\n", !!(info->flags & SPICE_CHANNEL_EVENT_FLAG_TLS));
        fflush(stdout);
    } else if (event == SPICE_CHANNEL_EVENT_INITIALIZED && info->type == SPICE_CHANNEL_DISPLAY) {
        printf("DISPLAY_INITIALIZED tls=%d\n", !!(info->flags & SPICE_CHANNEL_EVENT_FLAG_TLS));
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

/* Fixed test-only CPU framebuffer. Never expose guest or host desktop memory. */
enum { WIDTH = 640, HEIGHT = 480, DRAW_SLOTS = 16 };
static struct {
    uint32_t pixels[WIDTH * HEIGHT];
    QXLDrawable draws[DRAW_SLOTS];
    QXLImage images[DRAW_SLOTS];
    uint32_t red[WIDTH * HEIGHT];
    uint32_t green[WIDTH * HEIGHT];
} framebuffer;
#define pixels framebuffer.pixels
static QXLInstance qxl;
/* Bounded pool: SPICE may retain a drawable until a later update supersedes it. */
static gint draw_states[DRAW_SLOTS];
static unsigned next_color;
static unsigned palette_index;
static const uint32_t palettes[4][2] = {
    {0x00ff0000, 0x0000ff00}, /* red / green */
    {0x000000ff, 0x00ffff00}, /* blue / yellow */
    {0x0000ffff, 0x00ff00ff}, /* cyan / magenta */
    {0x00ffffff, 0x00808080}, /* white / gray */
};
static gint submitted_draws;
static gint consumed_draws;
static gint released_draws;
static int qxl_get_draw(QXLInstance *instance, QXLCommandExt *command) {
    (void)instance;
    for (int i = 0; i < DRAW_SLOTS; ++i) {
        if (!g_atomic_int_compare_and_exchange(&draw_states[i], 1, 2)) continue;
        memset(command, 0, sizeof(*command));
        command->cmd.type = QXL_CMD_DRAW;
        command->cmd.data = (uintptr_t)&framebuffer.draws[i];
        command->group_id = 0;
        g_atomic_int_inc(&consumed_draws);
        return 1;
    }
    return 0;
}
static gboolean update_color(gpointer data) {
    (void)data;
    // The GLib main loop is the only producer. Do not queue another command
    // while a previous one is still pending consumption.
    int slot = -1;
    for (int i = 0; i < DRAW_SLOTS; ++i) {
        int state = g_atomic_int_get(&draw_states[i]);
        if (state == 1) return G_SOURCE_CONTINUE;
        if (state == 0 && slot < 0) slot = i;
    }
    if (slot < 0) return G_SOURCE_CONTINUE;
    QXLDrawable *draw = &framebuffer.draws[slot];
    memset(draw, 0, sizeof(*draw));
    draw->release_info.id = (uintptr_t)draw;
    draw->surface_id = 0;
    draw->bbox.right = WIDTH;
    draw->bbox.bottom = HEIGHT;
    draw->clip.type = SPICE_CLIP_TYPE_NONE;
    draw->effect = QXL_EFFECT_OPAQUE;
    draw->type = QXL_DRAW_COPY;
    for (int i = 0; i < 3; ++i) draw->surfaces_dest[i] = -1;
    draw->mm_time = (uint32_t)(g_get_monotonic_time() / 1000);
    QXLImage *image = &framebuffer.images[slot];
    memset(image, 0, sizeof(*image));
    unsigned sequence = next_color++;
    image->descriptor.id = (uint64_t)sequence + 1;
    image->descriptor.type = SPICE_IMAGE_TYPE_BITMAP;
    image->descriptor.width = WIDTH;
    image->descriptor.height = HEIGHT;
    image->bitmap.format = SPICE_BITMAP_FMT_32BIT;
    image->bitmap.flags = QXL_BITMAP_DIRECT | QXL_BITMAP_TOP_DOWN;
    image->bitmap.x = WIDTH;
    image->bitmap.y = HEIGHT;
    image->bitmap.stride = WIDTH * 4;
    image->bitmap.data = (uintptr_t)(sequence % 2 ? framebuffer.green : framebuffer.red);
    draw->u.copy.src_bitmap = (uintptr_t)image;
    draw->u.copy.src_area.right = WIDTH;
    draw->u.copy.src_area.bottom = HEIGHT;
    draw->u.copy.rop_descriptor = SPICE_ROPD_OP_PUT;
    g_atomic_int_inc(&submitted_draws);
    g_atomic_int_set(&draw_states[slot], 1);
    spice_qxl_wakeup(&qxl);
    return G_SOURCE_CONTINUE;
}

static void qxl_attached(QXLInstance *instance) { (void)instance; }
static void qxl_compression(QXLInstance *instance, int level) { (void)instance; (void)level; }
static void qxl_init_info(QXLInstance *instance, QXLDevInitInfo *info) {
    (void)instance;
    memset(info, 0, sizeof(*info));
    info->memslot_gen_bits = 1;
    info->memslot_id_bits = 1;
    info->num_memslots = 1;
    info->num_memslots_groups = 1;
    info->internal_groupslot_id = 0;
    info->qxl_ram_size = sizeof(framebuffer);
    info->n_surfaces = 1;
}
static int qxl_no_command(QXLInstance *instance, QXLCommandExt *command) {
    (void)instance; (void)command; return 0;
}
static int qxl_notification(QXLInstance *instance) { (void)instance; return 1; }
static void qxl_release(QXLInstance *instance, QXLReleaseInfoExt info) {
    (void)instance;
    if (!info.info) return;
    for (int i = 0; i < DRAW_SLOTS; ++i) {
        if (info.info->id == (uintptr_t)&framebuffer.draws[i]) {
            g_atomic_int_inc(&released_draws);
            g_atomic_int_set(&draw_states[i], 0);
            return;
        }
    }
}
static void qxl_notify_update(QXLInstance *instance, uint32_t id) { (void)instance; (void)id; }
static int qxl_flush(QXLInstance *instance) { (void)instance; return 0; }
static void qxl_async(QXLInstance *instance, uint64_t cookie) { (void)instance; (void)cookie; }
static void qxl_update_complete(QXLInstance *instance, uint32_t surface_id, QXLRect *dirty, uint32_t count) {
    (void)instance; (void)surface_id; (void)dirty; (void)count;
}
static void qxl_capabilities(QXLInstance *instance, uint8_t present, uint8_t caps[58]) {
    (void)instance; (void)present; (void)caps;
}

static QXLInterface display_interface = {
    .base = {
        .type = SPICE_INTERFACE_QXL,
        .description = "MRV synthetic CPU framebuffer",
        .major_version = SPICE_INTERFACE_QXL_MAJOR,
        .minor_version = SPICE_INTERFACE_QXL_MINOR,
    },
    .attached_worker = qxl_attached,
    .set_compression_level = qxl_compression,
    .get_init_info = qxl_init_info,
    .get_command = qxl_get_draw,
    .req_cmd_notification = qxl_notification,
    .release_resource = qxl_release,
    .get_cursor_command = qxl_no_command,
    .req_cursor_notification = qxl_notification,
    .notify_update = qxl_notify_update,
    .flush_resources = qxl_flush,
    .async_complete = qxl_async,
    .update_area_complete = qxl_update_complete,
    .set_client_capabilities = qxl_capabilities,
};

static int setup_display(SpiceServer *server) {
    memset(&qxl, 0, sizeof(qxl));
    for (size_t i = 0; i < WIDTH * HEIGHT; ++i) {
        framebuffer.red[i] = palettes[palette_index][0];
        framebuffer.green[i] = palettes[palette_index][1];
    }
    qxl.base.sif = &display_interface.base;
    qxl.id = 0;
    if (spice_server_add_interface(server, &qxl.base)) return 1;
    QXLDevMemSlot slot = {0};
    slot.slot_group_id = 0;
    slot.virt_start = (uintptr_t)&framebuffer;
    slot.virt_end = (uintptr_t)&framebuffer + sizeof(framebuffer);
    slot.addr_delta = 0;
    spice_qxl_add_memslot(&qxl, &slot);
    QXLDevSurfaceCreate surface = {0};
    surface.width = WIDTH;
    surface.height = HEIGHT;
    surface.stride = -WIDTH * 4;
    surface.format = SPICE_SURFACE_FMT_32_xRGB;
    surface.mouse_mode = 1;
    surface.mem = (uintptr_t)pixels;
    surface.group_id = 0;
    spice_qxl_create_primary_surface(&qxl, 0, &surface);
    printf("PRIMARY_CREATED %dx%d\n", WIDTH, HEIGHT);
    fflush(stdout);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 6 || argc > 8) return 2;
    int with_display = argc >= 7 && strcmp(argv[6], "display") == 0;
    if (argc >= 7 && !with_display) return 2;
    if (argc == 8) {
        if (strlen(argv[7]) != 1 || argv[7][0] < '0' || argv[7][0] > '3') return 2;
        palette_index = (unsigned)(argv[7][0] - '0');
    }
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
    if (with_display && setup_display(server)) return 1;
    // A primary surface can be sent while the virtual machine is stopped.
    // The red worker will not consume QXL commands until VM start.
    if (with_display) {
        spice_server_vm_start(server);
        printf("VM_STARTED\n");
        fflush(stdout);
    }
    GMainLoop *loop = g_main_loop_new(NULL, FALSE);
    guint signal_source = g_unix_signal_add(SIGTERM, quit_loop, loop);
    guint update_source = with_display ? g_timeout_add(250, update_color, NULL) : 0;
    printf("READY\n");
    fflush(stdout);
    g_main_loop_run(loop);
    g_source_remove(signal_source);
    if (update_source) g_source_remove(update_source);
    if (with_display) {
        // Destroy while running so the worker can flush pending commands.
        spice_qxl_destroy_primary_surface(&qxl, 0);
        spice_server_vm_stop(server);
        printf("DRAW_COUNTS submitted=%d consumed=%d released=%d\n",
               g_atomic_int_get(&submitted_draws), g_atomic_int_get(&consumed_draws),
               g_atomic_int_get(&released_draws));
        fflush(stdout);
    }
    spice_server_destroy(server);
    g_main_loop_unref(loop);
    return 0;
}
