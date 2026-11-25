#!/usr/bin/env python3
"""overlay.py 的行為測試：Homebrew 相容 CSMain／gst_ios_init／Package.swift。"""

from __future__ import annotations

from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from overlay import (
    overlay_csmain,
    overlay_connection_pve_api,
    overlay_connection_lifecycle,
    overlay_display_initial_frame,
    overlay_gst_ios_init,
    overlay_horizontal_scroll_compatibility,
    overlay_input_release_and_secure_attention,
    overlay_metal_renderer_complete_pending_draws,
    overlay_metal_renderer_diagnostics,
    overlay_metal_frame_observation,
    overlay_metal_pixel_probe,
    overlay_package_swift,
    overlay_renderer_protected_category,
    overlay_session_sharing_category,
    overlay_clipboard_input_guards,
)

CSMAIN_FIXTURE = "//\n// Copyright © 2022 osy. All rights reserved.\n//\n// Licensed under the Apache License, Version 2.0 (the \"License\");\n// you may not use this file except in compliance with the License.\n// You may obtain a copy of the License at\n//\n//     http://www.apache.org/licenses/LICENSE-2.0\n//\n// Unless required by applicable law or agreed to in writing, software\n// distributed under the License is distributed on an \"AS IS\" BASIS,\n// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.\n// See the License for the specific language governing permissions and\n// limitations under the License.\n//\n\n#import \"CSMain.h\"\n#import <glib.h>\n#import <spice-client.h>\n#import <pthread.h>\n#import \"gst_ios_init.h\"\n\n@interface CSMain ()\n\n@property (nonatomic, readwrite) BOOL running;\n@property (nonatomic) pthread_t spiceThread;\n\n@end\n\n@interface _CSMainBlock : NSObject\n\n@property (nonatomic, copy) dispatch_block_t userBlock;\n@property (nonatomic, nullable, strong) dispatch_group_t group;\n\n@end\n\n@implementation _CSMainBlock @end\n\n@implementation CSMain {\n    GMainContext *_main_context;\n    gint _loop_quit;\n}\n\nstatic void logHandler(const gchar *log_domain, GLogLevelFlags log_level,\n                       const gchar *message, gpointer user_data)\n{\n    GDateTime *now;\n    gchar *dateTimeStr;\n    const char *glog_domains = g_getenv(\"G_MESSAGES_DEBUG\");\n    LogHandler_t handler = (__bridge LogHandler_t)user_data;\n\n    if (!spice_util_get_debug() &&\n        ((log_level & (G_LOG_LEVEL_INFO | G_LOG_LEVEL_DEBUG)) != 0)) {\n        return;\n    }\n\n    char* levelStr = \"UNKNOWN\";\n    if (log_level & G_LOG_LEVEL_ERROR) {\n        levelStr = \"ERROR\";\n    } else if (log_level & G_LOG_LEVEL_CRITICAL) {\n        levelStr = \"CRITICAL\";\n    } else if (log_level & G_LOG_LEVEL_WARNING) {\n        levelStr = \"WARNING\";\n    } else if (log_level & G_LOG_LEVEL_MESSAGE) {\n        levelStr = \"MESSAGE\";\n    } else if (log_level & G_LOG_LEVEL_INFO) {\n        levelStr = \"INFO\";\n    } else if (log_level & G_LOG_LEVEL_DEBUG) {\n        levelStr = \"DEBUG\";\n    }\n    \n    now = g_date_time_new_now_local();\n    dateTimeStr = g_date_time_format(now, \"%Y-%m-%d %T\");\n    \n    if (handler) {\n        NSString *line = [NSString stringWithFormat:@\"%s,%03d %s %s-%s\\n\", dateTimeStr,\n                          g_date_time_get_microsecond(now) / 1000, levelStr,\n                          log_domain, message];\n        handler(line);\n    } else {\n        fprintf(stdout, \"%s,%03d %s %s-%s\\n\", dateTimeStr,\n                g_date_time_get_microsecond(now) / 1000, levelStr,\n                log_domain, message);\n    }\n    \n    g_date_time_unref(now);\n    g_free(dateTimeStr);\n}\n\nvoid *spice_main_loop(void *args) {\n    CSMain *self = (__bridge_transfer CSMain *)args;\n    \n    pthread_setname_np(\"SPICE Main Loop\");\n    gst_ios_init();\n    \n    g_main_context_ref(self->_main_context);\n    g_main_context_push_thread_default(self->_main_context);\n    // Iterate manually instead of g_main_loop_run() so every dispatch runs\n    // inside an autorelease pool: SPICE callbacks autorelease Objective-C\n    // objects (one MTLBlitCommandEncoder per gl_draw, cursors, images), and\n    // this thread lives for the whole app, so without a per-iteration drain\n    // they pin device memory forever.\n    while (!g_atomic_int_get(&self->_loop_quit)) {\n        @autoreleasepool {\n            g_main_context_iteration(self->_main_context, TRUE);\n        }\n    }\n    g_main_context_pop_thread_default(self->_main_context);\n    g_main_context_unref(self->_main_context);\n    \n    return NULL;\n}\n\n+ (CSMain *)sharedInstance {\n    static CSMain *sharedInstance = nil;\n    static dispatch_once_t onceToken;\n    dispatch_once(&onceToken, ^{\n        sharedInstance = [[self alloc] init];\n    });\n    return sharedInstance;\n}\n\n- (void *)glibMainContext {\n    return _main_context;\n}\n\n- (void)setLogHandler:(LogHandler_t)newLogHandler {\n    _logHandler = newLogHandler;\n    g_log_set_default_handler(logHandler, (__bridge gpointer)newLogHandler);\n}\n\n- (id)init {\n    self = [super init];\n    if (self) {\n        if ((_main_context = g_main_context_new()) == NULL) {\n            return nil;\n        }\n        g_log_set_default_handler(logHandler, NULL);\n    }\n    return self;\n}\n\n- (void)dealloc {\n    [self spiceStop];\n    g_main_context_unref(_main_context);\n    g_log_set_default_handler(g_log_default_handler, NULL);\n}\n\n- (void)spiceSetDebug:(BOOL)enabled {\n    spice_util_set_debug(enabled);\n}\n\n- (BOOL)spiceStart {\n    @synchronized (self) {\n        if (!self.running) {\n            pthread_t spiceThread;\n            g_atomic_int_set(&_loop_quit, FALSE);\n            spice_util_set_main_context(_main_context);\n            pthread_attr_t qosAttribute;\n            pthread_attr_init(&qosAttribute);\n            pthread_attr_set_qos_class_np(&qosAttribute, QOS_CLASS_USER_INTERACTIVE, 0);\n            if (pthread_create(&spiceThread, &qosAttribute, &spice_main_loop, (__bridge_retained void *)self) != 0) {\n                return NO;\n            }\n            self.running = YES;\n            self.spiceThread = spiceThread;\n        }\n    }\n    return YES;\n}\n\n- (void)spiceStop {\n    @synchronized (self) {\n        if (self.running) {\n            void *status;\n            spice_util_set_main_context(NULL);\n            g_atomic_int_set(&_loop_quit, TRUE);\n            g_main_context_wakeup(_main_context);\n            pthread_join(self.spiceThread, &status);\n            self.running = NO;\n            self.spiceThread = NULL;\n        }\n    }\n}\n\nstatic gboolean callBlockInMainContext(gpointer data) {\n    _CSMainBlock *block = (__bridge _CSMainBlock *)data;\n    block.userBlock();\n    return FALSE;\n}\n\nstatic void cleanupBlock(gpointer data) {\n    _CSMainBlock *block = (__bridge_transfer _CSMainBlock *)data;\n    block.userBlock = nil;\n    if (block.group) {\n        dispatch_group_leave(block.group);\n    }\n}\n\n- (void)asyncWithBlock:(_CSMainBlock *)block {\n    gpointer data = (__bridge_retained void *)block;\n    g_main_context_invoke_full(self.glibMainContext,\n                               G_PRIORITY_DEFAULT,\n                               callBlockInMainContext,\n                               data,\n                               cleanupBlock);\n}\n\n- (void)asyncWith:(dispatch_block_t)block {\n    _CSMainBlock *_block = [[_CSMainBlock alloc] init];\n    _block.userBlock = block;\n    [self asyncWithBlock:_block];\n}\n\n- (void)syncWith:(dispatch_block_t)block {\n    if ([self isCurrentContextMain]) {\n        block();\n    } else {\n        _CSMainBlock *_block = [[_CSMainBlock alloc] init];\n        dispatch_group_t mainContextGroup = dispatch_group_create();\n        dispatch_group_enter(mainContextGroup);\n        _block.userBlock = block;\n        _block.group = mainContextGroup;\n        [self asyncWithBlock:_block];\n        dispatch_group_wait(mainContextGroup, DISPATCH_TIME_FOREVER);\n    }\n}\n\n- (BOOL)isCurrentContextMain {\n    return g_main_context_is_owner(self.glibMainContext);\n}\n\n@end\n"

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

    def test_clipboard_guards_preserve_release_body_variants(self) -> None:
        fixture = r"""static void cs_clipboard_got_from_guest(SpiceMainChannel *main, guint selection,
                                        guint type, const guchar *data, guint size,
                                        gpointer user_data)
{
    CSSession *self = (__bridge CSSession *)user_data;
    char *textData;

    SPICE_DEBUG("clipboard got data");
    
    if (type == VD_AGENT_CLIPBOARD_UTF8_TEXT && size > 0) {
        gchar *conv = NULL;
        /* on windows, gtk+ would already convert to LF endings, but
           not on unix */
        if (spice_main_channel_agent_test_capability(self.main, VD_AGENT_CAP_GUEST_LINEEND_CRLF)) {
            conv = spice_dos2unix((gchar*)data, size);
            size = (guint)strlen(conv);
        }
        // original data may not be null terminated
        textData = calloc(size + 1, sizeof(char));
        memcpy(textData, conv ? conv : (const char *)data, size);
        NSString *string = [NSString stringWithUTF8String:textData];
        free(textData);
        [self.pasteboardDelegate setString:string];
        g_free(conv);
    } else if (type == VD_AGENT_CLIPBOARD_UTF8_TEXT) {
        [self.pasteboardDelegate setString:@""];
    } else {
        CSPasteboardType cspbType = cspbTypeForClipboardType(type);
        NSData *pasteData = [NSData dataWithBytes:data length:size];
        [self.pasteboardDelegate setData:pasteData forType:cspbType];
    }
}

static gboolean cs_clipboard_grab(SpiceMainChannel *main, guint selection,
                                  guint32* types, guint32 ntypes,
                                  gpointer user_data)
{
    CSSession *self = (__bridge CSSession *)user_data;
    
    if (selection != VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD) {
        SPICE_DEBUG("skipping grab unimplemented selection: %d", selection);
        return FALSE;
    }

    if (self.sessionReadOnly || !self.shareClipboard) {
        SPICE_DEBUG("ignoring clipboard_grab");
        return TRUE;
    }

    g_object_ref(main);
    [CSMain.sharedInstance asyncWith:^{
        for (int n = 0; n < ntypes; ++n) {
            spice_main_channel_clipboard_selection_request(main, selection,
                                                           types[n]);
        }
        g_object_unref(main);
    }];

    return TRUE;
}

static gboolean cs_clipboard_request(SpiceMainChannel *main, guint selection,
                                     guint type, gpointer user_data)
{
    CSSession *self = (__bridge CSSession *)user_data;
    
    if (selection != VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD) {
        SPICE_DEBUG("skipping request unimplemented selection: %d", selection);
        return FALSE;
    }

    if (self.sessionReadOnly || !self.shareClipboard) {
        SPICE_DEBUG("ignoring clipboard_request");
        return FALSE;
    }

    CSPasteboardType cspbType = cspbTypeForClipboardType(type);
    NSData *data = [self.pasteboardDelegate dataForType:cspbType];
    if (data) {
        g_object_ref(main);
        [CSMain.sharedInstance asyncWith:^{
            spice_main_channel_clipboard_selection_notify(main, selection, type, data.bytes, data.length);
            g_object_unref(main);
        }];
    }

    return TRUE;
}

static void cs_clipboard_release(SpiceMainChannel *main, guint selection,
                                 gpointer user_data)
{
    CSSession *self = (__bridge CSSession *)user_data;
    [self.pasteboardDelegate clearContents];
}

static void cs_channel_new(void) {}
- (void)pasteboardDidChange:(NSNotification *)notification {
    SPICE_DEBUG("[CocoaSpice] seen UIPasteboardChangedNotification");
    if (!self.main || !self.shareClipboard || self.sessionReadOnly || !self.pasteboardDelegate) {
        return;
    }
    guint32 type = VD_AGENT_CLIPBOARD_NONE;
    id<CSPasteboardDelegate> pb = self.pasteboardDelegate;
    if ([pb canReadItemForType:kCSPasteboardTypePng]) {
        type = VD_AGENT_CLIPBOARD_IMAGE_PNG;
    } else if ([pb canReadItemForType:kCSPasteboardTypeBmp]) {
        type = VD_AGENT_CLIPBOARD_IMAGE_BMP;
    } else if ([pb canReadItemForType:kCSPasteboardTypeTiff]) {
        type = VD_AGENT_CLIPBOARD_IMAGE_TIFF;
    } else if ([pb canReadItemForType:kCSPasteboardTypeJpg]) {
        type = VD_AGENT_CLIPBOARD_IMAGE_JPG;
    } else if ([pb canReadItemForType:kCSPasteboardTypeString]) {
        type = VD_AGENT_CLIPBOARD_UTF8_TEXT;
    } else {
        SPICE_DEBUG("[CocoaSpice] pasteboard with unrecognized type");
    }
    if (spice_main_channel_agent_test_capability(self.main, VD_AGENT_CAP_CLIPBOARD_BY_DEMAND)) {
        [CSMain.sharedInstance asyncWith:^{
            guint32 _type = type;
            spice_main_channel_clipboard_selection_grab(self.main, VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD, &_type, 1);
        }];
    }
}

- (void)pasteboardDidRemove:(NSNotification *)notification {
    SPICE_DEBUG("[CocoaSpice] seen UIPasteboardRemovedNotification");
    if (!self.main || !self.shareClipboard || self.sessionReadOnly) {
        return;
    }
    if (spice_main_channel_agent_test_capability(self.main, VD_AGENT_CAP_CLIPBOARD_BY_DEMAND)) {
        [CSMain.sharedInstance asyncWith:^{
            guint32 type = VD_AGENT_CLIPBOARD_UTF8_TEXT;
            spice_main_channel_clipboard_selection_grab(self.main, VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD, &type, 1);
        }];
    }
}

"""
        for variant in ("", "    // existing release check\n"):
            with self.subTest(variant=variant), tempfile.TemporaryDirectory() as raw:
                root = Path(raw)
                path = root / "Sources" / "CocoaSpice" / "CSSession.m"
                path.parent.mkdir(parents=True)
                source = fixture.replace("    [self.pasteboardDelegate clearContents];",
                                         variant + "    [self.pasteboardDelegate clearContents];", 1)
                path.write_text(source)
                overlay_clipboard_input_guards(root)
                result = path.read_text()
                incoming = result.split("static void cs_clipboard_got_from_guest", 1)[1].split("static gboolean cs_clipboard_grab", 1)[0]
                self.assertLess(incoming.index("size > 16u * 1024u * 1024u"), incoming.index("initWithBytes:"))
                self.assertIn("g_utf8_validate", incoming)
                release = result.split("static void cs_clipboard_release", 1)[1].split("static void cs_channel_new", 1)[0]
                self.assertLess(release.index("!self.shareClipboard"), release.index("clearContents"))
                self.assertIn(variant + "    [self.pasteboardDelegate clearContents];", release)
                self.assertEqual(result.count("notification.object != self.pasteboardDelegate"), 2)

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
            self.assertIn("g_main_context_acquire(self->_main_context)", text)
            self.assertIn("dispatch_semaphore_wait(_workerReady", text)
            self.assertIn("g_source_attach(source, self.glibMainContext)", text)
            self.assertNotIn("g_main_context_invoke_full(", text)
            self.assertIn("g_main_context_release(self->_main_context)", text)
            self.assertIn("#import <pthread.h>\n#import <stdlib.h>", text)
            self.assertIn(r'ownsDefault=%d\n"', text)
            self.assertIn("MRV_GLIB_MESSAGE", text)
            self.assertNotIn("backtrace_symbols_fd(", text)

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
            with patch("overlay.pkgconfig_tokens", side_effect=[
                ["-I/fixture/include/spice", "-I/fixture/include/glib"],
                ["-L/fixture/lib", "-lspice-client-glib-2.0", "-lglib-2.0", "-lgstreamer-1.0"],
            ]) as pkgconfig:
                overlay_package_swift(root)
                self.assertEqual(pkgconfig.call_count, 2)
            text = path.read_text()
            self.assertIn("-lspice-client-glib-2.0", text)
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

    def test_frame_observation_only_reports_completed_draws(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source = root / "Sources" / "CocoaSpiceRenderer"
            header = source / "include" / "CSMetalRenderer.h"
            header.parent.mkdir(parents=True)
            header.write_text("/// Modify upscaler and downscaler settings")
            impl = source / "CSMetalRenderer.m"
            impl.write_text("""    [commandBuffer presentDrawable:currentDrawable];

    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> commandBuffer) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _completeDraw];
        });
    }];""")
            overlay_metal_frame_observation(root)
            self.assertIn("frameRenderedHandler", header.read_text())
            text = impl.read_text()
            self.assertIn("MTLCommandBufferStatusCompleted", text)
            self.assertIn("if (rendered && frameHandler)", text)
            self.assertIn("[self _completeDraw];", text)

    def test_pixel_probe_measures_gpu_interval_after_completion(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source = root / "Sources" / "CocoaSpiceRenderer"
            header = source / "include" / "CSMetalRenderer.h"
            header.parent.mkdir(parents=True)
            header.write_text("/// Modify upscaler and downscaler settings")
            (source / "CSShaders.metal").write_text("colorSample.a = 0xff;")
            impl = source / "CSMetalRenderer.m"
            impl.write_text("""    [self _renderCommand:commandBuffer
              drawSource:sourceData
    [commandBuffer presentDrawable:currentDrawable];

    // Capture the handler at submission
            if (rendered && frameHandler) {
                frameHandler();
            }""")
            overlay_metal_pixel_probe(root)
            text = impl.read_text()
            self.assertIn("uint32_t pixel, double gpuSeconds", header.read_text())
            self.assertIn("smokeRegionHandler", header.read_text())
            self.assertIn("regionHandler ? 1280 : 256", text)
            self.assertIn("destinationOffset:(i + 1) * 256", text)
            self.assertIn("regionHandler(values[0], values[1], values[2], values[3], values[4]);", text)
            self.assertIn("gpuStart > 0 && gpuEnd > gpuStart", text)
            self.assertLess(text.index("if (rendered && sampleHandler && sampleBuffer)"),
                            text.index("commandBuffer.GPUStartTime"))
            self.assertLess(text.index("commandBuffer.GPUEndTime"),
                            text.index("sampleHandler(pixel, gpuSeconds);"))

    def test_horizontal_compatibility_preserves_held_shift_and_releases_on_worker(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source = root / "Sources" / "CocoaSpice"
            header = source / "include" / "CSInput.h"
            header.parent.mkdir(parents=True)
            header.write_text("/// Sends a mouse button without moving the mouse")
            impl = source / "CSInput.m"
            impl.write_text("#import <glib.h>\n    CGFloat                 _scroll_delta_y;\n- (void)releaseKeys {\n    uint32_t i, b;\n    \n    SPICE_DEBUG(\"%s\", __FUNCTION__);\n    for (i = 0; i < SPICE_N_ELEMENTS(self->_key_state); i++) {\n        if (!self->_key_state[i]) {\n            continue;\n        }\n        for (b = 0; b < 32; b++) {\n            unsigned int scancode = i * 32 + b;\n            if (scancode != 0) {\n                [self sendKey:kCSInputKeyRelease code:scancode];\n            }\n        }\n    }\n}\n- (void)sendMouseButton:(CSInputButton)button mask:(CSInputButton)mask pressed:(BOOL)pressed {\n")
            overlay_horizontal_scroll_compatibility(root)
            self.assertIn("sendHorizontalScrollCompatibility(_:dx:)", header.read_text())
            result = impl.read_text()
            self.assertIn("if (!shiftHeld) spice_inputs_channel_key_press", result)
            self.assertIn("if (!shiftHeld) spice_inputs_channel_key_release", result)
            self.assertIn("self->_scroll_delta_x -= ticks", result)
            self.assertIn("self->_key_state[i] = 0", result)
            self.assertIn("self->_scroll_delta_y = 0", result)

    def test_secure_attention_and_pause_preserve_physical_state(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source = root / "Sources" / "CocoaSpice"
            header = source / "include" / "CSInput.h"
            header.parent.mkdir(parents=True)
            header.write_text("- (void)releaseKeys;")
            impl = source / "CSInput.m"
            impl.write_text("    uint32_t                _key_state[512 / 32];\n- (void)sendPause:(CSInputKey)type {\n    if (!self.channel) {\n        return;\n    }\n    [CSMain.sharedInstance asyncWith:^{\n        SpiceInputsChannel *inputs = self.channel;\n        /* Send proper scancodes. This will send same scancodes\n         * as hardware.\n         * The 0x21d is a sort of Third-Ctrl while\n         * 0x45 is the NumLock.\n         */\n        if (type == kCSInputKeyPress) {\n            spice_inputs_channel_key_press(inputs, 0x21d);\n            spice_inputs_channel_key_press(inputs, 0x45);\n        } else {\n            spice_inputs_channel_key_release(inputs, 0x21d);\n            spice_inputs_channel_key_release(inputs, 0x45);\n        }\n    }];\n}\n        self->_scroll_delta_x = 0;\n        self->_scroll_delta_y = 0;")
            overlay_input_release_and_secure_attention(root)
            result = impl.read_text()
            self.assertIn("sendSecureAttention", header.read_text())
            self.assertIn("if (!ctrlHeld) spice_inputs_channel_key_release", result)
            self.assertIn("if (!altHeld) spice_inputs_channel_key_release", result)
            self.assertIn("if (!deleteHeld) spice_inputs_channel_key_release", result)
            self.assertIn("if (inputs && self->_pause_down)", result)
            self.assertIn("self->_pause_down = NO", result)

    def test_connection_pve_api_uses_typed_properties_and_tls(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source = root / "Sources" / "CocoaSpice"
            header = source / "include" / "CSConnection.h"
            header.parent.mkdir(parents=True)
            header.write_text("- (BOOL)connect;")
            impl = source / "CSConnection.m"
            impl.write_text("""- (instancetype)initWithHost:(NSString *)host port:(NSString *)port {
    if (self = [super init]) {
        self.spiceSession = spice_session_new();
        self.host = host;
        self.port = port;
        [self finishInit];
    }
    return self;
}

- (BOOL)connect {
    return spice_session_connect(self.spiceSession);
}

- (void)disconnect {
    spice_session_disconnect(self.spiceSession);
}""")
            overlay_connection_pve_api(root)
            self.assertIn("configurePVEHost:", header.read_text())
            text = impl.read_text()
            self.assertIn("self.isTLSOnly = YES", text)
            self.assertIn('"port", NULL', text)
            self.assertIn("SPICE_SESSION_VERIFY_SUBJECT", text)
            self.assertIn("self.spiceMain", text)
            self.assertNotIn("valueForKey", text)
            self.assertEqual(text.count("[CSMain.sharedInstance syncWith:"), 4)
            self.assertIn("configured = YES;", text)
            self.assertIn("self.spiceSession = spice_session_new();", text)

    def test_connection_lifecycle_requires_actual_session_channel_removal(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            source = root / "Sources" / "CocoaSpice"
            header = source / "include" / "CSConnection.h"
            header.parent.mkdir(parents=True)
            header.write_text("- (BOOL)connect;")
            impl = source / "CSConnection.m"
            impl.write_text("//\n// Copyright © 2022 osy. All rights reserved.\n//\n// Licensed under the Apache License, Version 2.0 (the \"License\");\n// you may not use this file except in compliance with the License.\n// You may obtain a copy of the License at\n//\n//     http://www.apache.org/licenses/LICENSE-2.0\n//\n// Unless required by applicable law or agreed to in writing, software\n// distributed under the License is distributed on an \"AS IS\" BASIS,\n// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.\n// See the License for the specific language governing permissions and\n// limitations under the License.\n//\n\n#import \"CocoaSpice.h\"\n#import \"CSChannel+Protected.h\"\n#import \"CSCursor+Protected.h\"\n#import \"CSDisplay+Protected.h\"\n#import \"CSInput+Protected.h\"\n#import \"CSSession+Protected.h\"\n#import \"CSPort+Protected.h\"\n#if defined(WITH_USB_SUPPORT)\n#import \"CSUSBDevice+Protected.h\"\n#import \"CSUSBManager+Protected.h\"\n#endif\n#import <glib.h>\n#import <spice-client.h>\n#import <spice/vd_agent.h>\n\n@interface CSConnection ()\n\n@property (nonatomic, readwrite) BOOL isTLSOnly;\n@property (nonatomic, readwrite) CSSession *session;\n@property (nonatomic, readwrite) CSUSBManager *usbManager;\n@property (nonatomic, readwrite) NSMutableArray<CSChannel *> *mutableChannels;\n@property (nonatomic, readwrite) SpiceSession *spiceSession;\n@property (nonatomic, readwrite) SpiceMainChannel *spiceMain;\n@property (nonatomic, readwrite) SpiceAudio *spiceAudio;\n\n@end\n\n@implementation CSConnection\n\nstatic void cs_main_channel_event(SpiceChannel *channel, SpiceChannelEvent event,\n                               gpointer data)\n{\n    CSConnection *self = (__bridge CSConnection *)data;\n    const GError *error = NULL;\n    NSString *genericMsg = NSLocalizedString(@\"An error occurred trying to connect to SPICE.\", @\"CSConnection\");\n    NSInteger code = kCSConnectionErrorNone;\n    \n    switch (event) {\n        case SPICE_CHANNEL_OPENED:\n            g_message(\"main channel: opened\");\n            [self.delegate spiceConnected:self];\n            break;\n        case SPICE_CHANNEL_SWITCHING:\n            g_message(\"main channel: switching host\");\n            break;\n        case SPICE_CHANNEL_CLOSED:\n            /* this event is only sent if the channel was succesfully opened before */\n            g_message(\"main channel: closed\");\n            spice_session_disconnect(self.spiceSession);\n            break;\n        case SPICE_CHANNEL_ERROR_IO:\n        case SPICE_CHANNEL_ERROR_TLS:\n        case SPICE_CHANNEL_ERROR_LINK:\n        case SPICE_CHANNEL_ERROR_CONNECT:\n        case SPICE_CHANNEL_ERROR_AUTH:\n            error = spice_channel_get_error(channel);\n            if (error && event != SPICE_CHANNEL_ERROR_CONNECT) {\n                g_message(\"channel error: %s\", error->message);\n            }\n            switch (event) {\n                case SPICE_CHANNEL_ERROR_IO: code = kCSConnectionErrorIO; break;\n                case SPICE_CHANNEL_ERROR_TLS:\n                case SPICE_CHANNEL_ERROR_LINK:\n                case SPICE_CHANNEL_ERROR_AUTH: code = kCSConnectionErrorAuthentication; break;\n                case SPICE_CHANNEL_ERROR_CONNECT: code = kCSConnectionErrorConnect; break;\n                default: code = kCSConnectionErrorUnknown; break;\n            }\n            [self.delegate spiceError:self code:code message:(error ? [NSString stringWithUTF8String:error->message] : genericMsg)];\n            break;\n        default:\n            /* TODO: more sophisticated error handling */\n            g_warning(\"unknown main channel event: %u\", event);\n            /* connection_disconnect(conn); */\n            break;\n    }\n}\n\nstatic void cs_display_monitors(SpiceChannel *channel, GParamSpec *pspec,\n                             gpointer data)\n{\n    CSConnection *self = (__bridge CSConnection *)data;\n    GArray *cfgs = NULL;\n    CSDisplay *display = nil;\n    \n    g_object_get(channel,\n                 \"monitors\", &cfgs,\n                 NULL);\n    g_return_if_fail(cfgs != NULL);\n    \n    for (CSChannel *candidate in self.channels) {\n        if (candidate.spiceChannel == channel) {\n            assert([candidate isKindOfClass:CSDisplay.class]);\n            display = (CSDisplay *)candidate;\n            break;\n        }\n    }\n    \n    assert(display);\n    \n    SPICE_DEBUG(\"[CocoaSpice] display %ld now has %d monitors\", display.channelID, cfgs->len);\n    if (cfgs->len > 0) {\n        g_assert(cfgs->len == 1);\n        if (display.hasInitialConfig) {\n            [self.delegate spiceDisplayUpdated:self display:display];\n        } else {\n            [self.delegate spiceDisplayCreated:self display:display];\n            display.hasInitialConfig = YES;\n        }\n    } else {\n        [self.delegate spiceDisplayDestroyed:self display:display];\n    }\n    \n    g_clear_pointer(&cfgs, g_array_unref);\n}\n\nstatic void cs_main_agent_update(SpiceChannel *main, gpointer data)\n{\n    CSConnection *self = (__bridge CSConnection *)data;\n    gboolean agent_connected = false;\n    CSConnectionAgentFeature features = kCSConnectionAgentFeatureNone;\n    \n    g_object_get(main, \"agent-connected\", &agent_connected, NULL);\n    SPICE_DEBUG(\"[CocoaSpice] SPICE agent connected: %d\", agent_connected);\n    if (agent_connected) {\n        if (spice_main_channel_agent_test_capability(SPICE_MAIN_CHANNEL(main), VD_AGENT_CAP_MONITORS_CONFIG)) {\n            features |= kCSConnectionAgentFeatureMonitorsConfig;\n        }\n        [self.delegate spiceAgentConnected:self supportingFeatures:features];\n    } else {\n        [self.delegate spiceAgentDisconnected:self];\n    }\n}\n\nstatic void cs_port_opened(SpiceChannel *channel, GParamSpec *pspec,\n                           gpointer user)\n{\n    CSConnection *self = (__bridge CSConnection *)user;\n    CSPort *port = nil;\n    \n    for (CSPort *candidate in self.channels) {\n        if (candidate.spiceChannel == channel) {\n            assert([candidate isKindOfClass:CSPort.class]);\n            port = (CSPort *)candidate;\n            break;\n        }\n    }\n    \n    assert(port);\n    SPICE_DEBUG(\"[CocoaSpice] port %s opened:%d\", [port.name cStringUsingEncoding:NSASCIIStringEncoding], port.isOpen);\n\n    if (port.isOpen) {\n        [self.delegate spiceForwardedPortOpened:self port:port];\n    } else {\n        [self.delegate spiceForwardedPortClosed:self port:port];\n    }\n}\n\nstatic void cs_channel_new(SpiceSession *s, SpiceChannel *channel, gpointer data)\n{\n    CSConnection *self = (__bridge CSConnection *)data;\n    int chid;\n    \n    g_object_get(channel, \"channel-id\", &chid, NULL);\n    SPICE_DEBUG(\"new channel (#%d)\", chid);\n    \n    if (SPICE_IS_MAIN_CHANNEL(channel)) {\n        SPICE_DEBUG(\"new main channel\");\n        g_assert(!self.spiceMain); // should only be 1 main channel\n        self.spiceMain = SPICE_MAIN_CHANNEL(channel);\n        SPICE_DEBUG(\"[CocoaSpice] %s:%d\", __FUNCTION__, __LINE__);\n        g_signal_connect(channel, \"channel-event\",\n                         G_CALLBACK(cs_main_channel_event), (__bridge void *)self);\n        g_signal_connect(channel, \"main_agent_update\",\n                         G_CALLBACK(cs_main_agent_update), (__bridge void *)self);\n    }\n    \n    if (SPICE_IS_DISPLAY_CHANNEL(channel)) {\n        SPICE_DEBUG(\"new display channel (#%d)\", chid);\n        CSDisplay *display = [[CSDisplay alloc] initWithChannel:SPICE_DISPLAY_CHANNEL(channel)];\n        display.spiceMain = self.spiceMain;\n        [self.mutableChannels addObject:display];\n        g_signal_connect_after(channel, \"notify::monitors\",\n                               G_CALLBACK(cs_display_monitors), (__bridge void *)self);\n        display.isEnabled = YES;\n        // find and connect to any existing cursor channel\n        for (CSChannel *candidate in self.channels) {\n            if ([candidate isKindOfClass:CSCursor.class] && candidate.channelID == chid) {\n                CSCursor *cursor = (CSCursor *)candidate;\n                display.cursor = cursor;\n                break;\n            }\n        }\n        spice_channel_connect(channel);\n    }\n    \n    if (SPICE_IS_CURSOR_CHANNEL(channel)) {\n        SPICE_DEBUG(\"new cursor channel (#%d)\", chid);\n        CSCursor *cursor = [[CSCursor alloc] initWithChannel:SPICE_CURSOR_CHANNEL(channel)];\n        cursor.spiceMain = self.spiceMain;\n        [self.mutableChannels addObject:cursor];\n        // find and connect to any existing display channel\n        for (CSChannel *candidate in self.channels) {\n            if ([candidate isKindOfClass:CSDisplay.class] && candidate.channelID == chid) {\n                CSDisplay *display = (CSDisplay *)candidate;\n                display.cursor = cursor;\n                break;\n            }\n        }\n        spice_channel_connect(channel);\n    }\n    \n    if (SPICE_IS_INPUTS_CHANNEL(channel)) {\n        SPICE_DEBUG(\"new inputs channel\");\n        CSInput *input = [[CSInput alloc] initWithChannel:SPICE_INPUTS_CHANNEL(channel)];\n        input.spiceMain = self.spiceMain;\n        [self.mutableChannels addObject:input];\n        [self.delegate spiceInputAvailable:self input:input];\n        spice_channel_connect(channel);\n    }\n    \n    if (SPICE_IS_PLAYBACK_CHANNEL(channel)) {\n        SPICE_DEBUG(\"new audio channel\");\n        if (self.audioEnabled) {\n            self.spiceAudio = spice_audio_get(s, [CSMain sharedInstance].glibMainContext);\n            spice_channel_connect(channel);\n        } else {\n            SPICE_DEBUG(\"audio disabled\");\n        }\n    }\n\n    if (SPICE_IS_PORT_CHANNEL(channel)) {\n        SPICE_DEBUG(\"new port channel\");\n        CSPort *port = [[CSPort alloc] initWithChannel:SPICE_PORT_CHANNEL(channel)];\n        port.spiceMain = self.spiceMain;\n        port.connection = self;\n        [self.mutableChannels addObject:port];\n        g_signal_connect_after(channel, \"notify::port-opened\",\n                               G_CALLBACK(cs_port_opened), (__bridge void *)self);\n        spice_channel_connect(channel);\n    }\n}\n\nstatic void cs_channel_destroy(SpiceSession *s, SpiceChannel *channel, gpointer data)\n{\n    CSConnection *self = (__bridge CSConnection *)data;\n    int chid;\n    \n    g_object_get(channel, \"channel-id\", &chid, NULL);\n    if (SPICE_IS_MAIN_CHANNEL(channel)) {\n        SPICE_DEBUG(\"[CocoaSpice] %s:%d\", __FUNCTION__, __LINE__);\n        SPICE_DEBUG(\"zap main channel\");\n        self.spiceMain = NULL;\n        g_signal_handlers_disconnect_by_func(channel, G_CALLBACK(cs_main_channel_event), (__bridge void *)self);\n        g_signal_handlers_disconnect_by_func(channel, G_CALLBACK(cs_main_agent_update), (__bridge void *)self);\n    }\n    \n    if (SPICE_IS_DISPLAY_CHANNEL(channel)) {\n        SPICE_DEBUG(\"zap display channel (#%d)\", chid);\n        g_signal_handlers_disconnect_by_func(channel, G_CALLBACK(cs_display_monitors), (__bridge void *)self);\n    }\n    \n    if (SPICE_IS_INPUTS_CHANNEL(channel)) {\n        SPICE_DEBUG(\"zap inputs channel\");\n    }\n    \n    if (SPICE_IS_PLAYBACK_CHANNEL(channel)) {\n        SPICE_DEBUG(\"zap audio channel\");\n        self.spiceAudio = NULL;\n    }\n    \n    if (SPICE_IS_PORT_CHANNEL(channel)) {\n        g_signal_handlers_disconnect_by_func(channel, G_CALLBACK(cs_port_opened), (__bridge void *)self);\n    }\n    \n    for (NSInteger i = self.mutableChannels.count-1; i >= 0; i--) {\n        CSChannel* wrap = self.mutableChannels[i];\n        if (wrap.spiceChannel == channel) {\n            [self.mutableChannels removeObjectAtIndex:i];\n            if (SPICE_IS_DISPLAY_CHANNEL(channel)) {\n                [self.delegate spiceDisplayDestroyed:self display:(CSDisplay *)wrap];\n            } else if (SPICE_IS_PORT_CHANNEL(channel)) {\n                [self.delegate spiceForwardedPortClosed:self port:(CSPort *)wrap];\n            } else if (SPICE_IS_INPUTS_CHANNEL(channel)) {\n                [self.delegate spiceInputUnavailable:self input:(CSInput *)wrap];\n            }\n        }\n    }\n\n    // ideally we do this in cs_connection_destroy() but because that happens so late, it opens us up\n    // to retain cycles if the caller waits for `spiceDisconnect:` to cleanup.\n    if (self.channels.count == 0) {\n        [self.delegate spiceDisconnected:self];\n    }\n}\n\nstatic void cs_connection_destroy(SpiceSession *session,\n                               gpointer data)\n{\n    CSConnection *self = (__bridge CSConnection *)data;\n    SPICE_DEBUG(\"spice connection destroyed\");\n    // this happens pretty late--after every SpiceChannel has been deallocated\n}\n\n- (void)setHost:(NSString *)host {\n    g_object_set(self.spiceSession, \"host\", [host UTF8String], NULL);\n}\n\n- (NSString *)host {\n    gchar *strhost;\n    g_object_get(self.spiceSession, \"host\", &strhost, NULL);\n    NSString *nshost = [NSString stringWithUTF8String:strhost];\n    g_free(strhost);\n    return nshost;\n}\n\n- (void)setPort:(NSString *)port {\n    g_object_set(self.spiceSession, self.isTLSOnly ? \"tls-port\" : \"port\", [port UTF8String], NULL);\n}\n\n- (NSString *)port {\n    gchar *strhost;\n    g_object_get(self.spiceSession, self.isTLSOnly ? \"tls-port\" : \"port\", &strhost, NULL);\n    NSString *nshost = [NSString stringWithUTF8String:strhost];\n    g_free(strhost);\n    return nshost;\n}\n\n- (void)setUnixSocketURL:(NSURL *)unixSocketURL {\n    g_object_set(self.spiceSession, \"unix-path\", unixSocketURL.relativePath.UTF8String, NULL);\n    _unixSocketURL = unixSocketURL;\n}\n\n- (void)setTlsServerPublicKey:(NSData *)tlsServerPublicKey {\n    GByteArray *array = NULL;\n\n    if (!tlsServerPublicKey) {\n        goto end;\n    }\n    array = g_byte_array_new();\n    [tlsServerPublicKey enumerateByteRangesUsingBlock:^(const void * _Nonnull bytes, NSRange byteRange, BOOL * _Nonnull stop) {\n        g_byte_array_append(array, bytes, (guint)byteRange.length);\n    }];\n    _tlsServerPublicKey = tlsServerPublicKey;\nend:\n    g_object_set(self.spiceSession, \"pubkey\", array, NULL);\n    if (array) {\n        g_byte_array_unref(array);\n    }\n}\n\n- (NSString *)password {\n    gchar *value;\n    g_object_get(self.spiceSession, \"password\", &value, NULL);\n    if (!value) {\n        return nil;\n    }\n    NSString *nsvalue = [NSString stringWithUTF8String:value];\n    g_free(value);\n    return nsvalue;\n}\n\n- (void)setPassword:(NSString *)password {\n    g_object_set(self.spiceSession, \"password\", [password UTF8String], NULL);\n}\n\n- (NSArray<CSChannel *> *)channels {\n    return self.mutableChannels;\n}\n\n- (void)setSpiceMain:(SpiceMainChannel *)spiceMain {\n    SpiceMainChannel *old = _spiceMain;\n    _spiceMain = spiceMain ? g_object_ref(spiceMain) : NULL;\n    for (CSChannel *channel in self.channels) {\n        channel.spiceMain = spiceMain;\n    }\n    if (old) {\n        [CSMain.sharedInstance syncWith:^{\n            g_object_unref(old);\n        }];\n    }\n}\n\n- (void)dealloc {\n    SPICE_DEBUG(\"[CocoaSpice] %s:%d\", __FUNCTION__, __LINE__);\n    SpiceSession *spiceSession = self.spiceSession;\n    gpointer data = (__bridge void *)self;\n\n    [CSMain.sharedInstance syncWith:^{\n        g_signal_handlers_disconnect_by_func(spiceSession, G_CALLBACK(cs_channel_new), data);\n        g_signal_handlers_disconnect_by_func(spiceSession, G_CALLBACK(cs_channel_destroy), data);\n        g_signal_handlers_disconnect_by_func(spiceSession, G_CALLBACK(cs_connection_destroy), data);\n        for (NSInteger i = self.channels.count-1; i >= 0; i--) {\n            CSChannel* wrap = self.channels[i];\n            cs_channel_destroy(spiceSession, wrap.spiceChannel, data);\n        }\n        if (self.spiceMain) {\n            cs_channel_destroy(spiceSession, SPICE_CHANNEL(self.spiceMain), data);\n        }\n        g_object_unref(spiceSession);\n    }];\n}\n\n- (void)finishInit {\n    SPICE_DEBUG(\"[CocoaSpice] %s:%d\", __FUNCTION__, __LINE__);\n    g_signal_connect(self.spiceSession, \"channel-new\",\n                     G_CALLBACK(cs_channel_new), (__bridge void *)self);\n    g_signal_connect(self.spiceSession, \"channel-destroy\",\n                     G_CALLBACK(cs_channel_destroy), (__bridge void *)self);\n    g_signal_connect(self.spiceSession, \"disconnected\",\n                     G_CALLBACK(cs_connection_destroy), (__bridge void *)self);\n    \n#if defined(WITH_USB_SUPPORT)\n    SpiceUsbDeviceManager *manager = spice_usb_device_manager_get(self.spiceSession, NULL);\n    g_assert(manager != NULL);\n    self.usbManager = [[CSUSBManager alloc] initWithUsbDeviceManager:manager];\n#endif\n    self.session = [[CSSession alloc] initWithSession:self.spiceSession];\n    self.mutableChannels = [NSMutableArray<CSChannel *> array];\n}\n\n- (instancetype)initWithHost:(NSString *)host port:(NSString *)port {\n    if (self = [super init]) {\n        self.spiceSession = spice_session_new();\n        self.host = host;\n        self.port = port;\n        [self finishInit];\n    }\n    return self;\n}\n\n- (instancetype)initWithHost:(NSString *)host tlsPort:(NSString *)tlsPort serverPublicKey:(NSData *)serverPublicKey {\n    gchar *channels[] = { \"all\", NULL };\n\n    if (self = [super init]) {\n        self.spiceSession = spice_session_new();\n        self.isTLSOnly = YES;\n        self.host = host;\n        self.port = tlsPort;\n        self.tlsServerPublicKey = serverPublicKey;\n        g_object_set(self.spiceSession, \"secure-channels\", channels, NULL);\n        [self finishInit];\n    }\n    return self;\n}\n\n- (instancetype)initWithUnixSocketFile:(NSURL *)socketFile {\n    if (self = [super init]) {\n        self.spiceSession = spice_session_new();\n        self.unixSocketURL = socketFile;\n        [self finishInit];\n    }\n    return self;\n}\n\n- (BOOL)connect {\n    return spice_session_connect(self.spiceSession);\n}\n\n- (void)disconnect {\n    spice_session_disconnect(self.spiceSession);\n}\n\n@end\n")
            overlay_connection_pve_api(root)
            overlay_connection_lifecycle(root)
            text = impl.read_text()
            self.assertIn("GList *remaining = spice_session_get_channels(s);", text)
            self.assertIn("if (!self.spiceMain && empty && !self.disconnectNotified)", text)
            self.assertNotIn("if (self.channels.count == 0)", text)
            self.assertIn("self.disconnectNotified = NO;", text)
            self.assertIn("MRV_CONN_NEW", text)
            self.assertIn("MRV_CONN_DESTROY", text)

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
