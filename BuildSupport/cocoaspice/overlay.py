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
    if (rowBytes == 0 || rowBytes > stride) {
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
    if (!self.spiceSession || !host.length || !tlsPort.length || !ca.length || !subject.length) {
        return NO;
    }
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
    return YES;
}

- (BOOL)hasPVEClipboardCapability {
    return self.spiceMain &&
        spice_main_channel_agent_test_capability(self.spiceMain, VD_AGENT_CAP_CLIPBOARD_BY_DEMAND);
}

"""
    _replace_once(header, [("- (BOOL)connect;", declaration + "- (BOOL)connect;")])
    _replace_once(impl, [("- (BOOL)connect {", implementation + "- (BOOL)connect {")])


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
    overlay_connection_pve_api(checkout)
    overlay_horizontal_scroll_compatibility(checkout)
    overlay_session_sharing_category(checkout)
    print(f"已套用 Homebrew overlay：{checkout}")


if __name__ == "__main__":
    main()
