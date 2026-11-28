/* Inspect actual bundled decoder factories without starting media pipelines. */
#include <gst/gst.h>
#include <stdio.h>

int main(int argc, char **argv) {
    gst_init(NULL, NULL);
    for (int i = 1; i < argc; ++i) {
        GstElementFactory *factory = gst_element_factory_find(argv[i]);
        if (!factory) {
            printf("MRV_FACTORY\t%s\tmissing\t\n", argv[i]);
            continue;
        }
        GstElement *element = gst_element_factory_create(factory, NULL);
        GstPlugin *plugin = gst_plugin_feature_get_plugin(GST_PLUGIN_FEATURE(factory));
        const gchar *filename = plugin ? gst_plugin_get_filename(plugin) : NULL;
        printf("MRV_FACTORY\t%s\t%s\t%s\n", argv[i], element ? "created" : "create-failed",
               filename ? filename : "");
        if (element) gst_object_unref(element);
        if (plugin) gst_object_unref(plugin);
        gst_object_unref(factory);
    }
    return 0;
}
