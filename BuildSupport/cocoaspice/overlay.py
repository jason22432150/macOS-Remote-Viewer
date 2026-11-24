#!/usr/bin/env python3
"""對鎖定的 CocoaSpice checkout 套用 Homebrew 相容 overlay。"""

from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
OVERLAY = Path(__file__).resolve().parent
CHECKOUT = ROOT / "ThirdParty" / "CocoaSpice"


def overlay_gst_ios_init(checkout: Path) -> None:
    source = OVERLAY / "gst_ios_init.m"
    target = checkout / "Sources" / "CocoaSpice" / "gst_ios_init.m"
    shutil.copyfile(source, target)


def _replace_once(path: Path, replacements: list[tuple[str, str]]) -> None:
    text = path.read_text()
    for old, new in replacements:
        if old not in text:
            raise SystemExit(f"找不到 {path.name} 預期片段:\n{old}")
        text = text.replace(old, new, 1)
    path.write_text(text)


def overlay_csmain(checkout: Path) -> None:
    path = checkout / "Sources" / "CocoaSpice" / "CSMain.m"
    text = path.read_text()
    replacements = [
        (
            "    if ((_main_context = g_main_context_new()) == NULL) {",
            "    // Homebrew spice-gtk 沒有 spice_util_set_main_context，改跑 default context。\n"
            "    if ((_main_context = g_main_context_ref(g_main_context_default())) == NULL) {",
        ),
        (
            "            spice_util_set_main_context(_main_context);\n",
            "            // spice_util_set_main_context 僅存在於 UTM spice-gtk fork。\n",
        ),
        (
            "            spice_util_set_main_context(NULL);\n",
            "",
        ),
    ]
    for old, new in replacements:
        if old not in text:
            raise SystemExit(f"找不到 CSMain.m 預期片段:\n{old}")
        text = text.replace(old, new, 1)
    path.write_text(text)
    _replace_once(path, [
        ('#import <pthread.h>', '#import <pthread.h>\n#import <stdlib.h>'),
        ("""    GDateTime *now;
    gchar *dateTimeStr;""",
         """    // Opt-in test diagnostics: no connection properties, credentials or
    // remote data are emitted. Capture the offending thread before returning.
    if ((log_level & G_LOG_LEVEL_CRITICAL) && getenv("MRV_GLIB_TRACE")) {
        uint64_t tid = 0;
        pthread_threadid_np(NULL, &tid);
        fprintf(stderr, "MRV_GLIB_CRITICAL tid=%llu appkit=%d ownsDefault=%d\\n",
                (unsigned long long)tid, pthread_main_np(),
                g_main_context_is_owner(g_main_context_default()));
        // Do not unwind a stack created by makecontext/longjmp. The
        // previous diagnostic itself could fault before printing the error.
        fprintf(stderr, "MRV_GLIB_MESSAGE domain=%s message=%s\\n",
                log_domain ? log_domain : "(none)", message ? message : "(none)");
        fflush(stderr);
    }
    GDateTime *now;
    gchar *dateTimeStr;"""),
        ("    gint _loop_quit;", "    gint _loop_quit;\n    dispatch_semaphore_t _workerReady;\n    BOOL _workerOwnsContext;"),
        ("""    gst_ios_init();
    
    g_main_context_ref(self->_main_context);
    g_main_context_push_thread_default(self->_main_context);""",
         """    g_main_context_ref(self->_main_context);
    // Acquire explicitly: push_thread_default has no return value and merely
    // emits a critical on failure. Never report a worker that lacks ownership.
    if (!g_main_context_acquire(self->_main_context)) {
        self->_workerOwnsContext = NO;
        dispatch_semaphore_signal(self->_workerReady);
        g_main_context_unref(self->_main_context);
        return NULL;
    }
    g_main_context_push_thread_default(self->_main_context);
    gst_ios_init();
    self->_workerOwnsContext = YES;
    dispatch_semaphore_signal(self->_workerReady);"""),
        ("""    g_main_context_pop_thread_default(self->_main_context);
    g_main_context_unref(self->_main_context);""",
         """    g_main_context_pop_thread_default(self->_main_context);
    g_main_context_release(self->_main_context);
    g_main_context_unref(self->_main_context);"""),
        ("""            if (pthread_create(&spiceThread, &qosAttribute, &spice_main_loop, (__bridge_retained void *)self) != 0) {
                return NO;
            }
            self.running = YES;
            self.spiceThread = spiceThread;""",
         """            _workerReady = dispatch_semaphore_create(0);
            _workerOwnsContext = NO;
            void *retainedSelf = (__bridge_retained void *)self;
            int result = pthread_create(&spiceThread, &qosAttribute, &spice_main_loop, retainedSelf);
            pthread_attr_destroy(&qosAttribute);
            if (result != 0) {
                CFBridgingRelease(retainedSelf);
                return NO;
            }
            // Do not let the AppKit thread create channels until the worker
            // owns the default context and has initialized GStreamer.
            dispatch_semaphore_wait(_workerReady, DISPATCH_TIME_FOREVER);
            if (!_workerOwnsContext) {
                pthread_join(spiceThread, NULL);
                return NO;
            }
            self.running = YES;
            self.spiceThread = spiceThread;"""),
        ("""    g_main_context_invoke_full(self.glibMainContext,
                               G_PRIORITY_DEFAULT,
                               callBlockInMainContext,
                               data,
                               cleanupBlock);""",
         """    if (g_main_context_is_owner(self.glibMainContext)) {
        callBlockInMainContext(data);
        cleanupBlock(data);
        return;
    }
    // invoke_full may acquire an idle default context and execute inline on
    // the caller. Explicit attachment preserves worker-only dispatch.
    GSource *source = g_idle_source_new();
    g_source_set_priority(source, G_PRIORITY_DEFAULT);
    g_source_set_callback(source, callBlockInMainContext, data, cleanupBlock);
    g_source_attach(source, self.glibMainContext);
    g_source_unref(source);"""),
    ])


def overlay_display_initial_frame(checkout: Path) -> None:
    """第一次掛 renderer 時把完整 framebuffer 拷到 Metal，避免畫面留下黑色區塊。

    只改 `Sources/CocoaSpice/`：Xcode 的 CocoaSpiceNoUsb target 編譯這份來源
    （NoUsb 目錄是同一組檔案的 symlink）。
    """
    display = checkout / "Sources" / "CocoaSpice" / "CSDisplay.m"
    renderer = checkout / "Sources" / "CocoaSpice" / "CSDisplay+Renderer.m"
    protected = checkout / "Sources" / "CocoaSpice" / "CSDisplay+Protected.h"

    _replace_once(
        display,
        [
            (
                """- (void)updateVisibleAreaWithRect:(CGRect)rect {
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
}""",
                """- (void)updateVisibleAreaWithRect:(CGRect)rect {
    CGRect primary = self.canvasArea;
    CGRect visible = CGRectIntersection(primary, rect);
    if (CGRectIsNull(visible) || CGRectIsEmpty(visible)) {
        SPICE_DEBUG("[CocoaSpice] The monitor area is not intersecting primary surface");
        self.ready = NO;
        self.visibleArea = CGRectZero;
        self.displaySize = CGSizeZero;
        return;
    }
    self.visibleArea = visible;
    self.displaySize = self.visibleArea.size;
    // vertices 與 ready 必須在第一次 canvas blit 之前就緒，否則第一幀全畫面
    // copy 會被 renderer 丟掉，之後只剩 dirty region，畫面會留下黑色區塊。
    [self rebuildDisplayVertices];
    self.ready = YES;
    if (!self.isGLEnabled) {
        [self rebuildCanvasTexture];
    } else {
        [self invalidate];
    }
}""",
            ),
            (
                """#endif /* TARGET_OS_SIMULATOR */
    [self drawRegion:visibleArea];
}""",
                """#endif /* TARGET_OS_SIMULATOR */
    [self rebuildDisplayVertices];
    if (self.vertices) {
        self.ready = YES;
    }
    [self drawRegion:visibleArea];
}""",
            ),
            (
                """    self.canvasData = NULL;
    self.canvasBuffer = NULL; // no more new draws
    if (self.canvasIsBusy) {""",
                """    self.canvasData = NULL;
    self.canvasBuffer = NULL; // no more new draws
    // guest 改解析度會銷毀舊 surface；不可把上一張 canvas 的 dirty rect
    // 帶到新的較小 buffer，否則 didModifyRange 會超出長度並 abort。
    self.canvasDirtyRect = CGRectZero;
    if (self.canvasIsBusy) {""",
            ),
            (
                """    self.numVertices = sizeof(quadVertices) / sizeof(CSRenderVertex);
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
    [self copyBuffer:self.canvasBuffer""",
                """    self.numVertices = sizeof(quadVertices) / sizeof(CSRenderVertex);
}

/// 把目前 CPU framebuffer 完整上傳到 Metal。必須在 SPICE context 上呼叫。
- (void)repaintCurrentFramebuffer {
    // 與 canvas 同一時間點重抓 cursor shape，讓第一幀 snapshot 含 overlay。
    self.cursor.display = self;
    if (self.isGLEnabled) {
        [self invalidate];
        return;
    }
    [self rebuildDisplayVertices];
    if (!CGRectIsEmpty(self.visibleArea) && self.canvasData && self.canvasBuffer && self.vertices) {
        self.ready = YES;
        [self drawRegion:self.visibleArea];
        return;
    }
    [self invalidate];
}

/// 把 damage rect 裁成 canvas 內的整數像素。視窗自動改解析度時，
/// 上一張 surface 的 dirty region 可能比新 buffer 大。
- (CGRect)clippedDrawRect:(CGRect)rect {
    CGRect bounds = self.canvasArea;
    if (CGRectIsEmpty(bounds)) {
        return CGRectNull;
    }
    if (!CGRectIsEmpty(self.visibleArea)) {
        CGRect visible = CGRectIntersection(bounds, self.visibleArea);
        if (!CGRectIsNull(visible) && !CGRectIsEmpty(visible)) {
            bounds = visible;
        }
    }
    CGRect clipped = CGRectIntersection(rect, bounds);
    if (CGRectIsNull(clipped) || CGRectIsEmpty(clipped)) {
        return CGRectNull;
    }
    clipped = CGRectIntersection(CGRectIntegral(clipped), bounds);
    if (CGRectIsNull(clipped) || CGRectIsEmpty(clipped)) {
        return CGRectNull;
    }
    return clipped;
}

- (void)drawRegion:(CGRect)rect {
    if (!self.canvasData || !self.canvasBuffer || self.canvasStride <= 0) {
        return; // not ready to draw yet
    }
    rect = [self clippedDrawRect:rect];
    if (CGRectIsNull(rect) || CGRectIsEmpty(rect)) {
        return;
    }
    NSInteger pixelSize = (self.canvasFormat == SPICE_SURFACE_FMT_32_xRGB) ? 4 : 2;
    NSInteger x = (NSInteger)rect.origin.x;
    NSInteger y = (NSInteger)rect.origin.y;
    NSInteger width = (NSInteger)rect.size.width;
    NSInteger height = (NSInteger)rect.size.height;
    if (x < 0 || y < 0 || width <= 0 || height <= 0 || pixelSize <= 0) {
        return;
    }
    NSUInteger stride = (NSUInteger)self.canvasStride;
    NSUInteger rowBytes = (NSUInteger)width * (NSUInteger)pixelSize;
    if (rowBytes == 0 || rowBytes > stride || (NSUInteger)x > (stride - rowBytes) / (NSUInteger)pixelSize) {
        return;
    }
    NSUInteger offset = (NSUInteger)y * stride + (NSUInteger)x * (NSUInteger)pixelSize;
    NSUInteger bufferLength = self.canvasBuffer.length;
    NSUInteger maxHeight = 0;
    for (NSInteger row = 0; row < height; row++) {
        NSUInteger end = self.canvasBufferOffset + offset + (NSUInteger)row * stride + rowBytes;
        if (end > bufferLength) {
            break;
        }
        maxHeight = (NSUInteger)row + 1;
    }
    if (maxHeight == 0) {
        return;
    }
    height = (NSInteger)maxHeight;
    NSInteger destX = x - (NSInteger)self.visibleArea.origin.x;
    NSInteger destY = y - (NSInteger)self.visibleArea.origin.y;
    if (self.canvasTexture) {
        NSInteger maxWidth = (NSInteger)self.canvasTexture.width - destX;
        NSInteger maxDestHeight = (NSInteger)self.canvasTexture.height - destY;
        if (destX < 0 || destY < 0 || maxWidth <= 0 || maxDestHeight <= 0) {
            return;
        }
        if (width > maxWidth) {
            width = maxWidth;
            rowBytes = (NSUInteger)width * (NSUInteger)pixelSize;
        }
        if (height > maxDestHeight) {
            height = maxDestHeight;
        }
    }
    if (self.canvasIsBusy) {
        rect.size.width = width;
        rect.size.height = height;
        self.canvasDirtyRect = CGRectUnion(self.canvasDirtyRect, rect);
        return;
    }
    self.canvasIsBusy = YES;
    MTLRegion region = {
        { destX, destY, 0 },
        { width, height, 1 }
    };
#if TARGET_OS_OSX || TARGET_OS_SIMULATOR
    for (NSUInteger i = 0; i < (NSUInteger)height; i++) {
        NSUInteger location = self.canvasBufferOffset + offset + i * stride;
#if TARGET_OS_SIMULATOR
        memcpy(self.canvasBuffer.contents + location,
               self.canvasData + offset + i * stride,
               rowBytes);
#else /* !TARGET_OS_SIMULATOR */
        [self.canvasBuffer didModifyRange:NSMakeRange(location, rowBytes)];
#endif /* TARGET_OS_SIMULATOR */
    }
#endif
    [self copyBuffer:self.canvasBuffer""",
            ),
            (
                """        [self rebuildDisplayVertices];
    }];
    // possibly retrigger cursor rebuild
    self.cursor.display = self;
}""",
                """        [self rebuildDisplayVertices];
        // device 就緒後才重建 cursor texture。太早呼叫時 rebuildCursorWithSize
        // 會直接 return，hasCursor 維持 NO：滑鼠輸入正常，但 overlay 要等到
        // guest 下次送 cursor shape 才出現。
        self.cursor.display = self;
    }];
}""",
            ),
        ],
    )

    _replace_once(
        renderer,
        [
            (
                """#import "CSRenderer.h"
#import <stdatomic.h>""",
                """#import "CSRenderer.h"
#import "CSMain.h"
#import <stdatomic.h>""",
            ),
            (
                """- (void)addRenderer:(id<CSRenderer>)renderer {
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
}""",
                """- (void)addRenderer:(id<CSRenderer>)renderer {
    NSArray<id<CSRenderer>> *renderers = self.renderers;
    BOOL isNewRenderer = ![renderers containsObject:renderer];
    if (isNewRenderer) {
        self.renderers = [renderers arrayByAddingObject:renderer];
    }
    BOOL needsDevice = (self.device == nil);
    if (needsDevice) {
        self.device = renderer.device;
    } else {
        NSAssert(self.device == renderer.device, @"Cannot use two renderers from different Metal devices!");
    }
    if (isNewRenderer || needsDevice) {
        // setDevice 是丟到 SPICE thread 的 async；必須在同一條 queue 再拷一次
        // 目前 framebuffer，否則 Metal texture 可能只有後來的 dirty tiles。
        [CSMain.sharedInstance asyncWith:^{
            [self repaintCurrentFramebuffer];
        }];
    } else {
        [renderer invalidateRenderSource:self withCompletion:nil];
    }
}""",
            ),
        ],
    )

    _replace_once(
        protected,
        [
            (
                """@property (nonatomic) BOOL hasInitialConfig;

/// Create a new display for a given channel and monitor""",
                """@property (nonatomic) BOOL hasInitialConfig;

/// 在 renderer／device 就緒後，把目前 framebuffer 完整呈現一次。
- (void)repaintCurrentFramebuffer;

/// Create a new display for a given channel and monitor""",
            ),
        ],
    )


def pkgconfig_tokens(*args: str) -> list[str]:
    output = subprocess.check_output(["pkg-config", *args], text=True)
    return [token for token in output.split() if token]


def swift_string_list(values: list[str]) -> str:
    inner = ", ".join(f'"{item}"' for item in values)
    return f"[{inner}]"


def overlay_renderer_protected_category(checkout: Path) -> None:
    """公開 header 已宣告 `CSDisplay (Renderer)`；內部 header 必須用不同 category 名稱。"""
    path = checkout / "Sources" / "CocoaSpice" / "CSDisplay+Renderer_Protected.h"
    _replace_once(
        path,
        [
            (
                "@interface CSDisplay (Renderer)\n",
                "@interface CSDisplay (RendererProtected)\n",
            )
        ],
    )


def overlay_metal_renderer_diagnostics(checkout: Path) -> None:
    """消除 CocoaSpiceRenderer 在 Xcode Issues 出現的協議／initializer 警告。

    公開 header 不能只 forward-declare `CSRenderer` 就去 conform；
    `_CSRendererSourceData` 的介面多了未實作的 `device:` 參數。
    """
    header = checkout / "Sources" / "CocoaSpiceRenderer" / "include" / "CSMetalRenderer.h"
    impl = checkout / "Sources" / "CocoaSpiceRenderer" / "CSMetalRenderer.m"
    protocol_header = checkout / "Sources" / "CocoaSpiceRenderer" / "CSRenderer.h"
    public_protocol_header = checkout / "Sources" / "CocoaSpiceRenderer" / "include" / "CSRenderer.h"
    for path in (header, impl, protocol_header):
        if not path.is_file():
            raise SystemExit(f"找不到 {path}")

    text = protocol_header.read_text()
    if "#ifndef CSRenderer_h" not in text:
        protocol_header.write_text(
            "#ifndef CSRenderer_h\n#define CSRenderer_h\n\n" + text.rstrip() + "\n\n#endif /* CSRenderer_h */\n"
        )
    shutil.copyfile(protocol_header, public_protocol_header)

    _replace_once(
        header,
        [
            (
                "@protocol CSRenderSource;\n@protocol CSRenderer;\n",
                '#import "CSRenderer.h"\n@protocol CSRenderSource;\n',
            )
        ],
    )
    _replace_once(
        impl,
        [
            (
                "- (instancetype)init NS_UNAVAILABLE;\n"
                "- (nullable instancetype)initWithRenderSource:(id<CSRenderSource>)renderSource device:(id<MTLDevice>)device;\n"
                "- (nullable instancetype)initWithRenderSource:(id<CSRenderSource>)renderSource atOffset:(CGPoint)offset device:(id<MTLDevice>)device NS_DESIGNATED_INITIALIZER;",
                "- (instancetype)init NS_UNAVAILABLE;\n"
                "- (nullable instancetype)initWithRenderSource:(id<CSRenderSource>)renderSource;\n"
                "- (nullable instancetype)initWithRenderSource:(id<CSRenderSource>)renderSource atOffset:(CGPoint)offset NS_DESIGNATED_INITIALIZER;",
            )
        ],
    )


def overlay_metal_renderer_complete_pending_draws(impl: Path) -> None:
    """copyBuffer completion 綁在下一次 draw；沒 drawable 或 disableRender 時必須立刻放掉。"""
    _replace_once(
        impl,
        [
            (
                """    if (renderPassDescriptor == nil || currentDrawable == nil) {
        return;
    }""",
                """    if (renderPassDescriptor == nil || currentDrawable == nil) {
        // 沒有 drawable 也要完成 copyBuffer callback，否則共用 spice thread 會卡住所有連線。
        [self _completeDraw];
        return;
    }""",
            ),
            (
                """- (void)disableRender {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.renderSourceData = nil;
        self.renderNeedsUpdate = NO;
    });
}""",
                """- (void)disableRender {
    dispatch_async(dispatch_get_main_queue(), ^{
        // 先放掉等待中的 copyBuffer completion，再清畫面狀態。
        [self _completeDraw];
        self.renderSourceData = nil;
        self.renderNeedsUpdate = NO;
    });
}""",
            ),
        ],
    )


def overlay_metal_frame_observation(checkout: Path) -> None:
    """Notify only after a real draw command buffer completes successfully."""
    root = checkout / "Sources" / "CocoaSpiceRenderer"
    _replace_once(root / "include" / "CSMetalRenderer.h", [
        ("/// Modify upscaler and downscaler settings",
         "/// Optional callback on the main queue after a successful GPU draw. Set on main.\n"
         "@property (nonatomic, copy, nullable) void (^frameRenderedHandler)(void);\n\n"
         "/// Modify upscaler and downscaler settings"),
    ])
    _replace_once(root / "CSMetalRenderer.m", [
        ("""    [commandBuffer presentDrawable:currentDrawable];

    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> commandBuffer) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _completeDraw];
        });
    }];""",
         """    [commandBuffer presentDrawable:currentDrawable];

    // Capture the handler at submission, never read a newer session's handler
    // when an older GPU command buffer completes.
    void (^frameHandler)(void) = self.frameRenderedHandler;
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> commandBuffer) {
        BOOL rendered = commandBuffer.status == MTLCommandBufferStatusCompleted;
        dispatch_async(dispatch_get_main_queue(), ^{
            [self _completeDraw];
            if (rendered && frameHandler) {
                frameHandler();
            }
        });
    }];"""),
    ])


def overlay_connection_pve_api(checkout: Path) -> None:
    """Expose a typed PVE configuration API inside the pinned CocoaSpice implementation."""
    source = checkout / "Sources" / "CocoaSpice"
    header = source / "include" / "CSConnection.h"
    impl = source / "CSConnection.m"
    declaration = """/// Configure a CA-verified, TLS-only PVE connection before connect.
- (BOOL)configurePVEHost:(NSString *)host
                 tlsPort:(NSString *)tlsPort
                   proxy:(nullable NSString *)proxy
                      ca:(NSData *)ca
             certSubject:(NSString *)subject
                password:(NSString *)password;
/// Query on the SPICE worker when the agent capability callback fires.
- (BOOL)hasPVEClipboardCapability;

"""
    implementation = """- (BOOL)configurePVEHost:(NSString *)host
                 tlsPort:(NSString *)tlsPort
                   proxy:(NSString *)proxy
                      ca:(NSData *)ca
             certSubject:(NSString *)subject
                password:(NSString *)password
{
    if (!host.length || !tlsPort.length || !ca.length || !subject.length) {
        return NO;
    }
    __block BOOL configured = NO;
    [CSMain.sharedInstance syncWith:^{
        if (!self.spiceSession) return;
        self.isTLSOnly = YES;
        gchar *channels[] = { "all", NULL };
        g_object_set(self.spiceSession,
                 "host", host.UTF8String,
                 "tls-port", tlsPort.UTF8String,
                 "port", NULL,
                 "password", password.UTF8String,
                 "cert-subject", subject.UTF8String,
                 "secure-channels", channels,
                 "enable-audio", FALSE,
                 "enable-usbredir", FALSE,
                 "verify", SPICE_SESSION_VERIFY_SUBJECT,
                 "proxy", proxy.length ? proxy.UTF8String : NULL,
                 "pubkey", NULL,
                 NULL);
        GByteArray *caArray = g_byte_array_new();
        g_byte_array_append(caArray, ca.bytes, (guint)ca.length);
        g_object_set(self.spiceSession, "ca", caArray, NULL);
        g_byte_array_unref(caArray);
        configured = YES;
    }];
    return configured;
}

- (BOOL)hasPVEClipboardCapability {
    return self.spiceMain &&
        spice_main_channel_agent_test_capability(self.spiceMain, VD_AGENT_CAP_CLIPBOARD_BY_DEMAND);
}

"""
    _replace_once(header, [("- (BOOL)connect;", declaration + "- (BOOL)connect;")])
    _replace_once(impl, [
        ("""- (instancetype)initWithHost:(NSString *)host port:(NSString *)port {
    if (self = [super init]) {
        self.spiceSession = spice_session_new();
        self.host = host;
        self.port = port;
        [self finishInit];
    }
    return self;
}""",
         """- (instancetype)initWithHost:(NSString *)host port:(NSString *)port {
    if (self = [super init]) {
        // The PVE adapter uses this initializer after spiceStart succeeds.
        [CSMain.sharedInstance syncWith:^{
            self.spiceSession = spice_session_new();
            self.host = host;
            self.port = port;
            [self finishInit];
        }];
    }
    return self;
}"""),
        ("""- (BOOL)connect {
    return spice_session_connect(self.spiceSession);
}

- (void)disconnect {
    spice_session_disconnect(self.spiceSession);
}""",
         implementation + """- (BOOL)connect {
    // Channel creation and coroutine scheduling must share the GLib context.
    __block BOOL initiated = NO;
    [CSMain.sharedInstance syncWith:^{
        initiated = spice_session_connect(self.spiceSession);
    }];
    return initiated;
}

- (void)disconnect {
    [CSMain.sharedInstance syncWith:^{
        spice_session_disconnect(self.spiceSession);
    }];
}"""),
    ])


def overlay_session_sharing_category(checkout: Path) -> None:
    """`CSSession.m` 私有 `(Sharing)` 與公開 `CSSession+Sharing.h` 同名，會 duplicate category。

    `SharingPrivate` 只讓 `CSSession.m` 編譯期看得到 `-createDefaultShareReadme`；
    方法仍實作在 `CSSession+Sharing.m` 的公開 `(Sharing)` category。
    """
    path = checkout / "Sources" / "CocoaSpice" / "CSSession.m"
    _replace_once(
        path,
        [
            (
                "@interface CSSession (Sharing)\n",
                "@interface CSSession (SharingPrivate)\n",
            )
        ],
    )


def overlay_package_swift(checkout: Path) -> None:
    path = checkout / "Package.swift"
    text = path.read_text()
    marker = '.headerSearchPath("ExternalHeaders/spice-client-glib-2.0")]),'
    if marker not in text:
        raise SystemExit("找不到 Package.swift 的 CocoaSpice cSettings 結尾")

    # Homebrew GLib／spice-gtk header 的 Doxygen 標記會灌爆 Xcode Issues。
    cflags = pkgconfig_tokens("--cflags", "spice-client-glib-2.0", "glib-2.0", "gstreamer-1.0")
    cflags.append("-Wno-documentation")
    libs = pkgconfig_tokens("--libs", "spice-client-glib-2.0", "glib-2.0", "gstreamer-1.0")
    replacement = (
        '.headerSearchPath("ExternalHeaders/spice-client-glib-2.0"),\n'
        f"                .unsafeFlags({swift_string_list(cflags)})],\n"
        "            linkerSettings: [\n"
        f"                .unsafeFlags({swift_string_list(libs)})]),"
    )
    text = text.replace(marker, replacement, 1)

    renderer_marker = (
        '            resources: [\n'
        '                .process("CSShaders.metal")]),'
    )
    if renderer_marker not in text:
        raise SystemExit("找不到 Package.swift 的 CocoaSpiceRenderer resources 結尾")
    text = text.replace(
        renderer_marker,
        '            resources: [\n'
        '                .process("CSShaders.metal")],\n'
        "            cSettings: [\n"
        '                .unsafeFlags(["-Wno-documentation"])]),',
        1,
    )
    path.write_text(text)


def overlay_horizontal_scroll_compatibility(checkout: Path) -> None:
    """Shift+wheel compatibility, atomic on the GLib context and preserving held Shift."""
    source = checkout / "Sources" / "CocoaSpice"
    header = source / "include" / "CSInput.h"
    impl = source / "CSInput.m"
    _replace_once(header, [
        ("/// Sends a mouse button without moving the mouse",
         "/// Opt-in Shift+wheel compatibility; not a native horizontal scroll event.\n"
         "- (void)sendHorizontalScrollCompatibility:(CSInputButton)buttonMask dx:(CGFloat)dx "
         "NS_SWIFT_NAME(sendHorizontalScrollCompatibility(_:dx:));\n\n"
         "/// Sends a mouse button without moving the mouse"),
    ])
    _replace_once(impl, [
        ("    CGFloat                 _scroll_delta_y;",
         "    CGFloat                 _scroll_delta_y;\n    CGFloat                 _scroll_delta_x;"),
        ("- (void)sendMouseButton:(CSInputButton)button mask:(CSInputButton)mask pressed:(BOOL)pressed {",
         """- (void)sendHorizontalScrollCompatibility:(CSInputButton)buttonMask dx:(CGFloat)dx {
    if (!isfinite(dx) || !self.channel || self.disableInputs) return;
    gint button_state = cs_button_mask_to_spice(buttonMask);
    [CSMain.sharedInstance asyncWith:^{
        SpiceInputsChannel *inputs = self.channel;
        if (!inputs || self.disableInputs) return;
        // Physical modifiers are tracked on this same context. Avoid Ctrl/Alt/Super combinations.
        const unsigned int modifiers[] = {0x1d, 0x11d, 0x38, 0x138, 0x15b, 0x15c};
        for (unsigned int i = 0; i < G_N_ELEMENTS(modifiers); i++) {
            unsigned int key = modifiers[i];
            if (self->_key_state[key / 32] & (1u << (key % 32))) {
                self->_scroll_delta_x = 0;
                return;
            }
        }
        self->_scroll_delta_x += CLAMP(dx, -64.0, 64.0);
        int ticks = (int)self->_scroll_delta_x;
        if (!ticks) return;
        self->_scroll_delta_x -= ticks;
        BOOL shiftHeld = (self->_key_state[0x2a / 32] & (1u << (0x2a % 32))) ||
                         (self->_key_state[0x36 / 32] & (1u << (0x36 % 32)));
        if (!shiftHeld) spice_inputs_channel_key_press(inputs, 0x2a);
        int button = ticks < 0 ? SPICE_MOUSE_BUTTON_UP : SPICE_MOUSE_BUTTON_DOWN;
        for (int i = 0; i < ABS(ticks); i++) {
            spice_inputs_channel_button_press(inputs, button, button_state);
            spice_inputs_channel_button_release(inputs, button, button_state);
        }
        if (!shiftHeld) spice_inputs_channel_key_release(inputs, 0x2a);
    }];
}

- (void)sendMouseButton:(CSInputButton)button mask:(CSInputButton)mask pressed:(BOOL)pressed {"""),
        ("""- (void)releaseKeys {
    uint32_t i, b;
    
    SPICE_DEBUG("%s", __FUNCTION__);
    for (i = 0; i < SPICE_N_ELEMENTS(self->_key_state); i++) {
        if (!self->_key_state[i]) {
            continue;
        }
        for (b = 0; b < 32; b++) {
            unsigned int scancode = i * 32 + b;
            if (scancode != 0) {
                [self sendKey:kCSInputKeyRelease code:scancode];
            }
        }
    }
}""",
         """- (void)releaseKeys {
    // Read and clear key state on the same GLib context as queued key presses.
    [CSMain.sharedInstance asyncWith:^{
        SpiceInputsChannel *inputs = self.channel;
        for (unsigned int i = 0; i < SPICE_N_ELEMENTS(self->_key_state); i++) {
            for (unsigned int b = 0; b < 32; b++) {
                unsigned int key = i * 32 + b;
                if (inputs && key && (self->_key_state[i] & (1u << b))) {
                    spice_inputs_channel_key_release(inputs, key);
                }
            }
            self->_key_state[i] = 0;
        }
        self->_scroll_delta_x = 0;
        self->_scroll_delta_y = 0;
    }];
}"""),
        ("#import <glib.h>", "#import <glib.h>\n#import <math.h>"),
    ])


def overlay_input_release_and_secure_attention(checkout: Path) -> None:
    """Keep Pause and synthetic secure attention ordered with physical key events."""
    source = checkout / "Sources" / "CocoaSpice"
    header = source / "include" / "CSInput.h"
    impl = source / "CSInput.m"
    _replace_once(header, [
        ("- (void)releaseKeys;", "- (void)releaseKeys;\n\n"
         "/// Send Ctrl+Alt+Delete without releasing physically held modifiers.\n"
         "- (void)sendSecureAttention;\n"),
    ])
    _replace_once(impl, [
        ("    uint32_t                _key_state[512 / 32];",
         "    uint32_t                _key_state[512 / 32];\n    BOOL                    _pause_down;"),
        ("- (void)sendPause:(CSInputKey)type {\n    if (!self.channel) {\n        return;\n    }\n    [CSMain.sharedInstance asyncWith:^{\n        SpiceInputsChannel *inputs = self.channel;\n        /* Send proper scancodes. This will send same scancodes\n         * as hardware.\n         * The 0x21d is a sort of Third-Ctrl while\n         * 0x45 is the NumLock.\n         */\n        if (type == kCSInputKeyPress) {\n            spice_inputs_channel_key_press(inputs, 0x21d);\n            spice_inputs_channel_key_press(inputs, 0x45);\n        } else {\n            spice_inputs_channel_key_release(inputs, 0x21d);\n            spice_inputs_channel_key_release(inputs, 0x45);\n        }\n    }];\n}",
         """- (void)sendPause:(CSInputKey)type {
    if (!self.channel || self.disableInputs) return;
    [CSMain.sharedInstance asyncWith:^{
        SpiceInputsChannel *inputs = self.channel;
        if (!inputs || self.disableInputs) return;
        BOOL pressed = type == kCSInputKeyPress;
        if (self->_pause_down == pressed) return;
        self->_pause_down = pressed;
        if (pressed) {
            spice_inputs_channel_key_press(inputs, 0x21d);
            spice_inputs_channel_key_press(inputs, 0x45);
        } else {
            spice_inputs_channel_key_release(inputs, 0x21d);
            spice_inputs_channel_key_release(inputs, 0x45);
        }
    }];
}

- (void)sendSecureAttention {
    if (!self.channel || self.disableInputs) return;
    [CSMain.sharedInstance asyncWith:^{
        SpiceInputsChannel *inputs = self.channel;
        if (!inputs || self.disableInputs) return;
        BOOL ctrlHeld = (self->_key_state[0x1d / 32] & (1u << (0x1d % 32))) ||
                        (self->_key_state[0x11d / 32] & (1u << (0x11d % 32)));
        BOOL altHeld = (self->_key_state[0x38 / 32] & (1u << (0x38 % 32))) ||
                       (self->_key_state[0x138 / 32] & (1u << (0x138 % 32)));
        BOOL deleteHeld = self->_key_state[0x153 / 32] & (1u << (0x153 % 32));
        if (!ctrlHeld) spice_inputs_channel_key_press(inputs, 0x1d);
        if (!altHeld) spice_inputs_channel_key_press(inputs, 0x38);
        spice_inputs_channel_key_press(inputs, 0x153);
        if (!deleteHeld) spice_inputs_channel_key_release(inputs, 0x153);
        if (!altHeld) spice_inputs_channel_key_release(inputs, 0x38);
        if (!ctrlHeld) spice_inputs_channel_key_release(inputs, 0x1d);
    }];
}"""),
        ("        self->_scroll_delta_x = 0;\n        self->_scroll_delta_y = 0;",
         """        if (inputs && self->_pause_down) {
            spice_inputs_channel_key_release(inputs, 0x21d);
            spice_inputs_channel_key_release(inputs, 0x45);
        }
        self->_pause_down = NO;
        self->_scroll_delta_x = 0;
        self->_scroll_delta_y = 0;"""),
    ])


def overlay_canvas_gpu_lifetime(checkout: Path) -> None:
    """Own CPU staging memory; never wait for an AppKit draw on the GLib worker."""
    display = checkout / "Sources" / "CocoaSpice" / "CSDisplay.m"
    metal = checkout / "Sources" / "CocoaSpiceRenderer" / "CSMetalRenderer.m"
    _replace_once(display, [
        ('#import "CSDisplay+Renderer_Protected.h"', '#import "CSDisplay+Renderer_Protected.h"\n#import <math.h>'),
        ("""    if (self.canvasIsBusy) {
        dispatch_semaphore_t invalidateComplete = dispatch_semaphore_create(0);
        [self invalidateWithCompletion:^{
            dispatch_semaphore_signal(invalidateComplete);
        }];
        dispatch_semaphore_wait(invalidateComplete, DISPATCH_TIME_FOREVER);
    }
    [self disableScanout];""",
         """    // Staging buffers are Metal-owned, not aliases of SPICE surface memory.
    // An in-flight GPU command retains its old buffer; no UI-thread wait is needed.
    self.canvasIsBusy = NO;
    self.canvasTexture = nil;
    [self disableScanout];"""),
        ("""    MTLTextureDescriptor *textureDescriptor = [[MTLTextureDescriptor alloc] init];
    // don't worry that that components are reversed, we fix it in shaders""",
         """    // Bound allocation before converting dimensions or multiplying stride.
    const NSUInteger maxCanvasBytes = 256u * 1024u * 1024u;
    if (!self.canvasData || self.canvasStride <= 0 ||
        !isfinite(self.canvasArea.size.height) || self.canvasArea.size.height < 1 ||
        self.canvasArea.size.height > 16384 ||
        !isfinite(visibleArea.size.width) || !isfinite(visibleArea.size.height) ||
        visibleArea.size.width < 1 || visibleArea.size.width > 16384 ||
        visibleArea.size.height < 1 || visibleArea.size.height > 16384 ||
        (NSUInteger)self.canvasStride > maxCanvasBytes / (NSUInteger)self.canvasArea.size.height ||
        (NSUInteger)visibleArea.size.width > maxCanvasBytes / 4 / (NSUInteger)visibleArea.size.height) {
        return;
    }
    NSUInteger canvasSize = (NSUInteger)self.canvasStride * (NSUInteger)self.canvasArea.size.height;
    MTLTextureDescriptor *textureDescriptor = [[MTLTextureDescriptor alloc] init];
    // don't worry that that components are reversed, we fix it in shaders"""),
        ("""    self.canvasTexture = [self.device newTextureWithDescriptor:textureDescriptor];
    uintptr_t canvasDataAligned = trunc_page_kernel((uintptr_t)self.canvasData);
    NSUInteger canvasSize = self.canvasStride * self.canvasArea.size.height;
    if (!canvasDataAligned || !canvasSize) {
        return; // it will be freed
    }
#if TARGET_OS_SIMULATOR
    self.canvasBuffer = [self.device newBufferWithBytes:(void *)self.canvasData
                                                 length:canvasSize
                                                options:0];
#else /* !TARGET_OS_SIMULATOR */
    // round size up to multiple of page size
    self.canvasBufferOffset = ((uintptr_t)self.canvasData - canvasDataAligned);
    canvasSize += self.canvasBufferOffset;
    canvasSize = round_page_kernel(canvasSize);
    self.canvasBuffer = [self.device newBufferWithBytesNoCopy:(void *)canvasDataAligned
                                                       length:canvasSize
#if TARGET_OS_OSX
                                                      options:MTLResourceStorageModeManaged
#else
                                                      options:MTLResourceCPUCacheModeWriteCombined
#endif
                                                  deallocator:nil];
#endif /* TARGET_OS_SIMULATOR */""",
         """    id<MTLTexture> texture = [self.device newTextureWithDescriptor:textureDescriptor];
    id<MTLBuffer> buffer = [self.device newBufferWithLength:canvasSize
                                                   options:MTLResourceStorageModeShared];
    if (!texture || !buffer) {
        self.ready = NO;
        self.canvasBuffer = nil;
        self.canvasTexture = nil;
        self.canvasIsBusy = NO;
        self.canvasDirtyRect = CGRectZero;
        return;
    }
    // A new staging generation must not inherit busy/dirty state from the old surface.
    self.canvasIsBusy = NO;
    self.canvasDirtyRect = CGRectZero;
    self.canvasTexture = texture;
    self.canvasBufferOffset = 0;
    self.canvasBuffer = buffer;"""),
        ("""#if TARGET_OS_OSX || TARGET_OS_SIMULATOR
    for (NSUInteger i = 0; i < (NSUInteger)height; i++) {
        NSUInteger location = self.canvasBufferOffset + offset + i * stride;
#if TARGET_OS_SIMULATOR
        memcpy(self.canvasBuffer.contents + location,
               self.canvasData + offset + i * stride,
               rowBytes);
#else /* !TARGET_OS_SIMULATOR */
        [self.canvasBuffer didModifyRange:NSMakeRange(location, rowBytes)];
#endif /* TARGET_OS_SIMULATOR */
    }
#endif
    [self copyBuffer:self.canvasBuffer""",
         """    id<MTLBuffer> submittedBuffer = self.canvasBuffer;
    for (NSUInteger i = 0; i < (NSUInteger)height; i++) {
        NSUInteger location = offset + i * stride;
        memcpy((uint8_t *)submittedBuffer.contents + location,
               (const uint8_t *)self.canvasData + location, rowBytes);
    }
    [self copyBuffer:submittedBuffer"""),
        ("""        [CSMain.sharedInstance asyncWith:^{
            CGRect dirtyRect = self.canvasDirtyRect;
            self.canvasDirtyRect = CGRectZero;
            self.canvasIsBusy = NO;""",
         """        [CSMain.sharedInstance asyncWith:^{
            // A late completion must not clear the busy bit of a new surface.
            if (self.canvasBuffer != submittedBuffer) return;
            CGRect dirtyRect = self.canvasDirtyRect;
            self.canvasDirtyRect = CGRectZero;
            self.canvasIsBusy = NO;"""),
    ])
    _replace_once(metal, [
        ("""    id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];
    blitEncoder.label = @"Renderer Canvas Updates";""",
         """    id<MTLBlitCommandEncoder> blitEncoder = [commandBuffer blitCommandEncoder];
    if (!blitEncoder) {
        if (completion) completion();
        return;
    }
    blitEncoder.label = @"Renderer Canvas Updates";"""),
        ("""    [blitEncoder endEncoding];

    [commandBuffer commit];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (completion) {
            [self _addDrawCompletion:completion];
        }
        self.renderSourceData = sourceData;
        self.renderNeedsUpdate = YES;
    });""",
         """    [blitEncoder endEncoding];

    // CPU staging memory may be reused after the GPU finishes reading it.
    // Main-queue delivery bounds queued publications to one per active canvas.
    // No drawable or next draw is required, and the GLib worker never waits on it.
    if (completion) {
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> finished) {
            dispatch_async(dispatch_get_main_queue(), completion);
        }];
    }
    [commandBuffer commit];

    dispatch_async(dispatch_get_main_queue(), ^{
        self.renderSourceData = sourceData;
        self.renderNeedsUpdate = YES;
    });"""),
        ("""    void (^frameHandler)(void) = self.frameRenderedHandler;
    [commandBuffer addCompletedHandler:""",
         """    void (^frameHandler)(void) = self.frameRenderedHandler;
    // Transfer only callbacks submitted with this draw. An older GPU completion
    // must not drain callbacks added by a newer frame.
    NSArray<completionCallback_t> *submittedCompletions = [self.renderCompletions copy];
    [self.renderCompletions removeAllObjects];
    [commandBuffer addCompletedHandler:"""),
        ("""            [self _completeDraw];
            if (rendered && frameHandler)""",
         """            for (completionCallback_t completion in submittedCompletions) {
                completion();
            }
            if (rendered && frameHandler)"""),
    ])


def overlay_scanout_ownership(checkout: Path) -> None:
    """Never publish a server-owned IOSurface; fence stale GPU copies."""
    display = checkout / "Sources" / "CocoaSpice" / "CSDisplay.m"
    _replace_once(display, [
        ("@property (nonatomic) BOOL shadowNeedsFullCopy;",
         "@property (nonatomic) BOOL shadowNeedsFullCopy;\n"
         "@property (nonatomic, nullable) id<MTLCommandQueue> shadowQueue;\n"
         "- (void)resetScanout;"),
        ("""    self.shadowTexture = nil;
    self.presentTexture = nil;
}""",
         """    [self resetScanout];
}"""),
        ("""    /* should only be called when the display has a scanout */
    g_return_if_fail(scanout != NULL);
    
    self.isGLEnabled = YES;""",
         """    if (!scanout) {
        [self resetScanout];
        return;
    }
    self.isGLEnabled = YES;"""),
        ("""        // the shadow buffer belongs to the old device
        self.shadowTexture = nil;
        self.presentTexture = nil;""",
         """        // The shadow allocation belongs to the old device/queue.
        self.shadowTexture = nil;
        self.presentTexture = nil;
        self.shadowQueue = nil;"""),
        ("""                [self rebuildScanoutTextureWithSurface:self.delayedScanoutSurface width:self.delayedScanoutInfo.width height:self.delayedScanoutInfo.height];
                self.delayedScanoutSurface = nil;""",
         """                // Transfer the owned +1 reference before the consuming call.
                IOSurfaceRef surface = self.delayedScanoutSurface;
                self.delayedScanoutSurface = nil;
                [self rebuildScanoutTextureWithSurface:surface width:self.delayedScanoutInfo.width height:self.delayedScanoutInfo.height];"""),
        ("""        // present the shadow copy once we have one, see
        // `copyScanoutRect:withCompletion:`
        id<MTLTexture> presentTexture = self.presentTexture;
        return presentTexture ?: self.glTexture;""",
         """        // A gl_draw_done acknowledgement permits the server to overwrite
        // its IOSurface. Only a completed private copy is safe to present.
        return self.presentTexture;"""),
        ("""        g_object_unref(channel);
    }];
}

- (void)updateVisibleAreaWithRect:""",
         """        g_object_unref(channel);
    }];
    if (_delayedScanoutSurface) {
        CFRelease(_delayedScanoutSurface);
        _delayedScanoutSurface = nil;
    }
}

- (void)updateVisibleAreaWithRect:"""),
        ("""- (void)rebuildScanoutTextureWithScanout:(SpiceGlScanout)scanout {
    IOSurfaceID iosurfaceid = 0;""",
         """// Called on the GLib context. Drop an unconsumed lookup reference and
// invalidate previous copy generations before accepting a new scanout.
- (void)resetScanout {
    if (self.delayedScanoutSurface) {
        CFRelease(self.delayedScanoutSurface);
        self.delayedScanoutSurface = nil;
    }
    self.presentTexture = nil;
    self.shadowTexture = nil;
    self.shadowQueue = nil;
    self.glTexture = nil;
    self.shadowNeedsFullCopy = YES;
    [self disableScanout];
}

- (void)rebuildScanoutTextureWithScanout:(SpiceGlScanout)scanout {
    [self resetScanout];
    IOSurfaceID iosurfaceid = 0;"""),
        ("""- (void)rebuildScanoutTextureWithSurface:(IOSurfaceRef)surface width:(NSUInteger)width height:(NSUInteger)height {
    MTLTextureDescriptor *textureDescriptor""",
         """- (void)rebuildScanoutTextureWithSurface:(IOSurfaceRef)surface width:(NSUInteger)width height:(NSUInteger)height {
    // Consume the +1 reference on all paths. Bound dimensions and allocation
    // before invoking Metal, and do not trust metadata over the IOSurface.
    const NSUInteger maxScanoutBytes = 256u * 1024u * 1024u;
    if (!surface) return;
    if (!width || !height || width > 16384 || height > 16384 ||
        width > IOSurfaceGetWidth(surface) || height > IOSurfaceGetHeight(surface) ||
        width > maxScanoutBytes / 4 / height) {
        CFRelease(surface);
        [self resetScanout];
        return;
    }
    self.shadowTexture = nil;
    self.presentTexture = nil;
    self.shadowQueue = nil;
    MTLTextureDescriptor *textureDescriptor"""),
        ("""    CFRelease(surface);
    [self rebuildShadowTextureWithWidth:width height:height];""",
         """    CFRelease(surface);
    if (!self.glTexture) {
        [self resetScanout];
        return;
    }
    [self rebuildShadowTextureWithWidth:width height:height];"""),
        ("""    // if this fails we present the scanout directly, which is correct but
    // couples the server to our display refresh
    self.shadowTexture = [self.device newTextureWithDescriptor:textureDescriptor];""",
         """    // If allocation fails, skip presentation instead of sampling memory
    // the server is allowed to overwrite.
    self.shadowTexture = [self.device newTextureWithDescriptor:textureDescriptor];"""),
        ("""    id<MTLTexture> source = self.glTexture;
    id<MTLTexture> destination = self.shadowTexture;
    id<MTLCommandQueue> queue = self.renderers.firstObject.commandQueue;""",
         """    id<MTLTexture> source = self.glTexture;
    id<MTLCommandQueue> queue = self.renderers.firstObject.commandQueue;
    if (self.shadowQueue != queue) {
        // A replacement renderer may use a different command queue. Do not
        // overwrite a texture which the old queue may still be reading.
        self.shadowTexture = nil;
        self.presentTexture = nil;
        self.shadowQueue = queue;
        self.shadowNeedsFullCopy = YES;
    }
    if (source && queue && !self.shadowTexture) {
        [self rebuildShadowTextureWithWidth:source.width height:source.height];
        self.shadowNeedsFullCopy = YES;
    }
    id<MTLTexture> destination = self.shadowTexture;"""),
        ("""        // Either nothing can present this frame, or we have nowhere to copy it
        // to. We must not acknowledge here and then present `glTexture`: that
        // hands the renderer the surface the server is now free to overwrite.
        // Going through the renderer instead holds the acknowledgement until
        // the frame is on screen, which is what we did before the copy existed,
        // and costs nothing when there is nothing to draw.
        [self invalidateWithCompletion:^{
            [CSMain.sharedInstance asyncWith:completion];
        }];
        return;""",
         """        // No GPU reads the raw IOSurface in this branch. Acknowledge without
        // waiting on AppKit, and force a full copy when rendering recovers.
        self.shadowNeedsFullCopy = YES;
        completion();
        return;"""),
        ("""    if (!CGRectIsEmpty(damaged)) {
        [blitEncoder copyFromTexture:source""",
         """    if (!CGRectIsNull(damaged) && !CGRectIsEmpty(damaged)) {
        [blitEncoder copyFromTexture:source"""),
        ("""    // later copies build on this one, and the queue keeps them in order
    self.shadowNeedsFullCopy = NO;

    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> commandBuffer) {
        BOOL succeeded = commandBuffer.error == nil;""",
         """    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> commandBuffer) {
        BOOL succeeded = commandBuffer.status == MTLCommandBufferStatusCompleted;"""),
        ("""            if (succeeded && destination == self.shadowTexture) {
                // publish before the completion runs, so the invalidate it
                // triggers picks up this frame
                self.presentTexture = destination;
            }""",
         """            if (source == self.glTexture && destination == self.shadowTexture &&
                queue == self.shadowQueue) {
                if (succeeded) {
                    self.shadowNeedsFullCopy = NO;
                    self.presentTexture = destination;
                } else {
                    // A failed partial copy may corrupt the existing shadow.
                    self.shadowNeedsFullCopy = YES;
                    self.presentTexture = nil;
                    [self disableScanout];
                }
            }"""),
    ])


def overlay_metal_pixel_probe(checkout: Path) -> None:
    """Opt-in GPU drawable readback for the synthetic loopback display test."""
    root = checkout / "Sources" / "CocoaSpiceRenderer"
    # Metal normalized alpha is 0...1, not an 8-bit integer.
    _replace_once(root / "CSShaders.metal", [
        ("colorSample.a = 0xff;", "colorSample.a = 1.0h;"),
    ])
    _replace_once(root / "include" / "CSMetalRenderer.h", [
        ("/// Modify upscaler and downscaler settings",
         "/// Test-only center pixel (BGRA8), delivered on main after GPU completion.\n"
         "@property (nonatomic, copy, nullable) void (^smokePixelHandler)(uint32_t pixel);\n\n"
         "/// Modify upscaler and downscaler settings"),
    ])
    _replace_once(root / "CSMetalRenderer.m", [
        ("""    [self _renderCommand:commandBuffer
              drawSource:sourceData""",
         """    void (^sampleHandler)(uint32_t) = self.smokePixelHandler;
    id<MTLTexture> drawableTexture = currentDrawable.texture;
    id<MTLBuffer> sampleBuffer = nil;
    if (sampleHandler) [self _setViewportCGSize:CGSizeMake(drawableTexture.width, drawableTexture.height)];
    if (sampleHandler && !view.framebufferOnly &&
        drawableTexture.pixelFormat == MTLPixelFormatBGRA8Unorm &&
        drawableTexture.width && drawableTexture.height) {
        sampleBuffer = [drawableTexture.device newBufferWithLength:256 options:MTLResourceStorageModeShared];
        if (sampleBuffer) renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    }

    [self _renderCommand:commandBuffer
              drawSource:sourceData"""),
        ("""    [commandBuffer presentDrawable:currentDrawable];

    // Capture the handler at submission""",
         """    if (sampleBuffer) {
        id<MTLBlitCommandEncoder> probe = [commandBuffer blitCommandEncoder];
        if (probe) {
            [probe copyFromTexture:drawableTexture sourceSlice:0 sourceLevel:0
                      sourceOrigin:MTLOriginMake(drawableTexture.width / 2, drawableTexture.height / 2, 0)
                        sourceSize:MTLSizeMake(1, 1, 1)
                          toBuffer:sampleBuffer destinationOffset:0
             destinationBytesPerRow:256 destinationBytesPerImage:256];
            [probe endEncoding];
        } else {
            sampleBuffer = nil;
        }
    }
    [commandBuffer presentDrawable:currentDrawable];

    // Capture the handler at submission"""),
        ("""            if (rendered && frameHandler) {
                frameHandler();
            }""",
         """            if (rendered && frameHandler) {
                frameHandler();
            }
            if (sampleHandler && (!rendered || !sampleBuffer)) {
                NSLog(@"MRV_PIXEL_READBACK_UNAVAILABLE gpuStatus=%lu buffer=%d", (unsigned long)commandBuffer.status, sampleBuffer != nil);
            }
            if (rendered && sampleHandler && sampleBuffer) {
                uint32_t pixel = 0;
                memcpy(&pixel, sampleBuffer.contents, sizeof(pixel));
                sampleHandler(pixel);
            }"""),
    ])


def overlay_channel_lifetime_guards(checkout: Path) -> None:
    """Validate main-channel pointers on the worker, not before scheduling."""
    source = checkout / "Sources" / "CocoaSpice"
    _replace_once(source / "CSInput.m", [
        ("""- (void)requestMouseMode:(BOOL)server {
    if (!self.spiceMain) {
        return;
    }
    [CSMain.sharedInstance asyncWith:^{
        SpiceMainChannel *main = self.spiceMain;""",
         """- (void)requestMouseMode:(BOOL)server {
    [CSMain.sharedInstance asyncWith:^{
        SpiceMainChannel *main = self.spiceMain;
        if (!main || !self.channel) return;"""),
    ])
    _replace_once(source / "CSDisplay.m", [
        ("""    if (!self.spiceMain) {
        SPICE_DEBUG("[CocoaSpice] ignoring change resolution because main channel not found");
        return;
    }
    [CSMain.sharedInstance asyncWith:^{
        SpiceMainChannel *main = self.spiceMain;
        spice_main_channel_update_display_enabled""",
         """    [CSMain.sharedInstance asyncWith:^{
        SpiceMainChannel *main = self.spiceMain;
        if (!main) return;
        spice_main_channel_update_display_enabled"""),
        ("""    if (_isEnabled != isEnabled) {
        if (!self.spiceMain) {
            SPICE_DEBUG("[CocoaSpice] ignoring display enable change because main channel not found");
            return;
        }
        [CSMain.sharedInstance asyncWith:^{
            spice_main_channel_update_display_enabled(self.spiceMain, (int)self.monitorID, isEnabled, TRUE);
            self->_isEnabled = isEnabled;
        }];
    }""",
         """    [CSMain.sharedInstance asyncWith:^{
        SpiceMainChannel *main = self.spiceMain;
        if (!main || self->_isEnabled == isEnabled) return;
        spice_main_channel_update_display_enabled(main, (int)self.monitorID, isEnabled, TRUE);
        self->_isEnabled = isEnabled;
    }];"""),
    ])


def overlay_connection_lifecycle(checkout: Path) -> None:
    """Do not report disconnected while the live SpiceSession still has channels."""
    impl = checkout / "Sources" / "CocoaSpice" / "CSConnection.m"
    _replace_once(impl, [
        ('#import <spice/vd_agent.h>', '#import <spice/vd_agent.h>\n#import <stdlib.h>\n#import <stdio.h>'),
        ("@property (nonatomic, readwrite) BOOL isTLSOnly;",
         "@property (nonatomic, readwrite) BOOL isTLSOnly;\n@property (nonatomic) BOOL disconnectNotified;"),
        ("""    NSInteger code = kCSConnectionErrorNone;
    
    switch (event) {""",
         """    NSInteger code = kCSConnectionErrorNone;
    if (getenv("MRV_GLIB_TRACE")) {
        fprintf(stderr, "MRV_CONN_EVENT session=%p channel=%p event=%d\\n",
                (void *)self.spiceSession, (void *)channel, (int)event);
        fflush(stderr);
    }
    switch (event) {"""),
        ("""    CSConnection *self = (__bridge CSConnection *)data;
    int chid;
    
    g_object_get(channel, "channel-id", &chid, NULL);
    SPICE_DEBUG("new channel (#%d)", chid);""",
         """    CSConnection *self = (__bridge CSConnection *)data;
    int chid = -1, type = -1;
    if (s != self.spiceSession || !SPICE_IS_CHANNEL(channel)) return;
    g_object_get(channel, "channel-id", &chid, "channel-type", &type, NULL);
    if (getenv("MRV_GLIB_TRACE")) {
        fprintf(stderr, "MRV_CONN_NEW session=%p channel=%p type=%d id=%d\\n",
                (void *)s, (void *)channel, type, chid);
        fflush(stderr);
    }
    SPICE_DEBUG("new channel (#%d)", chid);"""),
        ("""    g_object_get(channel, "channel-id", &chid, NULL);
    if (SPICE_IS_MAIN_CHANNEL(channel)) {""",
         """    if (s != self.spiceSession || !SPICE_IS_CHANNEL(channel)) return;
    int type = -1;
    g_object_get(channel, "channel-id", &chid, "channel-type", &type, NULL);
    if (getenv("MRV_GLIB_TRACE")) {
        fprintf(stderr, "MRV_CONN_DESTROY session=%p channel=%p type=%d id=%d\\n",
                (void *)s, (void *)channel, type, chid);
        fflush(stderr);
    }
    if (SPICE_IS_MAIN_CHANNEL(channel)) {"""),
        ("""    // ideally we do this in cs_connection_destroy() but because that happens so late, it opens us up
    // to retain cycles if the caller waits for `spiceDisconnect:` to cleanup.
    if (self.channels.count == 0) {
        [self.delegate spiceDisconnected:self];
    }""", """    // The wrapper array excludes the main channel. Empty wrappers alone
    // do not mean the session disconnected (e.g. a display disappears).
    // Do not wait for every external wrapper reference to be released either.
    GList *remaining = spice_session_get_channels(s);
    BOOL empty = remaining == NULL;
    g_list_free(remaining);
    if (!self.spiceMain && empty && !self.disconnectNotified) {
        self.disconnectNotified = YES;
        [self.delegate spiceDisconnected:self];
    }"""),
        ("""    SPICE_DEBUG("spice connection destroyed");
    // this happens pretty late--after every SpiceChannel has been deallocated""",
         """    SPICE_DEBUG("spice connection destroyed");
    if (!self.disconnectNotified) {
        self.disconnectNotified = YES;
        [self.delegate spiceDisconnected:self];
    }"""),
        ("""        initiated = spice_session_connect(self.spiceSession);""",
         """        self.disconnectNotified = NO;
        if (getenv("MRV_GLIB_TRACE")) {
            fprintf(stderr, "MRV_CONN_CONNECT session=%p\\n", (void *)self.spiceSession);
            fflush(stderr);
        }
        initiated = spice_session_connect(self.spiceSession);"""),
        ("""- (void)disconnect {
    [CSMain.sharedInstance syncWith:^{
        spice_session_disconnect(self.spiceSession);""",
         """- (void)disconnect {
    [CSMain.sharedInstance syncWith:^{
        if (getenv("MRV_GLIB_TRACE")) {
            fprintf(stderr, "MRV_CONN_DISCONNECT session=%p\\n", (void *)self.spiceSession);
            fflush(stderr);
        }
        spice_session_disconnect(self.spiceSession);"""),
    ])


def main() -> None:
    checkout = Path(sys.argv[1]) if len(sys.argv) > 1 else CHECKOUT
    if not (checkout / "Package.swift").exists():
        raise SystemExit(f"CocoaSpice checkout 不存在：{checkout}")
    overlay_gst_ios_init(checkout)
    overlay_csmain(checkout)
    overlay_package_swift(checkout)
    overlay_display_initial_frame(checkout)
    overlay_renderer_protected_category(checkout)
    overlay_metal_renderer_diagnostics(checkout)
    overlay_metal_renderer_complete_pending_draws(
        checkout / "Sources" / "CocoaSpiceRenderer" / "CSMetalRenderer.m"
    )
    overlay_metal_frame_observation(checkout)
    overlay_canvas_gpu_lifetime(checkout)
    overlay_scanout_ownership(checkout)
    overlay_metal_pixel_probe(checkout)
    overlay_connection_pve_api(checkout)
    overlay_horizontal_scroll_compatibility(checkout)
    overlay_input_release_and_secure_attention(checkout)
    overlay_session_sharing_category(checkout)
    overlay_channel_lifetime_guards(checkout)
    overlay_connection_lifecycle(checkout)
    print(f"已套用 Homebrew overlay：{checkout}")


if __name__ == "__main__":
    main()
