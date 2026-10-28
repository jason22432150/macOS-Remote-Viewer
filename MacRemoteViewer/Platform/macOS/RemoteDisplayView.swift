import AppKit
import MetalKit
import SwiftUI
import CocoaSpiceRenderer

/// 遠端畫面：Metal 呈現 SPICE framebuffer，同時攔截鍵盤滑鼠。
struct RemoteDisplayView: NSViewRepresentable {
    var controller: SessionController
    var router: InputRouter
    /// 讓 guest 解析度變更時 SwiftUI 會呼叫 `updateNSView`，才能重算 letterbox。
    var displaySize: RemoteFrame?

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
        // 不可在 layout／updateNSView 同步寫入 @Observable，否則 AppKit display cycle 會 SIGTRAP。
        _ = displaySize
    }
}

final class RemoteCanvasView: MTKView {
    weak var controller: SessionController?
    var router: InputRouter?
    private var metalRenderer: CSMetalRenderer?
    private var mapping: GuestPointerMapping?
    /// `NSCursor.hide` / `unhide` 是計數式 API，必須成對呼叫。
    private var isLocalCursorHidden = false

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

    /// 視窗邏輯尺寸變化時請 guest 對齊解析度；agent 未就緒則由 SessionController 暫存。
    /// 必須延到下一輪 run loop：AppKit layout 期間同步寫入 @Observable 會 SIGTRAP。
    /// `size` 只做同步 guard；真正送出的是 layout 結束後的 `bounds`，避免用到尚未穩定的 frame。
    func syncGuestResolution(_ size: CGSize? = nil) {
        let canvasSize = size ?? bounds.size
        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let latest = self.bounds.size
            guard latest.width > 0, latest.height > 0 else { return }
            self.controller?.updateViewportSize(latest)
        }
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
        syncGuestResolution(newSize)
        // 與 guest 解析度分開排隊：letterbox 依賴 MTKView 在 setFrameSize 之後更新的 drawableSize。
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

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didResignKeyNotification,
                object: window
            )
        }
        if newWindow == nil {
            showLocalCursor()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResignKey(_:)),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
            window.makeFirstResponder(self)
        }
        attachRendererIfNeeded()
        // bounds 仍為零時會略過，等後續 setFrameSize 再送。
        syncGuestResolution()
    }

    override func mouseEntered(with event: NSEvent) {
        handleMouse(event)
    }

    override func mouseExited(with event: NSEvent) {
        showLocalCursor()
    }

    /// 失去 key window 時立刻顯示本機游標，避免 NSCursor.hide 殘留到其他 App。
    @objc private func windowDidResignKey(_ notification: Notification) {
        showLocalCursor()
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
    /// 右鍵／側鍵按住時 AppKit 改送 *Dragged；不轉發則本機游標已隱藏、guest 也收不到移動。
    override func rightMouseDragged(with event: NSEvent) { handleMouse(event) }
    override func otherMouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        handleMouse(event)
    }
    override func otherMouseUp(with event: NSEvent) { handleMouse(event) }
    override func otherMouseDragged(with event: NSEvent) { handleMouse(event) }
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
        if let mapping {
            let location = convert(event.locationInWindow, from: nil)
            let insideDisplay = mapping.contains(viewPoint: location, bounds: bounds)
            // 只有滑鼠在遠端畫面內才隱藏本機游標；黑邊維持可見。
            updateLocalCursor(hidden: router.captured && insideDisplay)
            if let mouse = router.mouseEvent(from: event, in: self, mapping: mapping) {
                controller.sendMouse(mouse)
            }
            // 側鍵上頁／下一頁只在畫面內送出，與滑鼠事件範圍一致。
            if insideDisplay {
                for key in router.sideButtonKeyEvents(from: event) {
                    controller.sendKey(key)
                }
            }
        } else {
            showLocalCursor()
        }
    }

    private func updateLocalCursor(hidden: Bool) {
        guard isLocalCursorHidden != hidden else { return }
        if hidden {
            NSCursor.hide()
        } else {
            NSCursor.unhide()
        }
        isLocalCursorHidden = hidden
    }

    private func showLocalCursor() {
        updateLocalCursor(hidden: false)
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
            showLocalCursor()
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
