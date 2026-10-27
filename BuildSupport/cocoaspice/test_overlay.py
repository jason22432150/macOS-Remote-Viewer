#!/usr/bin/env python3
"""overlay.py 的行為測試：Homebrew 相容 CSMain／gst_ios_init／Package.swift。"""

from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

from overlay import overlay_csmain, overlay_gst_ios_init, overlay_package_swift

CSMAIN_FIXTURE = """\
- (id)init {
    self = [super init];
    if (self) {
    if ((_main_context = g_main_context_new()) == NULL) {
            return nil;
        }
    }
    return self;
}

- (BOOL)spiceStart {
    @synchronized (self) {
        if (!self.running) {
            spice_util_set_main_context(_main_context);
            pthread_create(&spiceThread, &qosAttribute, &spice_main_loop, (__bridge_retained void *)self);
        }
    }
    return YES;
}

- (void)spiceStop {
    @synchronized (self) {
        if (self.running) {
            spice_util_set_main_context(NULL);
            g_main_context_wakeup(_main_context);
        }
    }
}
"""

PACKAGE_FIXTURE = """\
        .target(
            name: "CocoaSpiceNoUsb",
            cSettings: [
                .headerSearchPath("ExternalHeaders"),
                .headerSearchPath("ExternalHeaders/glib-2.0"),
                .headerSearchPath("ExternalHeaders/gstreamer-1.0"),
                .headerSearchPath("ExternalHeaders/spice-1"),
                .headerSearchPath("ExternalHeaders/spice-client-glib-2.0")]),
"""


class OverlayTests(unittest.TestCase):
    def test_csmain_uses_default_context_and_drops_utm_api(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            path = root / "Sources" / "CocoaSpice" / "CSMain.m"
            path.parent.mkdir(parents=True)
            path.write_text(CSMAIN_FIXTURE)
            overlay_csmain(root)
            text = path.read_text()
            self.assertNotIn("spice_util_set_main_context(_main_context)", text)
            self.assertNotIn("spice_util_set_main_context(NULL)", text)
            self.assertIn("g_main_context_ref(g_main_context_default())", text)
            self.assertNotIn("g_main_context_new()", text)

    def test_gst_ios_init_uses_dynamic_gst_init(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            path = root / "Sources" / "CocoaSpice" / "gst_ios_init.m"
            path.parent.mkdir(parents=True)
            path.write_text("GST_PLUGIN_STATIC_DECLARE(coreelements);\n")
            overlay_gst_ios_init(root)
            text = path.read_text()
            self.assertIn("gst_init(NULL, NULL)", text)
            self.assertNotIn("GST_PLUGIN_STATIC", text)

    def test_package_swift_injects_pkg_config_flags(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            path = root / "Package.swift"
            path.write_text(PACKAGE_FIXTURE)
            overlay_package_swift(root)
            text = path.read_text()
            self.assertIn(".unsafeFlags([", text)
            self.assertIn("-I", text)
            self.assertIn("linkerSettings", text)


if __name__ == "__main__":
    unittest.main()
