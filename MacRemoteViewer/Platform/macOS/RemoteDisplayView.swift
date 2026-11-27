import AppKit
import CoreGraphics
import OSLog
import MetalKit
import SwiftUI
import CocoaSpiceRenderer

/// 所有 MTKView 共用同一顆 Metal device，避免 CSDisplay 因 device 指標不同而拒絕重掛 renderer。
@MainActor
private enum SharedMetalDevice {
    static let systemDefault: MTLDevice? = MTLCreateSystemDefaultDevice()
}

/// 遠端畫面：Metal 呈現 SPICE framebuffer，同時攔截鍵盤滑鼠。
struct RemoteDisplayView: NSViewRepresentable {
    var controller: SessionController
    var router: InputRouter
    /// 讓 guest 解析度變更時 SwiftUI 會呼叫 `updateNSView`，才能重算 letterbox。
    var displaySize: RemoteFrame?
    var isActive: Bool = true
    var useNativeDisplayPixels = false
    var relativeMouseRequested = false
    var sessionConnected = false

    func makeNSView(context: Context) -> RemoteCanvasView {
        let view = RemoteCanvasView(frame: .zero, device: SharedMetalDevice.systemDefault)
        view.controller = controller
        view.router = router
        view.setNativeDisplayPixels(useNativeDisplayPixels)
        view.setActive(isActive)
        view.setupMetal()
        view.setupTracking()
        return view
    }

    static func dismantleNSView(_ nsView: RemoteCanvasView, coordinator: ()) {
        nsView.prepareForRemoval()
    }

    func updateNSView(_ nsView: RemoteCanvasView, context: Context) {
        nsView.controller = controller
        nsView.router = router
        nsView.setNativeDisplayPixels(useNativeDisplayPixels)
        nsView.setActive(isActive)
        nsView.updateCaptureEligibility(requested: relativeMouseRequested,
                                        connected: sessionConnected,
                                        hasDisplay: displaySize != nil)
        nsView.attachRendererIfNeeded()
        nsView.updateViewport()
        // 不可在 layout／updateNSView 同步寫入 @Observable，否則 AppKit display cycle 會 SIGTRAP。
        _ = displaySize
    }
}

final class RemoteCanvasView: MTKView {
    weak var controller: SessionController?
    var router: InputRouter?
    /// Keep background ticks at reduced FPS; the renderer only requests a drawable when dirty.
    private static let foregroundFPS = 60
    private static let backgroundFPS = 15
    private(set) var isActive = true
    private var metalRenderer: CSMetalRenderer?
    private weak var registeredController: SessionController?
    private var permanentlyRemoved = false
    private var mapping: GuestPointerMapping?
    private var useNativeDisplayPixels = false
    /// `NSCursor.hide` / `unhide` 是計數式 API，必須成對呼叫。
    private var isLocalCursorHidden = false
    private static weak var captureOwner: RemoteCanvasView?
    private var captureWatchdog: Task<Void, Never>?
    private var priorMouseMovedEvents = false
    private var lastRelativeRequest = false
    private let captureLogger = Logger(subsystem: "local.MacRemoteViewer", category: "mouse-capture")
    private var isRelativeCaptured: Bool { Self.captureOwner === self }

    override var acceptsFirstResponder: Bool { isActive }
    override var isFlipped: Bool { true }

    func setActive(_ active: Bool) {
        guard !permanentlyRemoved, isActive != active else { return }
        if !active { releaseKeys(); endRelativeCapture() }
        isActive = active
        preferredFramesPerSecond = active ? Self.foregroundFPS : Self.backgroundFPS
        if active {
            window?.makeFirstResponder(self)
            updateViewport()
            metalRenderer?.requestPresentationRefresh()
            syncGuestResolution()
        } else {
            showLocalCursor()
            if window?.firstResponder === self {
                window?.makeFirstResponder(nil)
            }
        }
    }

    func setNativeDisplayPixels(_ enabled: Bool) {
        guard useNativeDisplayPixels != enabled else { return }
        useNativeDisplayPixels = enabled
        syncGuestResolution()
    }

    /// 建立 CocoaSpice Metal renderer，並在 display channel 就緒後掛上。
    func setupMetal() {
        guard !permanentlyRemoved else { return }
        framebufferOnly = false
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        isPaused = window == nil
        preferredFramesPerSecond = isActive ? Self.foregroundFPS : Self.backgroundFPS
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

    /// Used only by the explicit synthetic-display probe.
    func setSmokePixelHandler(_ handler: ((UInt32, Double) -> Void)?) {
        metalRenderer?.smokePixelHandler = handler
    }

    /// Test-only same-frame spatial readback, never enabled in normal use.
    func setSmokeRegionHandler(_ handler: ((UInt32, UInt32, UInt32, UInt32, UInt32) -> Void)?) {
        metalRenderer?.smokeRegionHandler = handler
    }

    /// Probe the actual cached mapping used by InputRouter, including
    /// the center and letterbox rejection. No input is sent to the guest.
    func smokeMappingMatches(_ frame: RemoteFrame) -> Bool {
        guard let mapping, bounds.width > 0, bounds.height > 0,
              mapping.displaySize == CGSize(width: frame.width, height: frame.height),
              mapping.drawableSize == drawableSize,
              let center = mapping.guestPoint(fromViewPoint: CGPoint(x: bounds.midX, y: bounds.midY), bounds: bounds),
              abs(center.x - CGFloat(frame.width) / 2) < 0.5,
              abs(center.y - CGFloat(frame.height) / 2) < 0.5 else { return false }
        // This probe uses a deliberately wide window with a 4:3 guest.
        return mapping.guestPoint(fromViewPoint: CGPoint(x: 0, y: bounds.midY), bounds: bounds) == nil
    }

    func attachRendererIfNeeded() {
        guard !permanentlyRemoved, window != nil, let metalRenderer else { return }
        if registeredController !== controller {
            registeredController?.detachRenderer(metalRenderer)
            registeredController = controller
        }
        registeredController?.attachRenderer(metalRenderer)
        updateViewport()
    }

    private func detachRegisteredRenderer() {
        if let metalRenderer { registeredController?.detachRenderer(metalRenderer) }
        registeredController = nil
        mapping = nil
    }

    /// 視窗邏輯尺寸變化時請 guest 對齊解析度；agent 未就緒則由 SessionController 暫存。
    /// 必須延到下一輪 run loop：AppKit layout 期間同步寫入 @Observable 會 SIGTRAP。
    /// `size` 只做同步 guard；真正送出的是 layout 結束後的 `bounds`，避免用到尚未穩定的 frame。
    func syncGuestResolution(_ size: CGSize? = nil) {
        let canvasSize = size ?? bounds.size
        guard !permanentlyRemoved, window != nil, isActive,
              canvasSize.width > 0, canvasSize.height > 0 else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.permanentlyRemoved, self.window != nil, self.isActive else { return }
            let latest = self.bounds.size
            guard latest.width > 0, latest.height > 0 else { return }
            let target = GuestResolutionPolicy.viewportSize(logicalSize: latest,
                backingScale: self.window?.backingScaleFactor ?? 1,
                nativePixels: self.useNativeDisplayPixels)
            self.controller?.updateViewportSize(target)
        }
    }

    /// CocoaSpice 以 drawable 中心繪製；必須把 scale 設成與滑鼠對應相同的 letterbox。
    func updateViewport() {
        guard !permanentlyRemoved, window != nil, let renderer = metalRenderer,
              let frame = controller?.displaySize,
              frame.width > 0,
              frame.height > 0,
              drawableSize.width > 0,
              drawableSize.height > 0
        else { mapping = nil; return }
        let next = GuestPointerMapping.aspectFit(
            displaySize: CGSize(width: frame.width, height: frame.height),
            drawableSize: drawableSize
        )
        guard mapping != next else { return }
        mapping = next
        renderer.viewportScale = next.viewportScale
        renderer.viewportOrigin = next.viewportOrigin
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if isActive {
            syncGuestResolution(newSize)
        }
        // 與 guest 解析度分開排隊：letterbox 依賴 MTKView 在 setFrameSize 之後更新的 drawableSize。
        DispatchQueue.main.async { [weak self] in
            self?.updateViewport()
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateViewport()
        syncGuestResolution()
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
        endRelativeCapture()
        if let window {
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didResignKeyNotification,
                object: window
            )
        }
        if newWindow == nil {
            releaseKeys()
            showLocalCursor()
            // A temporarily unhosted canvas must not register again until
            // it has a window. Background tabs with a window stay attached.
            isPaused = true
            detachRegisteredRenderer()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard !permanentlyRemoved, let window else { return }
        isPaused = false
        do {
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowDidResignKey(_:)),
                name: NSWindow.didResignKeyNotification,
                object: window
            )
            if isActive {
                window.makeFirstResponder(self)
            }
        }
        attachRendererIfNeeded()
        // bounds 仍為零時會略過，等後續 setFrameSize 再送。
        syncGuestResolution()
    }

    override func mouseEntered(with event: NSEvent) {
        guard isActive else { return }
        handleMouse(event)
    }

    override func mouseExited(with event: NSEvent) {
        guard isActive, !isRelativeCaptured else { return }
        showLocalCursor()
    }

    /// 失去 key window 時立刻顯示本機游標，避免 NSCursor.hide 殘留到其他 App。
    @objc private func windowDidResignKey(_ notification: Notification) {
        endRelativeCapture()
        releaseKeys()
        showLocalCursor()
    }

    override func mouseMoved(with event: NSEvent) { handleMouse(event) }
    override func mouseDown(with event: NSEvent) {
        guard isActive else { return }
        window?.makeFirstResponder(self)
        if router?.captured == false {
            router?.captured = true
            if beginRelativeCapture(event) { return }
            return
        }
        if !isRelativeCaptured, beginRelativeCapture(event) { return }
        handleMouse(event)
    }
    override func mouseUp(with event: NSEvent) { handleMouse(event) }
    override func mouseDragged(with event: NSEvent) { handleMouse(event) }
    override func rightMouseDown(with event: NSEvent) { handleMouse(event) }
    override func rightMouseUp(with event: NSEvent) { handleMouse(event) }
    /// 右鍵／側鍵按住時 AppKit 改送 *Dragged；不轉發則本機游標已隱藏、guest 也收不到移動。
    override func rightMouseDragged(with event: NSEvent) { handleMouse(event) }
    override func otherMouseDown(with event: NSEvent) {
        guard isActive else { return }
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
        guard isActive, router?.captured == true, controller?.state == .connected,
              controller?.displaySize != nil else {
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
        endRelativeCapture()
        releaseKeys()
        return super.resignFirstResponder()
    }

    private func handleMouse(_ event: NSEvent) {
        guard isActive, let controller, let router, router.captured,
              controller.state == .connected else { return }
        if isRelativeCaptured && !controller.usesServerMouseMode {
            endRelativeCapture()
            releaseKeys()
            return
        }
        // A requested/accepted relative mode is not a capture until the user clicks.
        if controller.relativeMouseRequested && controller.usesServerMouseMode && !isRelativeCaptured {
            showLocalCursor()
            return
        }
        updateViewport()
        if let mapping {
            let location = convert(event.locationInWindow, from: nil)
            let insideDisplay = isRelativeCaptured || mapping.contains(viewPoint: location, bounds: bounds)
            // 只有滑鼠在遠端畫面內才隱藏本機游標；黑邊維持可見。
            updateLocalCursor(hidden: router.captured && insideDisplay)
            if let mouse = router.mouseEvent(from: event, in: self, mapping: mapping, relativeCaptured: isRelativeCaptured) {
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

    func prepareForRemoval() {
        guard !permanentlyRemoved else { return }
        permanentlyRemoved = true
        endRelativeCapture()
        releaseKeys()
        showLocalCursor()
        isActive = false
        isPaused = true
        detachRegisteredRenderer()
        metalRenderer?.smokePixelHandler = nil
        metalRenderer?.smokeRegionHandler = nil
        delegate = nil
        metalRenderer = nil
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
    }

    func updateCaptureEligibility(requested: Bool, connected: Bool, hasDisplay: Bool) {
        if lastRelativeRequest != requested || !connected || !hasDisplay {
            // The controller has released remote input; clear local tracking too.
            _ = router?.releaseAll()
            if !requested || !connected || !hasDisplay { endRelativeCapture() }
            if !connected || !hasDisplay { showLocalCursor() }
        }
        lastRelativeRequest = requested
    }

    /// Capture is explicit: an actual click, a key window and an accepted server mode.
    private func beginRelativeCapture(_ event: NSEvent) -> Bool {
        guard isActive, let controller, controller.relativeMouseRequested,
              controller.usesServerMouseMode, let window, window.isKeyWindow,
              NSApp.isActive, window.firstResponder === self, let mapping,
              mapping.contains(viewPoint: convert(event.locationInWindow, from: nil), bounds: bounds)
        else { return false }
        Self.captureOwner?.endRelativeCapture()
        guard CGAssociateMouseAndMouseCursorPosition(0) == .success else { return false }
        Self.captureOwner = self
        priorMouseMovedEvents = window.acceptsMouseMovedEvents
        window.acceptsMouseMovedEvents = true
        updateLocalCursor(hidden: true)
        captureWatchdog = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard let self else { return }
                guard self.isActive, NSApp.isActive, self.window?.isKeyWindow == true,
                      self.window?.firstResponder === self,
                      self.controller?.relativeMouseRequested == true, self.controller?.displaySize != nil,
                      self.controller?.usesServerMouseMode == true else {
                    self.endRelativeCapture()
                    self.releaseKeys()
                    return
                }
            }
        }
        return true
    }

    func endRelativeCapture() {
        captureWatchdog?.cancel()
        captureWatchdog = nil
        guard isRelativeCaptured else { return }
        let result = CGAssociateMouseAndMouseCursorPosition(1)
        if result != .success {
            captureLogger.error("cursor-reassociation-failed")
        }
        Self.captureOwner = nil
        window?.acceptsMouseMovedEvents = priorMouseMovedEvents
        releaseKeys()
        showLocalCursor()
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
        guard isActive, let controller, let router, router.captured,
              controller.state == .connected, controller.displaySize != nil else { return }
        for key in router.keyEvents(from: event) {
            controller.sendKey(key)
        }
    }

    private func isLocalQuitShortcut(_ event: NSEvent) -> Bool {
        event.modifierFlags.contains(.command)
            && event.charactersIgnoringModifiers?.lowercased() == "q"
    }

    private func interceptHotKey(_ event: NSEvent) -> Bool {
        guard isActive, let controller, let router, let profile = controller.profile else { return false }
        if router.matches(profile.toggleFullscreen, event: event) {
            endRelativeCapture()
            releaseKeys()
            window?.toggleFullScreen(nil)
            return true
        }
        if router.matches(profile.releaseCursor, event: event) {
            releaseCapture()
            return true
        }
        if router.matches(profile.secureAttention, event: event) {
            controller.sendSecureAttention()
            return true
        }
        return false
    }

    func releaseCapture() {
        endRelativeCapture()
        router?.captured = false
        releaseKeys()
        showLocalCursor()
        window?.makeFirstResponder(nil)
    }

    private func releaseKeys() {
        guard let controller, let router else { return }
        for event in router.releaseAll() {
            controller.sendKey(event)
        }
        controller.releaseKeys()
    }
}
