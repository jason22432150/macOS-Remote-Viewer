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
    overlay_metal_renderer_complete_pending_draws,
    overlay_metal_renderer_diagnostics,
    overlay_package_swift,
    overlay_renderer_protected_category,
    overlay_session_sharing_category,
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
    self.canvasData = NULL;
    self.canvasBuffer = NULL; // no more new draws
    if (self.canvasIsBusy) {
        dispatch_semaphore_wait(invalidateComplete, DISPATCH_TIME_FOREVER);
    }

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
            name: "CocoaSpiceRenderer",
            dependencies: [],
            resources: [
                .process("CSShaders.metal")]),
        .target(
            name: "CocoaSpiceNoUsb",
            cSettings: [
                .headerSearchPath("ExternalHeaders"),
                .headerSearchPath("ExternalHeaders/glib-2.0"),
                .headerSearchPath("ExternalHeaders/gstreamer-1.0"),
                .headerSearchPath("ExternalHeaders/spice-1"),
                .headerSearchPath("ExternalHeaders/spice-client-glib-2.0")]),
"""

RENDERER_PROTECTED_FIXTURE = """\
#import "CSDisplay.h"

NS_ASSUME_NONNULL_BEGIN

@interface CSDisplay (Renderer)

- (void)copyBuffer:(id<MTLBuffer>)sourceBuffer
            region:(MTLRegion)region
      sourceOffset:(NSUInteger)sourceOffset
 sourceBytesPerRow:(NSUInteger)sourceBytesPerRow
        completion:(completionCallback_t)completion;

@end

NS_ASSUME_NONNULL_END
"""

METAL_RENDERER_HEADER_FIXTURE = """\
@protocol CSRenderSource;
@protocol CSRenderer;

NS_ASSUME_NONNULL_BEGIN
@interface CSMetalRenderer : NSObject<MTKViewDelegate, CSRenderer>
@end
NS_ASSUME_NONNULL_END
"""

METAL_RENDERER_IMPL_FIXTURE = """\
@interface _CSRendererSourceData : NSObject<CSRenderSource>
- (instancetype)init NS_UNAVAILABLE;
- (nullable instancetype)initWithRenderSource:(id<CSRenderSource>)renderSource device:(id<MTLDevice>)device;
- (nullable instancetype)initWithRenderSource:(id<CSRenderSource>)renderSource atOffset:(CGPoint)offset device:(id<MTLDevice>)device NS_DESIGNATED_INITIALIZER;
@end
"""

CSRENDERER_PROTOCOL_FIXTURE = """\
#import <Foundation/Foundation.h>
@protocol CSRenderer <NSObject>
@property (nonatomic, readonly) id device;
@end
"""

SESSION_SHARING_FIXTURE = """\
@interface CSSession ()

@property (nonatomic, readwrite, nullable) SpiceSession *session;
@property (nonatomic, readonly) BOOL sessionReadOnly;
@property (nonatomic, nullable) SpiceMainChannel *main;

@end

@interface CSSession (Sharing)

- (void)createDefaultShareReadme;

@end
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
            self.assertIn("-Wno-documentation", text)
            self.assertIn('.process("CSShaders.metal")],', text)
            self.assertEqual(text.count("-Wno-documentation"), 2)

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
            self.assertIn("clippedDrawRect", display_text)
            self.assertIn("self.canvasDirtyRect = CGRectZero", display_text)
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

    def test_renderer_protected_category_is_renamed_to_avoid_duplicate(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            path = root / "Sources" / "CocoaSpice" / "CSDisplay+Renderer_Protected.h"
            path.parent.mkdir(parents=True)
            path.write_text(RENDERER_PROTECTED_FIXTURE)
            overlay_renderer_protected_category(root)
            text = path.read_text()
            self.assertIn("@interface CSDisplay (RendererProtected)", text)
            self.assertNotIn("@interface CSDisplay (Renderer)\n", text)
            self.assertIn("copyBuffer:", text)

    def test_metal_renderer_imports_protocol_and_matches_initializers(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            renderer_dir = root / "Sources" / "CocoaSpiceRenderer"
            include_dir = renderer_dir / "include"
            include_dir.mkdir(parents=True)
            (renderer_dir / "CSRenderer.h").write_text(CSRENDERER_PROTOCOL_FIXTURE)
            header = include_dir / "CSMetalRenderer.h"
            impl = renderer_dir / "CSMetalRenderer.m"
            header.write_text(METAL_RENDERER_HEADER_FIXTURE)
            impl.write_text(METAL_RENDERER_IMPL_FIXTURE)
            overlay_metal_renderer_diagnostics(root)
            header_text = header.read_text()
            impl_text = impl.read_text()
            public_protocol = (include_dir / "CSRenderer.h").read_text()
            private_protocol = (renderer_dir / "CSRenderer.h").read_text()
            self.assertIn('#import "CSRenderer.h"', header_text)
            self.assertNotIn("@protocol CSRenderer;", header_text)
            self.assertIn("#ifndef CSRenderer_h", public_protocol)
            self.assertIn("#ifndef CSRenderer_h", private_protocol)
            self.assertNotIn("device:(id<MTLDevice>)device", impl_text)
            self.assertIn(
                "initWithRenderSource:(id<CSRenderSource>)renderSource atOffset:(CGPoint)offset NS_DESIGNATED_INITIALIZER",
                impl_text,
            )

    def test_metal_renderer_completes_draw_when_disabled_or_missing_drawable(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            impl = Path(raw) / "CSMetalRenderer.m"
            impl.write_text(
                """    if (renderPassDescriptor == nil || currentDrawable == nil) {
        return;
    }

- (void)disableRender {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.renderSourceData = nil;
        self.renderNeedsUpdate = NO;
    });
}
"""
            )
            overlay_metal_renderer_complete_pending_draws(impl)
            text = impl.read_text()
            self.assertEqual(text.count("[self _completeDraw];"), 2)
            self.assertIn("沒有 drawable 也要完成 copyBuffer callback", text)
            self.assertIn("先放掉等待中的 copyBuffer completion", text)
            self.assertLess(
                text.find("[self _completeDraw];\n        self.renderSourceData = nil"),
                text.find("self.renderSourceData = nil"),
            )

    def test_session_private_sharing_category_is_renamed_to_avoid_duplicate(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            path = root / "Sources" / "CocoaSpice" / "CSSession.m"
            path.parent.mkdir(parents=True)
            path.write_text(SESSION_SHARING_FIXTURE)
            overlay_session_sharing_category(root)
            text = path.read_text()
            self.assertIn("@interface CSSession (SharingPrivate)", text)
            self.assertIn("- (void)createDefaultShareReadme;", text)
            self.assertNotIn("@interface CSSession (Sharing)\n", text)


if __name__ == "__main__":
    unittest.main()
