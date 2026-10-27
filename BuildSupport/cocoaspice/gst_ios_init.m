#include "gst_ios_init.h"

/// Homebrew／動態 GStreamer 入口。UTM 原檔會靜態註冊 gst_plugin_*，
/// 那些符號不存在於 bottle，因此原型改為 gst_init 並掃描系統 plugin 路徑。
void gst_ios_init(void)
{
    static gsize once = 0;
    if (g_once_init_enter(&once)) {
        gst_init(NULL, NULL);
        g_once_init_leave(&once, 1);
    }
}
