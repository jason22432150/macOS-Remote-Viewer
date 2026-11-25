#include "gst_ios_init.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Inspect the actual initialized registry, not merely the configured paths.
// Only the explicit packaged startup smoke enables this read-only probe.
static void verify_packaged_registry(void)
{
    if (g_strcmp0(g_getenv("MRV_VERIFY_PACKAGED_GST"), "1") != 0) {
        return;
    }
    const gchar *root = g_getenv("GST_PLUGIN_SYSTEM_PATH_1_0");
    char *resolved_root = root ? realpath(root, NULL) : NULL;
    gchar *prefix = resolved_root ? g_strconcat(resolved_root, G_DIR_SEPARATOR_S, NULL) : NULL;
    gboolean ok = prefix != NULL;
    guint dynamic_count = 0;
    gboolean core_found = FALSE;
    GList *plugins = gst_registry_get_plugin_list(gst_registry_get());
    for (GList *item = plugins; item; item = item->next) {
        GstPlugin *plugin = GST_PLUGIN(item->data);
        const gchar *filename = gst_plugin_get_filename(plugin);
        if (!filename) {
            continue; // static plugin, no external module path
        }
        dynamic_count++;
        char *resolved = realpath(filename, NULL);
        if (!resolved || !prefix || !g_str_has_prefix(resolved, prefix)) {
            ok = FALSE;
        }
        if (g_strcmp0(gst_plugin_get_name(plugin), "coreelements") == 0) {
            core_found = TRUE;
        }
        free(resolved);
    }
    gst_plugin_list_free(plugins);
    g_free(prefix);
    free(resolved_root);
    puts(ok && core_found && dynamic_count > 0 ? "MRV_GST_REGISTRY_OK" : "MRV_GST_REGISTRY_FAILED");
    fflush(stdout);
}

/// Homebrew / dynamic GStreamer entry point.
void gst_ios_init(void)
{
    static gsize once = 0;
    if (g_once_init_enter(&once)) {
        gst_init(NULL, NULL);
        verify_packaged_registry();
        g_once_init_leave(&once, 1);
    }
}
