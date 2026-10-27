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
    }
}

final class RemoteCanvasView: MTKView {
    weak var controller: SessionController?
    var router: InputRouter?
    private var metalRenderer: CSMetalRenderer?

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
    }

    func attachRendererIfNeeded() {
        guard let metalRenderer else { return }
        controller?.attachRenderer(metalRenderer)
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

    override func mouseMoved(with event: NSEvent) { handleMouse(event) }
    override func mouseDown(with event: NSEvent) { handleMouse(event) }
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

    override func resignFirstResponder() -> Bool {
        releaseKeys()
        return super.resignFirstResponder()
    }

    private func handleMouse(_ event: NSEvent) {
        guard let controller, let router else { return }
        let size = controller.displaySize.map { CGSize(width: $0.width, height: $0.height) } ?? bounds.size
        if let mouse = router.mouseEvent(from: event, in: self, displaySize: size) {
            controller.sendMouse(mouse)
        }
    }

    private func sendKey(_ event: NSEvent) {
        guard let controller, let router, let key = router.keyEvent(from: event) else { return }
        controller.sendKey(key)
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
