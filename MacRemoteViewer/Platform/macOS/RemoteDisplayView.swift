import AppKit
import SwiftUI

/// 輸入畫布。CocoaSpice Metal renderer 待原生依賴鎖定後再接上。
struct RemoteDisplayView: NSViewRepresentable {
    var controller: SessionController
    var router: InputRouter

    func makeNSView(context: Context) -> RemoteCanvasView {
        let view = RemoteCanvasView()
        view.controller = controller
        view.router = router
        view.setupTracking()
        return view
    }

    func updateNSView(_ nsView: RemoteCanvasView, context: Context) {
        nsView.controller = controller
        nsView.router = router
    }
}

final class RemoteCanvasView: NSView {
    weak var controller: SessionController?
    var router: InputRouter?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        dirtyRect.fill()
        let text = "等待 SPICE 畫面（原生引擎尚未連結）"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.systemFont(ofSize: 16)
        ]
        let size = text.size(withAttributes: attrs)
        let origin = CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2)
        text.draw(at: origin, withAttributes: attrs)
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
