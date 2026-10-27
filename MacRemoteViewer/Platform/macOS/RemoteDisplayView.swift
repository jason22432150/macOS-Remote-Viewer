import AppKit
import MetalKit
import SwiftUI
import CocoaSpiceRenderer

/// 遠端畫面：Metal 呈現 SPICE framebuffer，同時攔截鍵盤滑鼠。
struct RemoteDisplayView: NSViewRepresentable {
    var controller: SessionController
    var router: InputRouter

    func makeNSView(context: Context) -> RemoteCanvasView {
        let view = RemoteCanvasView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.controller = controller
        view.router = router
        view.setupMetal()
        view.setupTracking()
        return view
    }

    func updateNSView(_ nsView: RemoteCanvasView, context: Context) {
        nsView.controller = controller
        nsView.router = router
        nsView.attachRendererIfNeeded()
        nsView.updateViewport()
    }
}

final class RemoteCanvasView: MTKView {
    weak var controller: SessionController?
    var router: InputRouter?
    private var metalRenderer: CSMetalRenderer?
    private var mapping: GuestPointerMapping?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    /// 建立 CocoaSpice Metal renderer，並在 display channel 就緒後掛上。
    func setupMetal() {
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        isPaused = false
        enableSetNeedsDisplay = false
        autoResizeDrawable = true
        if metalRenderer == nil {
            let renderer = CSMetalRenderer(metalKitView: self)
            metalRenderer = renderer
            delegate = renderer
        }
        attachRendererIfNeeded()
        updateViewport()
    }

    func attachRendererIfNeeded() {
        guard let metalRenderer else { return }
        controller?.attachRenderer(metalRenderer)
        updateViewport()
    }

    /// CocoaSpice 以 drawable 中心繪製；必須把 scale 設成與滑鼠對應相同的 letterbox。
    func updateViewport() {
        guard let renderer = metalRenderer,
              let frame = controller?.displaySize,
              frame.width > 0,
              frame.height > 0,
              drawableSize.width > 0,
              drawableSize.height > 0
        else { return }
        let next = GuestPointerMapping.aspectFit(
            displaySize: CGSize(width: frame.width, height: frame.height),
            drawableSize: drawableSize
        )
        mapping = next
        renderer.viewportScale = next.viewportScale
        renderer.viewportOrigin = next.viewportOrigin
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        DispatchQueue.main.async { [weak self] in
            self?.updateViewport()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateViewport()
    }

    func setupTracking() {
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseMoved, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        ))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        attachRendererIfNeeded()
    }

    override func mouseEntered(with event: NSEvent) {
        if router?.captured == true {
            NSCursor.hide()
        }
        handleMouse(event)
    }

    override func mouseExited(with event: NSEvent) {
        NSCursor.unhide()
    }

    override func mouseMoved(with event: NSEvent) { handleMouse(event) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        handleMouse(event)
    }
    override func mouseUp(with event: NSEvent) { handleMouse(event) }
    override func mouseDragged(with event: NSEvent) { handleMouse(event) }
    override func rightMouseDown(with event: NSEvent) { handleMouse(event) }
    override func rightMouseUp(with event: NSEvent) { handleMouse(event) }
    override func otherMouseDown(with event: NSEvent) { handleMouse(event) }
    override func otherMouseUp(with event: NSEvent) { handleMouse(event) }
    override func scrollWheel(with event: NSEvent) { handleMouse(event) }

    override func keyDown(with event: NSEvent) {
        if interceptHotKey(event) { return }
        sendKey(event)
    }

    override func keyUp(with event: NSEvent) {
        sendKey(event)
    }

    override func flagsChanged(with event: NSEvent) {
        sendKey(event)
    }

    /// 擷取輸入時把 Cmd+A 等 menu key equivalent 轉給 guest，避免本機選單先吃掉。
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard router?.captured == true, controller != nil else {
            return super.performKeyEquivalent(with: event)
        }
        if isLocalQuitShortcut(event) {
            return super.performKeyEquivalent(with: event)
        }
        if interceptHotKey(event) { return true }
        sendKey(event)
        return true
    }

    override func resignFirstResponder() -> Bool {
        releaseKeys()
        return super.resignFirstResponder()
    }

    private func handleMouse(_ event: NSEvent) {
        guard let controller, let router else { return }
        updateViewport()
        guard let mapping else { return }
        if let mouse = router.mouseEvent(from: event, in: self, mapping: mapping) {
            controller.sendMouse(mouse)
        }
    }

    private func sendKey(_ event: NSEvent) {
        guard let controller, let router else { return }
        for key in router.keyEvents(from: event) {
            controller.sendKey(key)
        }
    }

    private func isLocalQuitShortcut(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command)
            && event.charactersIgnoringModifiers?.lowercased() == "q"
    }

    private func interceptHotKey(_ event: NSEvent) -> Bool {
        guard let controller, let router, let profile = controller.profile else { return false }
        if router.matches(profile.toggleFullscreen, event: event) {
            window?.toggleFullScreen(nil)
            return true
        }
        if router.matches(profile.releaseCursor, event: event) {
            router.captured = false
            NSCursor.unhide()
            window?.makeFirstResponder(nil)
            return true
        }
        if router.matches(profile.secureAttention, event: event) {
            controller.sendSecureAttention()
            return true
        }
        return false
    }

    private func releaseKeys() {
        guard let controller, let router else { return }
        for event in router.releaseAll() {
            controller.sendKey(event)
        }
    }
}
