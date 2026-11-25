/* Test-only TLS SPICE main-channel server; no VM, display or external listener. */
#include <glib.h>
#include <glib-unix.h>
#include <spice.h>
#include <spice/enums.h>
#include <spice/qxl_dev.h>
#include <spice/vd_agent.h>
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
enum { WIDTH = 640, HEIGHT = 480, RESIZE_W = 1024, RESIZE_H = 768, DRAW_SLOTS = 16, PATCH_W = 160, PATCH_H = 120 };
static unsigned surface_width = WIDTH, surface_height = HEIGHT;
static gboolean resize_applied;
static struct {
    uint32_t pixels[RESIZE_W * RESIZE_H];
    QXLDrawable draws[DRAW_SLOTS];
    QXLImage images[DRAW_SLOTS];
    uint32_t red[WIDTH * HEIGHT];
    uint32_t green[WIDTH * HEIGHT];
    uint32_t blue[WIDTH * HEIGHT];
    uint32_t resized_a[RESIZE_W * RESIZE_H];
    uint32_t resized_b[RESIZE_W * RESIZE_H];
} framebuffer;
#define pixels framebuffer.pixels
static QXLInstance qxl;
/* Bounded pool: SPICE may retain a drawable until a later update supersedes it. */
static gint draw_states[DRAW_SLOTS];
static unsigned next_color;
static unsigned palette_index;
static gboolean partial_updates;
static unsigned partial_submitted;
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
    unsigned sequence = next_color++;
    gboolean patch = partial_updates && sequence > 0;
    unsigned width = patch ? PATCH_W : surface_width;
    unsigned height = patch ? PATCH_H : surface_height;
    draw->bbox.left = patch ? (WIDTH - PATCH_W) / 2 : 0;
    draw->bbox.top = patch ? (HEIGHT - PATCH_H) / 2 : 0;
    draw->bbox.right = draw->bbox.left + width;
    draw->bbox.bottom = draw->bbox.top + height;
    draw->clip.type = SPICE_CLIP_TYPE_NONE;
    draw->effect = QXL_EFFECT_OPAQUE;
    draw->type = QXL_DRAW_COPY;
    for (int i = 0; i < 3; ++i) draw->surfaces_dest[i] = -1;
    draw->mm_time = (uint32_t)(g_get_monotonic_time() / 1000);
    QXLImage *image = &framebuffer.images[slot];
    memset(image, 0, sizeof(*image));
    image->descriptor.id = (uint64_t)sequence + 1;
    image->descriptor.type = SPICE_IMAGE_TYPE_BITMAP;
    image->descriptor.width = width;
    image->descriptor.height = height;
    image->bitmap.format = SPICE_BITMAP_FMT_32BIT;
    image->bitmap.flags = QXL_BITMAP_DIRECT | QXL_BITMAP_TOP_DOWN;
    image->bitmap.x = width;
    image->bitmap.y = height;
    image->bitmap.stride = width * 4;
    image->bitmap.data = (uintptr_t)(resize_applied ?
                                     (sequence % 2 ? framebuffer.resized_a : framebuffer.resized_b) :
                                     (partial_updates && !patch ? framebuffer.blue :
                                     (sequence % 2 ? framebuffer.green : framebuffer.red)));
    draw->u.copy.src_bitmap = (uintptr_t)image;
    draw->u.copy.src_area.right = width;
    draw->u.copy.src_area.bottom = height;
    if (patch) ++partial_submitted;
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

static void create_primary(unsigned width, unsigned height) {
    QXLDevSurfaceCreate surface = {0};
    surface.width = width;
    surface.height = height;
    surface.stride = -(int32_t)(width * 4);
    surface.format = SPICE_SURFACE_FMT_32_xRGB;
    surface.mouse_mode = 1;
    surface.mem = (uintptr_t)pixels;
    surface.group_id = 0;
    spice_qxl_create_primary_surface(&qxl, 0, &surface);
}
static int setup_display(SpiceServer *server) {
    memset(&qxl, 0, sizeof(qxl));
    for (size_t i = 0; i < WIDTH * HEIGHT; ++i) {
        framebuffer.red[i] = palettes[palette_index][0];
        framebuffer.green[i] = palettes[palette_index][1];
        if (partial_updates) framebuffer.blue[i] = 0x000000ff;
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
    create_primary(WIDTH, HEIGHT);
    printf("PRIMARY_CREATED %dx%d\n", WIDTH, HEIGHT);
    fflush(stdout);
    return 0;
}

/* Synthetic guest agent, deliberately limited to capabilities negotiation.
 * No guest filesystem, clipboard contents, or external virtio endpoint.
 * VDI framing follows the public spice-protocol vd_agent.h declarations.
 */
static SpiceCharDeviceInstance agent_device;
static gboolean agent_full, agent_attached, agent_error, agent_monitor, agent_resize;
static unsigned agent_monitor_requests, agent_monitor_targets;
static gboolean agent_clipboard, clip_host_grab, clip_host_requested, clip_host_ok;
static gboolean clip_guest_grab, clip_guest_requested, clip_guest_sent;
static const char clip_host_text[] = "MRV Mac 繁體中文 ☀️\nline-2";
static const char clip_guest_text[] = "MRV Guest 測試剪貼簿 🚀\nline-2";
static gboolean agent_received_caps, agent_sent_caps;
static gint64 agent_delivered_at;
static uint8_t agent_rx[65536], agent_tx[128];
static size_t agent_rx_len, agent_tx_len, agent_tx_pos;

static void agent_state(SpiceCharDeviceInstance *sin, int connected) {
    (void)sin;
    printf("AGENT_DEVICE_STATE connected=%d\n", connected);
    fflush(stdout);
}

static int agent_write(SpiceCharDeviceInstance *sin, const uint8_t *buf, int len) {
    (void)sin;
    if (len <= 0) return 0;
    if ((size_t)len > sizeof(agent_rx) - agent_rx_len) {
        agent_error = TRUE;
        return -1;
    }
    memcpy(agent_rx + agent_rx_len, buf, (size_t)len);
    agent_rx_len += (size_t)len;
    // Handle partial char-device writes, and never trust a chunk length.
    while (agent_rx_len >= sizeof(VDIChunkHeader)) {
        VDIChunkHeader chunk;
        memcpy(&chunk, agent_rx, sizeof(chunk));
        uint32_t size = GUINT32_FROM_LE(chunk.size);
        if (size > sizeof(agent_rx) - sizeof(chunk)) {
            agent_error = TRUE;
            return -1;
        }
        size_t total = sizeof(chunk) + size;
        if (agent_rx_len < total) break;
        if (GUINT32_FROM_LE(chunk.port) == VDP_CLIENT_PORT && size >= sizeof(VDAgentMessage)) {
            VDAgentMessage msg;
            memcpy(&msg, agent_rx + sizeof(chunk), sizeof(msg));
            uint32_t payload_size = GUINT32_FROM_LE(msg.size);
            const uint8_t *payload = agent_rx + sizeof(chunk) + sizeof(msg);
            if (agent_clipboard && GUINT32_FROM_LE(msg.protocol) == VD_AGENT_PROTOCOL &&
                payload_size == size - sizeof(msg)) {
                uint32_t type = GUINT32_FROM_LE(msg.type);
                uint32_t format = 0;
                if (payload_size >= sizeof(format)) {
                    memcpy(&format, payload, sizeof(format));
                    format = GUINT32_FROM_LE(format);
                }
                // We intentionally do not advertise CLIPBOARD_SELECTION or
                // GRAB_SERIAL; the legacy clipboard payload starts at type.
                if (type == VD_AGENT_CLIPBOARD_GRAB && !clip_host_grab &&
                    payload_size == sizeof(uint32_t) && format == VD_AGENT_CLIPBOARD_UTF8_TEXT) {
                    clip_host_grab = TRUE;
                    puts("AGENT_CLIP_HOST_GRAB");
                } else if (type == VD_AGENT_CLIPBOARD && clip_host_requested && !clip_host_ok) {
                    if (format != VD_AGENT_CLIPBOARD_UTF8_TEXT ||
                        payload_size != sizeof(format) + sizeof(clip_host_text) - 1 ||
                        memcmp(payload + sizeof(format), clip_host_text, sizeof(clip_host_text) - 1)) {
                        agent_error = TRUE;
                        puts("AGENT_CLIP_HOST_MISMATCH");
                        fflush(stdout);
                        return -1;
                    }
                    clip_host_ok = TRUE;
                    puts("AGENT_CLIP_HOST_UTF8_OK");
                } else if (type == VD_AGENT_CLIPBOARD_REQUEST && clip_guest_grab &&
                           payload_size == sizeof(format) && format == VD_AGENT_CLIPBOARD_UTF8_TEXT &&
                           !clip_guest_requested) {
                    clip_guest_requested = TRUE;
                    puts("AGENT_CLIP_GUEST_REQUEST");
                }
                fflush(stdout);
            }
            if (agent_monitor && GUINT32_FROM_LE(msg.protocol) == VD_AGENT_PROTOCOL &&
                GUINT32_FROM_LE(msg.type) == VD_AGENT_MONITORS_CONFIG) {
                // The bounded single-display fixture handles the ordinary
                // monitor array, not arbitrary fragmented agent messages.
                if (payload_size != size - sizeof(msg) || payload_size < sizeof(VDAgentMonitorsConfig)) {
                    agent_error = TRUE;
                    return -1;
                }
                VDAgentMonitorsConfig config;
                memcpy(&config, payload, sizeof(config));
                uint32_t count = GUINT32_FROM_LE(config.num_of_monitors);
                if (count > 16 || count > (payload_size - sizeof(config)) / sizeof(VDAgentMonConfig)) {
                    agent_error = TRUE;
                    return -1;
                }
                ++agent_monitor_requests;
                for (uint32_t i = 0; i < count; ++i) {
                    VDAgentMonConfig monitor;
                    memcpy(&monitor, payload + sizeof(config) + i * sizeof(monitor), sizeof(monitor));
                    uint32_t width = GUINT32_FROM_LE(monitor.width);
                    uint32_t height = GUINT32_FROM_LE(monitor.height);
                    printf("AGENT_MONITOR_REQUEST width=%u height=%u\n", width, height);
                    if (count == 1 && width == 1024 && height == 768) ++agent_monitor_targets;
                }
                fflush(stdout);
            }
            if (GUINT32_FROM_LE(msg.protocol) == VD_AGENT_PROTOCOL &&
                GUINT32_FROM_LE(msg.type) == VD_AGENT_ANNOUNCE_CAPABILITIES &&
                GUINT32_FROM_LE(msg.size) >= sizeof(uint32_t) &&
                GUINT32_FROM_LE(msg.size) == size - sizeof(msg)) {
                if (!agent_received_caps) {
                    agent_received_caps = TRUE;
                    puts("AGENT_CLIENT_CAPS");
                    fflush(stdout);
                }
            }
        }
        memmove(agent_rx, agent_rx + total, agent_rx_len - total);
        agent_rx_len -= total;
    }
    return len;
}

static int agent_read(SpiceCharDeviceInstance *sin, uint8_t *buf, int len) {
    (void)sin;
    if (len <= 0 || agent_tx_pos >= agent_tx_len) return 0;
    size_t count = MIN((size_t)len, agent_tx_len - agent_tx_pos);
    memcpy(buf, agent_tx + agent_tx_pos, count);
    agent_tx_pos += count;
    if (agent_tx_pos == agent_tx_len) {
        if (!agent_delivered_at) {
            agent_delivered_at = g_get_monotonic_time();
            puts("AGENT_CAPS_DELIVERED");
            fflush(stdout);
        }
    }
    return (int)count;
}

static SpiceCharDeviceInterface agent_interface = {
    .base = {
        .type = SPICE_INTERFACE_CHAR_DEVICE,
        .description = "MRV synthetic capability-only guest agent",
        .major_version = SPICE_INTERFACE_CHAR_DEVICE_MAJOR,
        .minor_version = SPICE_INTERFACE_CHAR_DEVICE_MINOR,
    },
    .state = agent_state,
    .write = agent_write,
    .read = agent_read,
};

static void agent_queue_clip(uint32_t message_type, const char *text, size_t text_len) {
    uint32_t format = GUINT32_TO_LE(VD_AGENT_CLIPBOARD_UTF8_TEXT);
    VDAgentMessage msg = {0};
    msg.protocol = GUINT32_TO_LE(VD_AGENT_PROTOCOL);
    msg.type = GUINT32_TO_LE(message_type);
    msg.size = GUINT32_TO_LE((uint32_t)(sizeof(format) + text_len));
    VDIChunkHeader chunk = {
        .port = GUINT32_TO_LE(VDP_CLIENT_PORT),
        .size = GUINT32_TO_LE((uint32_t)(sizeof(msg) + sizeof(format) + text_len)),
    };
    size_t total = sizeof(chunk) + sizeof(msg) + sizeof(format) + text_len;
    if (agent_tx_pos != agent_tx_len || total > sizeof(agent_tx)) {
        agent_error = TRUE;
        return;
    }
    memcpy(agent_tx, &chunk, sizeof(chunk));
    memcpy(agent_tx + sizeof(chunk), &msg, sizeof(msg));
    memcpy(agent_tx + sizeof(chunk) + sizeof(msg), &format, sizeof(format));
    if (text_len) memcpy(agent_tx + sizeof(chunk) + sizeof(msg) + sizeof(format), text, text_len);
    agent_tx_len = total;
    agent_tx_pos = 0;
    spice_server_char_device_wakeup(&agent_device);
}

static gboolean agent_tick(gpointer data) {
    (void)data;
    if (!agent_attached || agent_error) return G_SOURCE_CONTINUE;
    if (agent_received_caps && !agent_sent_caps) {
        // Reply only after the client negotiated the agent data channel.
        uint32_t caps[2] = {0, 0};
        VD_AGENT_SET_CAPABILITY(caps, VD_AGENT_CAP_REPLY);
        if (agent_full) {
            VD_AGENT_SET_CAPABILITY(caps, VD_AGENT_CAP_MONITORS_CONFIG);
            VD_AGENT_SET_CAPABILITY(caps, VD_AGENT_CAP_CLIPBOARD_BY_DEMAND);
        }
        uint32_t payload[3] = {GUINT32_TO_LE(0), GUINT32_TO_LE(caps[0]), GUINT32_TO_LE(caps[1])};
        VDAgentMessage msg = {0};
        msg.protocol = GUINT32_TO_LE(VD_AGENT_PROTOCOL);
        msg.type = GUINT32_TO_LE(VD_AGENT_ANNOUNCE_CAPABILITIES);
        msg.size = GUINT32_TO_LE(sizeof(payload));
        VDIChunkHeader chunk = {
            .port = GUINT32_TO_LE(VDP_CLIENT_PORT),
            .size = GUINT32_TO_LE(sizeof(msg) + sizeof(payload)),
        };
        memcpy(agent_tx, &chunk, sizeof(chunk));
        memcpy(agent_tx + sizeof(chunk), &msg, sizeof(msg));
        memcpy(agent_tx + sizeof(chunk) + sizeof(msg), payload, sizeof(payload));
        agent_tx_len = sizeof(chunk) + sizeof(msg) + sizeof(payload);
        agent_sent_caps = TRUE;
        printf("AGENT_CAPS_SENT monitors=%d clipboard=%d\n", agent_full, agent_full);
        fflush(stdout);
        spice_server_char_device_wakeup(&agent_device);
    } else if (agent_sent_caps && agent_tx_pos < agent_tx_len) {
        spice_server_char_device_wakeup(&agent_device);
    } else if (agent_clipboard && clip_host_grab && !clip_host_requested) {
        clip_host_requested = TRUE;
        puts("AGENT_CLIP_HOST_REQUEST");
        fflush(stdout);
        agent_queue_clip(VD_AGENT_CLIPBOARD_REQUEST, NULL, 0);
    } else if (agent_clipboard && clip_host_ok && !clip_guest_grab) {
        clip_guest_grab = TRUE;
        puts("AGENT_CLIP_GUEST_GRAB");
        fflush(stdout);
        agent_queue_clip(VD_AGENT_CLIPBOARD_GRAB, NULL, 0);
    } else if (agent_clipboard && clip_guest_requested && !clip_guest_sent) {
        clip_guest_sent = TRUE;
        puts("AGENT_CLIP_GUEST_UTF8_SENT");
        fflush(stdout);
        agent_queue_clip(VD_AGENT_CLIPBOARD, clip_guest_text, sizeof(clip_guest_text) - 1);
    } else if (agent_resize && agent_monitor_targets && !resize_applied) {
        // Main-loop producer is serialized with update_color. Wait until the
        // worker has consumed queued commands, then synchronously destroy
        // the old primary; immutable bitmap storage remains valid.
        for (int i = 0; i < DRAW_SLOTS; ++i)
            if (g_atomic_int_get(&draw_states[i]) == 1) return G_SOURCE_CONTINUE;
        spice_qxl_destroy_primary_surface(&qxl, 0);
        // pixels is a macro for framebuffer.pixels; use the same alias in sizeof.
        memset(pixels, 0, sizeof(pixels));
        surface_width = RESIZE_W;
        surface_height = RESIZE_H;
        resize_applied = TRUE;
        create_primary(surface_width, surface_height);
        puts("AGENT_PRIMARY_RESIZED 1024x768");
        fflush(stdout);
    } else if (agent_delivered_at && g_get_monotonic_time() - agent_delivered_at >= (agent_clipboard ? 12000000 : agent_resize ? 10000000 : agent_monitor ? 6000000 : 3000000)) {
        // Real server-side hot removal, not a fabricated client callback.
        agent_attached = FALSE;
        if (spice_server_remove_interface(&agent_device.base)) {
            agent_error = TRUE;
        } else {
            puts("AGENT_REMOVED");
            fflush(stdout);
        }
    }
    return G_SOURCE_CONTINUE;
}

static int setup_agent(SpiceServer *server) {
    agent_device.base.sif = &agent_interface.base;
    agent_device.subtype = "vdagent";
    if (spice_server_add_interface(server, &agent_device.base)) return 1;
    agent_attached = TRUE;
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 6 || argc > 8) return 2;
    partial_updates = argc == 7 && strcmp(argv[6], "partial") == 0;
    gboolean workspace = argc == 8 && strcmp(argv[6], "workspace") == 0;
    agent_clipboard = argc == 7 && strcmp(argv[6], "agent-clipboard-full") == 0;
    agent_resize = argc == 7 && strcmp(argv[6], "agent-monitor-resize-full") == 0;
    agent_monitor = agent_resize || (argc == 7 && (strcmp(argv[6], "agent-monitor-full") == 0 ||
                                  strcmp(argv[6], "agent-monitor-limited") == 0));
    if (agent_resize) {
        for (size_t i = 0; i < RESIZE_W * RESIZE_H; ++i) {
            framebuffer.resized_a[i] = 0x0000ffff;
            framebuffer.resized_b[i] = 0x00ff00ff;
        }
    }
    int with_display = argc >= 7 && (strcmp(argv[6], "display") == 0 || partial_updates || workspace || agent_monitor);
    gboolean with_agent = agent_clipboard || agent_monitor || (argc == 7 && (strcmp(argv[6], "agent-full") == 0 || strcmp(argv[6], "agent-limited") == 0));
    agent_full = with_agent && (agent_clipboard || agent_resize || strcmp(argv[6], "agent-full") == 0 || strcmp(argv[6], "agent-monitor-full") == 0);
    if (argc >= 7 && !with_display && !with_agent) return 2;
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
        spice_server_set_ticket(server, argv[5], workspace ? 600 : 180, 0, 0) ||
        spice_server_set_channel_security(server, NULL, SPICE_CHANNEL_SECURITY_SSL) ||
        spice_server_init(server, &core)) {
        fprintf(stderr, "SPICE fixture initialization failed\n");
        return 1;
    }
    if (with_display && setup_display(server)) return 1;
    if (with_agent && setup_agent(server)) return 1;
    // A primary surface can be sent while the virtual machine is stopped.
    // The red worker will not consume QXL commands until VM start.
    if (with_display) {
        spice_server_vm_start(server);
        printf("VM_STARTED\n");
        fflush(stdout);
    }
    if (with_agent && !with_display) spice_server_vm_start(server);
    GMainLoop *loop = g_main_loop_new(NULL, FALSE);
    guint signal_source = g_unix_signal_add(SIGTERM, quit_loop, loop);
    guint update_source = with_display ? g_timeout_add(250, update_color, NULL) : 0;
    guint agent_source = with_agent ? g_timeout_add(50, agent_tick, NULL) : 0;
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
        if (partial_updates) printf("PARTIAL_COUNTS submitted=%u rect=240,180,160,120\n", partial_submitted);
        fflush(stdout);
    }
    if (agent_source) g_source_remove(agent_source);
    if (with_agent) {
        if (agent_attached) spice_server_remove_interface(&agent_device.base);
        if (!with_display) spice_server_vm_stop(server);
        if (agent_monitor) printf("AGENT_MONITOR_RESULT requests=%u targets=%u\n", agent_monitor_requests, agent_monitor_targets);
        if (agent_clipboard) printf("AGENT_CLIP_RESULT host=%d guest-request=%d guest-sent=%d\n",
                                    clip_host_ok, clip_guest_requested, clip_guest_sent && agent_tx_pos == agent_tx_len);
        printf("AGENT_RESULT received=%d delivered=%d removed=%d error=%d\n",
               agent_received_caps, agent_delivered_at != 0, !agent_attached, agent_error);
        fflush(stdout);
    }
    spice_server_destroy(server);
    g_main_loop_unref(loop);
    return agent_error ? 1 : 0;
}
