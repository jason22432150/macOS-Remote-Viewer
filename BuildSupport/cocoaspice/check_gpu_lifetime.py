#!/usr/bin/env python3
"""Validate invariants against the actual pinned, patched CocoaSpice checkout.

This is a structural regression check, not a GPU runtime test.
"""
from pathlib import Path
import sys


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(message)


def main() -> None:
    root = Path(sys.argv[1]) / "Sources"
    display = (root / "CocoaSpice" / "CSDisplay.m").read_text()
    renderer = (root / "CocoaSpiceRenderer" / "CSMetalRenderer.m").read_text()

    destroy = display.split("static void cs_primary_destroy(", 1)[1].split("static void cs_invalidate(", 1)[0]
    rebuild = display.split("- (void)rebuildCanvasTexture {", 1)[1].split("- (void)rebuildDisplayVertices {", 1)[0]
    draw = display.split("- (void)drawRegion:(CGRect)rect {", 1)[1].split("- (void)requestResolution:", 1)[0]
    copy = renderer.split("- (void)renderSouce:", 1)[1].split("- (void)invalidateRenderSource:", 1)[0]
    gpu_draw = renderer.split("- (void)drawInMTKView:", 1)[1].split("- (void)renderSouce:", 1)[0]

    require("dispatch_semaphore_wait" not in destroy, "surface destroy still blocks on render")
    require("newBufferWithBytesNoCopy" not in rebuild, "SPICE memory still aliases staging buffer")
    require("MTLResourceStorageModeShared" in rebuild, "expected owned shared staging buffer")
    require("maxCanvasBytes" in rebuild and "maxCanvasBytes / 4" in rebuild, "allocation cap missing")
    require("self.canvasBuffer != submittedBuffer" in draw, "stale completion is not fenced")
    require("memcpy((uint8_t *)submittedBuffer.contents" in draw, "dirty region not copied to owned staging memory")
    require("addCompletedHandler" in copy and "_addDrawCompletion" not in copy, "blit completion still depends on drawable")
    require("submittedCompletions" in gpu_draw, "draw completion batch missing")
    dirty_guard = gpu_draw.index("if (!self.renderNeedsUpdate || !sourceData.isVisible)")
    acquire_drawable = gpu_draw.index("view.currentRenderPassDescriptor")
    consume_dirty = gpu_draw.index("self.renderNeedsUpdate = NO;")
    require(dirty_guard < acquire_drawable < consume_dirty, "idle ticks still acquire drawables")
    require(gpu_draw.index("if (!commandBuffer)") < consume_dirty, "failed command buffer consumes dirty state")
    idle_guard = gpu_draw[dirty_guard:acquire_drawable]
    require("[self _completeDraw];" in idle_guard, "idle ticks no longer drain pending completions")
    unavailable_guard = gpu_draw[acquire_drawable:consume_dirty]
    require(unavailable_guard.count("[self _completeDraw];") == 2, "unavailable drawable/command buffer does not drain completions")
    resize = renderer.split("- (void)mtkView:", 1)[1].split("- (void)setViewportOrigin:", 1)[0]
    require("self.renderNeedsUpdate = YES;" in resize.split("- (void)requestPresentationRefresh", 1)[0],
            "resize does not invalidate static frame")
    require("- (void)requestPresentationRefresh" in resize and
            "self.renderNeedsUpdate = YES;" in resize.split("- (void)requestPresentationRefresh", 1)[1],
            "foreground refresh does not mark retained frame dirty")
    require("for (completionCallback_t completion in submittedCompletions)" in gpu_draw, "old draw can drain newer completions")
    scanout_copy = display.split("- (void)copyScanoutRect:(CGRect)rect withCompletion:", 1)[1].split("- (void)rebuildCanvasTexture {", 1)[0]
    require("return presentTexture ?: self.glTexture" not in display, "server-owned IOSurface must not be presented")
    require("return self.presentTexture;" in display, "private scanout presentation missing")
    require("CFRelease(self.delayedScanoutSurface)" in display and "CFRelease(_delayedScanoutSurface)" in display, "unconsumed IOSurface reference not released")
    require("source == self.glTexture && destination == self.shadowTexture" in scanout_copy and "queue == self.shadowQueue" in scanout_copy, "stale scanout completion not fenced")
    require("self.shadowNeedsFullCopy = YES;" in scanout_copy and "self.presentTexture = nil;" in scanout_copy, "copy failure recovery missing")
    require("invalidateWithCompletion" not in scanout_copy, "scanout fallback still waits for AppKit")
    print("Patched GPU and scanout lifetime invariants verified.")


if __name__ == "__main__":
    main()
