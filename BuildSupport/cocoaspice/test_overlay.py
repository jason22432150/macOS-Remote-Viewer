#!/usr/bin/env python3
"""overlay.py 的行為測試：Homebrew 相容 CSMain／gst_ios_init／Package.swift。"""

from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

from overlay import (
    overlay_csmain,
    overlay_display_initial_frame,
    overlay_gst_ios_init,
    overlay_package_swift,
)

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

DISPLAY_FIXTURE = r"""
- (void)updateVisibleAreaWithRect:(CGRect)rect {
    CGRect primary = self.canvasArea;
    CGRect visible = CGRectIntersection(primary, rect);
    if (CGRectIsNull(visible)) {
        SPICE_DEBUG("[CocoaSpice] The monitor area is not intersecting primary surface");
        self.ready = NO;
        self.visibleArea = CGRectZero;
    } else {
        self.visibleArea = visible;
    }
    self.displaySize = self.visibleArea.size;
    if (!self.isGLEnabled) {
        [self rebuildCanvasTexture];
    }
    [self rebuildDisplayVertices];
    self.ready = YES;
}

#endif /* TARGET_OS_SIMULATOR */
    [self drawRegion:visibleArea];
}

    self.numVertices = sizeof(quadVertices) / sizeof(CSRenderVertex);
}

- (void)drawRegion:(CGRect)rect {
    if (!self.canvasData || !self.canvasBuffer) {
        return; // not ready to draw yet
    }
    self.canvasIsBusy = YES;
    NSInteger pixelSize = (self.canvasFormat == SPICE_SURFACE_FMT_32_xRGB) ? 4 : 2;
    // create draw region
    MTLRegion region = {
        { rect.origin.x-self.visibleArea.origin.x, rect.origin.y-self.visibleArea.origin.y, 0 }, // MTLOrigin
        { rect.size.width, rect.size.height, 1} // MTLSize
    };
    NSUInteger offset = (NSUInteger)(rect.origin.y*self.canvasStride + rect.origin.x*pixelSize);
    NSUInteger totalBytes = rect.size.width*rect.size.height*pixelSize;
#if TARGET_OS_OSX || TARGET_OS_SIMULATOR
    for (NSUInteger i = 0; i < rect.size.height; i++) {
#if TARGET_OS_SIMULATOR
        memcpy(self.canvasBuffer.contents + offset + i*self.canvasStride,
               self.canvasData + offset + i*self.canvasStride,
               rect.size.width*pixelSize);
#else /* !TARGET_OS_SIMULATOR */
        [self.canvasBuffer didModifyRange:NSMakeRange(offset+i*self.canvasStride,
                                                      rect.size.width*pixelSize)];
#endif /* TARGET_OS_SIMULATOR */
    }
#endif
    dispatch_semaphore_t drawCompletedEvent = dispatch_semaphore_create(0);
    [self copyBuffer:self.canvasBuffer

        [self rebuildDisplayVertices];
    }];
    // possibly retrigger cursor rebuild
    self.cursor.display = self;
}
"""

RENDERER_FIXTURE = """\
#import "CSRenderer.h"
#import <stdatomic.h>

- (void)addRenderer:(id<CSRenderer>)renderer {
    NSArray<id<CSRenderer>> *renderers = self.renderers;
    if (![renderers containsObject:renderer]) {
        self.renderers = [renderers arrayByAddingObject:renderer];
    }
    if (!self.device) {
        self.device = renderer.device;
    } else {
        NSAssert(self.device == renderer.device, @"Cannot use two renderers from different Metal devices!");
    }
    [renderer invalidateRenderSource:self withCompletion:nil];
}
"""

PROTECTED_FIXTURE = """\
@property (nonatomic) BOOL hasInitialConfig;

/// Create a new display for a given channel and monitor
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

    def test_display_initial_frame_repaints_after_renderer_attach(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            display = root / "Sources" / "CocoaSpice" / "CSDisplay.m"
            renderer = root / "Sources" / "CocoaSpice" / "CSDisplay+Renderer.m"
            protected = root / "Sources" / "CocoaSpice" / "CSDisplay+Protected.h"
            display.parent.mkdir(parents=True)
            display.write_text(DISPLAY_FIXTURE)
            renderer.write_text(RENDERER_FIXTURE)
            protected.write_text(PROTECTED_FIXTURE)
            overlay_display_initial_frame(root)
            display_text = display.read_text()
            renderer_text = renderer.read_text()
            protected_text = protected.read_text()
            self.assertIn("repaintCurrentFramebuffer", display_text)
            self.assertIn(
                "    self.cursor.display = self;\n"
                "    if (self.isGLEnabled) {\n",
                display_text,
            )
            self.assertIn("self.canvasIsBusy", display_text)
            self.assertIn("canvasBufferOffset", display_text)
            self.assertNotIn("drawCompletedEvent", display_text)
            self.assertIn(
                "    [self rebuildDisplayVertices];\n"
                "    if (self.vertices) {\n"
                "        self.ready = YES;\n"
                "    }\n"
                "    [self drawRegion:visibleArea];\n",
                display_text,
            )
            self.assertIn("isNewRenderer", renderer_text)
            self.assertIn("#import \"CSMain.h\"", renderer_text)
            self.assertIn("repaintCurrentFramebuffer", protected_text)
            self.assertIn(
                "        [self rebuildDisplayVertices];\n"
                "        // device 就緒後才重建 cursor texture。太早呼叫時 rebuildCursorWithSize\n"
                "        // 會直接 return，hasCursor 維持 NO：滑鼠輸入正常，但 overlay 要等到\n"
                "        // guest 下次送 cursor shape 才出現。\n"
                "        self.cursor.display = self;\n"
                "    }];\n",
                display_text,
            )
            self.assertIn("self.cursor.display = self;", display_text)
            self.assertNotIn("possibly retrigger cursor rebuild", display_text)


if __name__ == "__main__":
    unittest.main()
