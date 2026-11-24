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
