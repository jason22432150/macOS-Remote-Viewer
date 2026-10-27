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

- (void)drawRegion:(CGRect)rect {
    if (!self.canvasData || !self.canvasBuffer) {
        return; // not ready to draw yet
    }
    if (self.canvasIsBusy) {
        self.canvasDirtyRect = CGRectUnion(self.canvasDirtyRect, rect);
        return;
    }
    self.canvasIsBusy = YES;
    NSInteger pixelSize = (self.canvasFormat == SPICE_SURFACE_FMT_32_xRGB) ? 4 : 2;
    // create draw region
    MTLRegion region = {
        { rect.origin.x-self.visibleArea.origin.x, rect.origin.y-self.visibleArea.origin.y, 0 }, // MTLOrigin
        { rect.size.width, rect.size.height, 1} // MTLSize
    };
    NSUInteger offset = (NSUInteger)(rect.origin.y*self.canvasStride + rect.origin.x*pixelSize);
#if TARGET_OS_OSX || TARGET_OS_SIMULATOR
    for (NSUInteger i = 0; i < rect.size.height; i++) {
#if TARGET_OS_SIMULATOR
        memcpy(self.canvasBuffer.contents + self.canvasBufferOffset + offset + i*self.canvasStride,
               self.canvasData + offset + i*self.canvasStride,
               rect.size.width*pixelSize);
#else /* !TARGET_OS_SIMULATOR */
        [self.canvasBuffer didModifyRange:NSMakeRange(self.canvasBufferOffset + offset + i*self.canvasStride,
                                                      rect.size.width*pixelSize)];
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


def overlay_package_swift(checkout: Path) -> None:
    path = checkout / "Package.swift"
    text = path.read_text()
    marker = '.headerSearchPath("ExternalHeaders/spice-client-glib-2.0")]),'
    if marker not in text:
        raise SystemExit("找不到 Package.swift 的 CocoaSpice cSettings 結尾")

    cflags = pkgconfig_tokens("--cflags", "spice-client-glib-2.0", "glib-2.0", "gstreamer-1.0")
    libs = pkgconfig_tokens("--libs", "spice-client-glib-2.0", "glib-2.0", "gstreamer-1.0")
    replacement = (
        '.headerSearchPath("ExternalHeaders/spice-client-glib-2.0"),\n'
        f"                .unsafeFlags({swift_string_list(cflags)})],\n"
        "            linkerSettings: [\n"
        f"                .unsafeFlags({swift_string_list(libs)})]),"
    )
    text = text.replace(marker, replacement)
    path.write_text(text)


def main() -> None:
    checkout = Path(sys.argv[1]) if len(sys.argv) > 1 else CHECKOUT
    if not (checkout / "Package.swift").exists():
        raise SystemExit(f"CocoaSpice checkout 不存在：{checkout}")
    overlay_gst_ios_init(checkout)
    overlay_csmain(checkout)
    overlay_package_swift(checkout)
    overlay_display_initial_frame(checkout)
    print(f"已套用 Homebrew overlay：{checkout}")


if __name__ == "__main__":
    main()
