import AppKit
import SwiftUI
import MetalKit
import Darwin
@preconcurrency import CocoaSpiceNoUsb
import CocoaSpiceRenderer

@main
struct MacRemoteViewerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 單一 `Window`：Finder 雙擊不可再建 WindowGroup 場景。
        // 第二扇主窗會對同一 SPICE session 再掛 Metal renderer，畫面會黑掉或卡住。
        Window("Mac Remote Viewer", id: "main") {
            ContentView()
                .environment(appDelegate.model)
                .environment(appDelegate.model.settings)
                .environment(\.locale, appDelegate.model.settings.language.locale)
        }
        // Finder 開檔只走 AppDelegate；SwiftUI 若也收 external event 會重建 ContentView，
        // 第一個連線的 Metal renderer 會被卸掉，畫面卡住。
        .handlesExternalEvents(matching: [])
        .windowStyle(.automatic)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.string(.openVVEllipsis, language: appDelegate.model.settings.language)) {
                    appDelegate.model.chooseFile()
                }
                .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu(L10n.string(.menuSession, language: appDelegate.model.settings.language)) {
                Button(L10n.string(.sendCtrlAltDel, language: appDelegate.model.settings.language)) {
                    appDelegate.model.session?.sendSecureAttention()
                }
                .disabled(appDelegate.model.session == nil)
                Button(L10n.string(.releasePointer, language: appDelegate.model.settings.language)) {
                    if let canvas = NSApp.keyWindow?.firstResponder as? RemoteCanvasView {
                        canvas.releaseCapture()
                    } else {
                        appDelegate.model.session?.releaseKeys()
                        NSApp.keyWindow?.makeFirstResponder(nil)
                    }
                }
            }
        }

        Settings {
            SettingsView()
                .environment(appDelegate.model)
                .environment(appDelegate.model.settings)
                .environment(\.locale, appDelegate.model.settings.language.locale)
        }
    }
}

/// Probe-only weak slots avoid retaining a snapshot array of live objects.
@MainActor
private final class WorkspaceLifetimeReference {
    let round: Int
    weak var controller: SessionController?
    weak var canvas: RemoteCanvasView?

    init(round: Int, controller: SessionController) {
        self.round = round
        self.controller = controller
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private let incomingFiles = IncomingURLBuffer()
    // AppKit can deliver positional .vv arguments as normal open-file events,
    // even before applicationDidFinishLaunching. Probe controllers are the
    // exclusive owners of those files; never also import them into AppModel.
    private let probeLaunch = IntegrationProbeLaunch.evaluate(
        arguments: ProcessInfo.processInfo.arguments,
        environment: ProcessInfo.processInfo.environment
    )
    private var isIntegrationProbe: Bool { probeLaunch == .allowed }
    private var portableRegistryDirectory: URL?
    private var isWaitingToPresentMainWindow = false
    /// 已在畫面上、帶 Metal 的那扇主窗。關多餘窗時必須對這個物件，不可改選最前面那扇。
    private weak var keptMainWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard probeLaunch != .denied else {
            print("MRV_PROBE_LAUNCH_DENIED")
            fflush(nil)
            Darwin.exit(2)
        }
        do {
            portableRegistryDirectory = try preparePortableRuntime(
                verifyRegistry: isIntegrationProbe &&
                    ProcessInfo.processInfo.arguments.contains("--startup-smoke-test"),
                integrationProbe: isIntegrationProbe)
        } catch {
            // Do not initialize native libraries using untrusted fallback paths.
            print("MRV_PORTABLE_RUNTIME_FAILED")
            fflush(nil)
            Darwin.exit(1)
        }
        NSWindow.allowsAutomaticWindowTabbing = false
        if !isIntegrationProbe {
            incomingFiles.setHandler { [model] urls in
                model.open(urls: urls)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard probeLaunch == .normal else {
            print("MRV_PROBE_IGNORED_OPEN_URLS count=\(urls.count)")
            return
        }
        incomingFiles.handle(urls)
        presentMainWindowWhenReady()
        closeExtraMainWindowsAfterSceneUpdate()
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        guard probeLaunch == .normal else {
            print("MRV_PROBE_IGNORED_OPEN_FILE")
            return true
        }
        incomingFiles.handle([URL(fileURLWithPath: filename)])
        presentMainWindowWhenReady()
        closeExtraMainWindowsAfterSceneUpdate()
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 安裝後立刻登錄文件類型，否則 Finder「打開方式」可能看不到這個 App。
        let arguments = ProcessInfo.processInfo.arguments
        if !isIntegrationProbe {
            LSRegisterURL(Bundle.main.bundleURL as CFURL, true)
            presentMainWindowWhenReady()
            return
        } else if arguments.contains("--startup-smoke-test") {
            // Startup smoke still requires the actual main window.
            presentMainWindowWhenReady()
        }
        if arguments.contains("--startup-smoke-test") {
            runStartupSmokeTest()
        } else if arguments.contains("--scanout-runtime-probe") || arguments.contains("--scanout-drawable-probe") {
            runScanoutRuntimeProbe(presentDrawable: arguments.contains("--scanout-drawable-probe"))
        } else if let index = arguments.firstIndex(of: "--loopback-tls-probe") {
            guard index + 1 < arguments.count else { Darwin.exit(2) }
            runLoopbackTLSProbe(file: URL(fileURLWithPath: arguments[index + 1]))
        } else if let index = arguments.firstIndex(of: "--loopback-spice-clipboard-reactivate-probe") {
            guard arguments.count == index + 5 else { Darwin.exit(2) }
            runClipboardIsolationProbe(files: arguments[(index + 1)...(index + 2)].map { URL(fileURLWithPath: $0) },
                                       lateRequest: URL(fileURLWithPath: arguments[index + 3]),
                                       lateDelivered: URL(fileURLWithPath: arguments[index + 4]), reactivate: true)
        } else if let index = arguments.firstIndex(of: "--loopback-spice-clipboard-late-probe") {
            guard arguments.count == index + 5 else { Darwin.exit(2) }
            runClipboardIsolationProbe(files: arguments[(index + 1)...(index + 2)].map { URL(fileURLWithPath: $0) },
                                       lateRequest: URL(fileURLWithPath: arguments[index + 3]),
                                       lateDelivered: URL(fileURLWithPath: arguments[index + 4]))
        } else if let index = arguments.firstIndex(of: "--loopback-spice-clipboard-isolation-probe") {
            guard arguments.count == index + 3 else { Darwin.exit(2) }
            runClipboardIsolationProbe(files: arguments[(index + 1)...].map { URL(fileURLWithPath: $0) })
        } else if arguments.contains("--clipboard-security-probe") {
            runClipboardSecurityProbe()
        } else if let index = arguments.firstIndex(of: "--loopback-spice-clipboard-bulk-probe") {
            guard arguments.count == index + 2 else { Darwin.exit(2) }
            runLoopbackSpiceClipboardProbe(file: URL(fileURLWithPath: arguments[index + 1]), bulk: true)
        } else if let index = arguments.firstIndex(of: "--loopback-spice-clipboard-invalid-probe") {
            guard arguments.count == index + 2 else { Darwin.exit(2) }
            runLoopbackSpiceClipboardProbe(file: URL(fileURLWithPath: arguments[index + 1]), invalid: true)
        } else if let index = arguments.firstIndex(of: "--loopback-spice-clipboard-probe") {
            guard arguments.count == index + 2 else { Darwin.exit(2) }
            runLoopbackSpiceClipboardProbe(file: URL(fileURLWithPath: arguments[index + 1]))
        } else if let index = arguments.firstIndex(of: "--loopback-spice-agent-probe") {
            guard arguments.count == index + 3,
                  ["full", "limited", "monitor-full", "monitor-limited", "monitor-resize-full"].contains(arguments[index + 2]) else { Darwin.exit(2) }
            runLoopbackSpiceAgentProbe(file: URL(fileURLWithPath: arguments[index + 1]),
                                       full: arguments[index + 2].hasSuffix("full"),
                                       monitor: arguments[index + 2].hasPrefix("monitor-"),
                                       resize: arguments[index + 2] == "monitor-resize-full")
        } else if let index = arguments.firstIndex(of: "--loopback-spice-auth-probe") {
            guard index + 1 < arguments.count else { Darwin.exit(2) }
            runLoopbackSpiceAuthProbe(file: URL(fileURLWithPath: arguments[index + 1]))
        } else if let index = arguments.firstIndex(of: "--loopback-spice-display-probe") {
            guard index + 1 < arguments.count else { Darwin.exit(2) }
            runLoopbackSpiceDisplayProbe(file: URL(fileURLWithPath: arguments[index + 1]))
        } else if let index = arguments.firstIndex(of: "--loopback-spice-partial-probe") {
            guard arguments.count == index + 2 else { Darwin.exit(2) }
            runLoopbackSpiceDisplayProbe(file: URL(fileURLWithPath: arguments[index + 1]), partial: true)
        } else if let index = arguments.firstIndex(of: "--loopback-spice-wrapper-probe") {
            guard arguments.count == index + 5 else { Darwin.exit(2) }
            runLoopbackSpiceWrapperProbe(files: arguments[(index + 1)...].map {
                URL(fileURLWithPath: $0)
            })
        } else if let index = arguments.firstIndex(of: "--loopback-spice-workspace-probe") {
            guard arguments.count == index + 5 else { Darwin.exit(2) }
            runLoopbackSpiceWorkspaceProbe(files: arguments[(index + 1)...].map {
                URL(fileURLWithPath: $0)
            })
        } else if let index = arguments.firstIndex(of: "--loopback-spice-multi-probe") {
            guard arguments.count == index + 5 else { Darwin.exit(2) }
            runLoopbackSpiceMultiProbe(files: arguments[(index + 1)...].map {
                URL(fileURLWithPath: $0)
            })
        }
    }

    /// Host the production SwiftUI workspace in an isolated test window. The
    /// normal application scene remains empty; no second renderer per session.
    private func runLoopbackSpiceWorkspaceProbe(files: [URL]) {
        Task { @MainActor in
            let workspaceModel = AppModel()
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 960, height: 720),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            // Hold the hosting view through the window only, so the final
            // diagnostic can remove it without retaining it in the probe.
            window.contentView = NSHostingView(rootView: ContentView()
                .environment(workspaceModel)
                .environment(workspaceModel.settings)
                .environment(\.locale, workspaceModel.settings.language.locale))
            let expected: [Set<UInt32>] = [
                [0xff0000, 0x00ff00], [0x0000ff, 0xffff00],
                [0x00ffff, 0xff00ff], [0xffffff, 0x808080],
            ]
            var observed = Array(repeating: Set<UInt32>(), count: 4)
            var foreign = Set<Int>()
            var identities: [String: ObjectIdentifier] = [:]
            var original: [SessionController] = []
            var live = Set(0..<4)
            var generation = 0
            var usedIDs = Set<String>()
            var lifetime: [String: WorkspaceLifetimeReference] = [:]
            var batch = 0

            @MainActor func canvases(in view: NSView) -> [RemoteCanvasView] {
                if let canvas = view as? RemoteCanvasView { return [canvas] }
                return view.subviews.flatMap { canvases(in: $0) }
            }
            @MainActor func currentCanvases() -> [RemoteCanvasView] {
                guard let host = window.contentView else { return [] }
                return canvases(in: host)
            }
            @MainActor func reportLifetime(_ round: Int) {
                let controllerCount = lifetime.values.reduce(0) { $0 + ($1.controller == nil ? 0 : 1) }
                let canvasCount = lifetime.values.reduce(0) { $0 + ($1.canvas == nil ? 0 : 1) }
                print("MRV_WORKSPACE_WEAK round=\(round) controllers=\(controllerCount) canvases=\(canvasCount)")
                for group in 0...round {
                    let refs = lifetime.values.filter { $0.round == group }
                    let controllers = refs.reduce(0) { $0 + ($1.controller == nil ? 0 : 1) }
                    let canvases = refs.reduce(0) { $0 + ($1.canvas == nil ? 0 : 1) }
                    print("MRV_WORKSPACE_WEAK_BATCH sample=\(round) batch=\(group) controllers=\(controllers) canvases=\(canvases)")
                }
            }
            @MainActor func cleanup() {
                generation += 1
                for canvas in currentCanvases() {
                    canvas.setSmokePixelHandler(nil)
                }
                // Keep the host window visible while SwiftUI reconciles the
                // empty workspace. Hiding it here can suspend view updates or
                // let the app terminate before the final assertions run.
                for id in workspaceModel.sessions.map(\.sessionID) {
                    workspaceModel.closeSession(id)
                }
            }

            @MainActor func readProfiles() throws -> [ConnectionProfile] {
                let profiles = try files.map { file in
                    let (data, _) = try FoundationFileAccessor().readIdentified(from: file)
                    let profile = try VVParser().parse(data: data)
                    guard profile.host == "127.0.0.1", profile.proxyURL == nil,
                          profile.ticket.value == "mrv-ci-synthetic-ticket", !profile.deleteSourceFile else {
                        throw SessionError.cancelled
                    }
                    return profile
                }
                guard profiles.count == 4, Set(profiles.map(\.tlsPort)).count == 4,
                      Set(profiles.map(\.sessionID)).count == 4, model.sessions.isEmpty else {
                    throw SessionError.cancelled
                }
                let ids = Set(profiles.map(\.sessionID))
                guard ids.isDisjoint(with: usedIDs) else { throw SessionError.cancelled }
                usedIDs.formUnion(ids)
                return profiles
            }

            @MainActor func openAndMount() async throws {
                guard workspaceModel.sessions.isEmpty, currentCanvases().isEmpty,
                      original.isEmpty else { throw SessionError.cancelled }
                generation += 1
                let currentGeneration = generation
                identities.removeAll()
                observed = Array(repeating: Set<UInt32>(), count: 4)
                foreign.removeAll()
                live = Set(0..<4)
                workspaceModel.workspace.open(try readProfiles())
                original = workspaceModel.sessions
                guard original.count == 4 else { throw SessionError.cancelled }
                for controller in original {
                    lifetime[controller.sessionID] = WorkspaceLifetimeReference(round: batch, controller: controller)
                }
                batch += 1

                // Discover actual NSViewRepresentable children; never manually
                // drive rendering or force the selected state from the probe.
                let mountDeadline = ContinuousClock.now + .seconds(15)
                while ContinuousClock.now < mountDeadline {
                    let views = currentCanvases()
                    if views.count == 4 && Set(views.compactMap { $0.controller?.sessionID }).count == 4 {
                        for view in views {
                            guard let id = view.controller?.sessionID,
                                  let i = original.firstIndex(where: { $0.sessionID == id }) else {
                                throw SessionError.cancelled
                            }
                            identities[id] = ObjectIdentifier(view)
                            lifetime[id]?.canvas = view
                            view.setSmokePixelHandler { pixel, _ in
                                guard currentGeneration == generation else { return }
                                let rgb = pixel & 0x00ffffff
                                if expected[i].contains(rgb) { observed[i].insert(rgb) }
                                else if rgb != 0 { foreign.insert(i) }
                            }
                        }
                        break
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard identities.count == 4 else { throw SessionError.displayTimeout }
            }

            do {
                window.makeKeyAndOrderFront(nil)
                try await openAndMount()

                @MainActor func validateSelection(_ selected: Int) async throws {
                    let selectedID = original[selected].sessionID
                    let deadline = ContinuousClock.now + .seconds(10)
                    var armed = false
                    while ContinuousClock.now < deadline {
                        guard foreign.isEmpty, model.sessions.isEmpty,
                              workspaceModel.selectedSessionID == selectedID,
                              workspaceModel.sessions.count == live.count else {
                            throw SessionError.cancelled
                        }
                        for i in live {
                            if case .failed = original[i].state { throw SessionError.network }
                            if original[i].state == .disconnected { throw SessionError.disconnected }
                        }
                        let views = currentCanvases()
                        let ids = Set(views.compactMap { $0.controller?.sessionID })
                        let expectedIDs = Set(live.map { original[$0].sessionID })
                        var ready = views.count == live.count && ids == expectedIDs
                        for view in views {
                            guard let id = view.controller?.sessionID, expectedIDs.contains(id) else {
                                ready = false
                                continue
                            }
                            guard identities[id] == ObjectIdentifier(view) else {
                                print("MRV_WORKSPACE_RECREATED")
                                throw SessionError.cancelled
                            }
                            let active = id == selectedID
                            if view.window !== window || view.isActive != active ||
                                view.preferredFramesPerSecond != (active ? 60 : 15) {
                                ready = false
                            }
                        }
                        ready = ready && live.allSatisfy {
                            original[$0].state == .connected &&
                            original[$0].displaySize == RemoteFrame(width: 640, height: 480)
                        }
                        if ready {
                            if !armed {
                                observed[selected].removeAll()
                                armed = true
                            } else if observed[selected] == expected[selected] && original[selected].hasRenderedFrame {
                                return
                            }
                        } else {
                            armed = false
                        }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    print("MRV_WORKSPACE_TIMEOUT selected=\(selected) live=\(live.count) views=\(currentCanvases().count) colors=\(observed[selected].count)")
                    throw SessionError.displayTimeout
                }

                // Use exactly the model API used by the production tab buttons.
                // Repeat the same real-view checks across three complete switch cycles.
                let switchOrder = Array(repeating: [0, 1, 2, 3, 0, 2, 1, 3], count: 3).flatMap { $0 }
                for (step, selected) in switchOrder.enumerated() {
                    workspaceModel.selectSession(original[selected].sessionID)
                    try await validateSelection(selected)
                    print("MRV_WORKSPACE_SWITCH_OK step=\(step) selected=\(selected) live=4")
                }
                // Sustained production workspace stress, with monotonic time
                // and current (not high-water) resident memory observations.
                @MainActor func snapshot(_ phase: Int, since start: ContinuousClock.Instant,
                                         marker: String = "MRV_WORKSPACE_SOAK") throws {
                    var info = mach_task_basic_info()
                    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<integer_t>.size)
                    let result = withUnsafeMutablePointer(to: &info) { pointer in
                        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
                        }
                    }
                    var usage = rusage()
                    guard result == KERN_SUCCESS, info.resident_size > 0,
                          Darwin.getrusage(RUSAGE_SELF, &usage) == 0 else {
                        throw SessionError.unknown(code: "workspace-resource-snapshot")
                    }
                    let elapsed = start.duration(to: ContinuousClock.now)
                    let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                    let cpu = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 +
                              Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
                    print("\(marker) phase=\(phase) elapsed-ms=\(Int(seconds * 1000)) rss-bytes=\(info.resident_size) peak-rss-bytes=\(usage.ru_maxrss) cpu-ms=\(Int(cpu * 1000)) live=\(live.count)")
                    fflush(nil)
                }
                let soakStart = ContinuousClock.now
                try snapshot(0, since: soakStart)
                for phase in 1...6 {
                    let selected = (phase - 1) % 4
                    workspaceModel.selectSession(original[selected].sessionID)
                    try await validateSelection(selected)
                    // Keep the same four sessions alive through the entire
                    // interval and check state without driving renderer calls.
                    let checkpoint = soakStart + .seconds(phase * 10)
                    while ContinuousClock.now < checkpoint {
                        guard foreign.isEmpty, model.sessions.isEmpty,
                              workspaceModel.selectedSessionID == original[selected].sessionID,
                              workspaceModel.sessions.count == 4,
                              original.allSatisfy({ $0.state == .connected && $0.displaySize == RemoteFrame(width: 640, height: 480) }) else {
                            throw SessionError.disconnected
                        }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    try await validateSelection(selected)
                    try snapshot(phase, since: soakStart)
                }
                // Restore the selection assumed by the existing close tests.
                workspaceModel.selectSession(original[3].sessionID)
                try await validateSelection(3)
                print("MRV_WORKSPACE_SOAK_OK seconds=60 checkpoints=7")
                // Closing a background session must retain selection and views.
                workspaceModel.closeSession(original[1].sessionID)
                live.remove(1)
                try await validateSelection(3)
                guard original[1].state == .disconnected, original[1].displaySize == nil else {
                    throw SessionError.cancelled
                }
                print("MRV_WORKSPACE_BACKGROUND_CLOSE_OK selected=3 live=3")
                // Closing selected last tab selects its immediate predecessor.
                workspaceModel.closeSession(original[3].sessionID)
                live.remove(3)
                try await validateSelection(2)
                guard original[3].state == .disconnected, original[3].displaySize == nil else {
                    throw SessionError.cancelled
                }
                print("MRV_WORKSPACE_ACTIVE_CLOSE_OK selected=2 live=2")
                print("MRV_WORKSPACE_CLEANUP_BEGIN")
                fflush(nil)
                cleanup()
                let deadline = ContinuousClock.now + .seconds(5)
                while !currentCanvases().isEmpty && ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(50))
                }
                let remainingViews = currentCanvases().count
                let disconnected = original.filter {
                    $0.state == .disconnected && $0.displaySize == nil && !$0.hasRenderedFrame
                }.count
                print("MRV_WORKSPACE_CLEANUP_STATE sessions=\(workspaceModel.sessions.count) views=\(remainingViews) disconnected=\(disconnected) normal=\(model.sessions.count)")
                guard workspaceModel.sessions.isEmpty, workspaceModel.selectedSessionID == nil,
                      remainingViews == 0, model.sessions.isEmpty, disconnected == original.count,
                      foreign.isEmpty else {
                    throw SessionError.cancelled
                }
                live.removeAll()
                try snapshot(7, since: soakStart)

                // Drop the probe's strong references before measuring survivors.
                original.removeAll()
                let churnStart = ContinuousClock.now
                try await Task.sleep(for: .seconds(1))
                try snapshot(0, since: churnStart, marker: "MRV_WORKSPACE_CHURN")
                reportLifetime(0)
                for round in 1...3 {
                    try await openAndMount()
                    for selected in 0..<4 {
                        workspaceModel.selectSession(original[selected].sessionID)
                        try await validateSelection(selected)
                    }
                    print("MRV_WORKSPACE_CHURN_OPEN_OK round=\(round) live=4")
                    cleanup()
                    let closeDeadline = ContinuousClock.now + .seconds(5)
                    while !currentCanvases().isEmpty && ContinuousClock.now < closeDeadline {
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    guard workspaceModel.sessions.isEmpty, workspaceModel.selectedSessionID == nil,
                          currentCanvases().isEmpty, model.sessions.isEmpty, foreign.isEmpty,
                          original.allSatisfy({ $0.state == .disconnected && $0.displaySize == nil && !$0.hasRenderedFrame }) else {
                        throw SessionError.cancelled
                    }
                    live.removeAll()
                    original.removeAll()
                    // Allow queued callbacks/autorelease pools to settle.
                    try await Task.sleep(for: .seconds(1))
                    try snapshot(round, since: churnStart, marker: "MRV_WORKSPACE_CHURN")
                    reportLifetime(round)
                    print("MRV_WORKSPACE_CHURN_CLOSE_OK round=\(round) live=0 views=0")
                }
                guard usedIDs.count == 16, lifetime.count == 16 else { throw SessionError.cancelled }
                // Distinguish a retained SwiftUI view graph from a reference
                // surviving after removal of the hosting view. No forced GC.
                let before = lifetime.values.reduce(0) { $0 + ($1.controller == nil ? 0 : 1) }
                window.contentView = NSView(frame: .zero)
                let settle = ContinuousClock.now + .seconds(5)
                while ContinuousClock.now < settle {
                    if lifetime.values.allSatisfy({ $0.controller == nil && $0.canvas == nil }) { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                let after = lifetime.values.reduce(0) { $0 + ($1.controller == nil ? 0 : 1) }
                let views = lifetime.values.reduce(0) { $0 + ($1.canvas == nil ? 0 : 1) }
                print("MRV_WORKSPACE_WEAK_UNHOST before=\(before) controllers=\(after) canvases=\(views)")
                print("MRV_WORKSPACE_CHURN_OK cycles=4 sessions=16")
                print("MRV_PROBE_WORKSPACE_EMPTY")
                print("MRV_WORKSPACE_OK")
                fflush(nil)
                window.orderOut(nil)
                Darwin.exit(0)
            } catch {
                print("MRV_WORKSPACE_FAILED error=\(error)")
                cleanup()
                fflush(nil)
                window.orderOut(nil)
                Darwin.exit(1)
            }
        }
    }

    /// Production session/adapter/CocoaSpice path without any remote Metal canvas.
    private func runLoopbackSpiceWrapperProbe(files: [URL]) {
        Task { @MainActor in
            var controllers: [SessionController] = []
            do {
                let profiles = try files.map { file in
                    let (data, _) = try FoundationFileAccessor().readIdentified(from: file)
                    let profile = try VVParser().parse(data: data)
                    guard profile.host == "127.0.0.1", profile.proxyURL == nil,
                          profile.ticket.value == "mrv-ci-synthetic-ticket", !profile.deleteSourceFile else {
                        throw SessionError.cancelled
                    }
                    return profile
                }
                guard profiles.count == 4, Set(profiles.map(\.tlsPort)).count == 4 else {
                    throw SessionError.cancelled
                }
                for _ in profiles {
                    let controller = SessionController(engine: SpiceEngineAdapter(),
                        connectionTimeout: .seconds(8), displayTimeout: .seconds(12))
                    controller.setClipboardSharingEnabled(false)
                    controllers.append(controller)
                }
                for i in profiles.indices { controllers[i].open(profiles[i]) }
                let deadline = ContinuousClock.now + .seconds(15)
                var stableSince: ContinuousClock.Instant?
                var passed = false
                while ContinuousClock.now < deadline {
                    for i in controllers.indices {
                        if case .failed(let error) = controllers[i].state {
                            print("MRV_WRAPPER_FAILED session=\(i) error=\(error)")
                            throw SessionError.network
                        }
                        if controllers[i].state == .disconnected {
                            print("MRV_WRAPPER_DISCONNECTED session=\(i)")
                            throw SessionError.disconnected
                        }
                    }
                    if controllers.allSatisfy({
                        $0.state == .connected && $0.displaySize == RemoteFrame(width: 640, height: 480)
                    }) {
                        if stableSince == nil { stableSince = ContinuousClock.now }
                        if let start = stableSince, start.duration(to: ContinuousClock.now) >= .seconds(2) {
                            passed = true
                            break
                        }
                    } else {
                        stableSince = nil
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard passed, model.sessions.isEmpty else {
                    throw SessionError.displayTimeout
                }
                print("MRV_PROBE_WORKSPACE_EMPTY")
                for controller in controllers { controller.cancel() }
                try await Task.sleep(for: .milliseconds(500))
                guard controllers.allSatisfy({ $0.state == .disconnected && $0.displaySize == nil }) else {
                    throw SessionError.cancelled
                }
                print("MRV_WRAPPER_MULTI_OK")
                fflush(nil)
                Darwin.exit(0)
            } catch {
                for i in controllers.indices {
                    print("MRV_WRAPPER_FINAL session=\(i) state=\(controllers[i].state) display=\(controllers[i].displaySize != nil)")
                    controllers[i].cancel()
                }
                fflush(nil)
                Darwin.exit(1)
            }
        }
    }

    /// Four simultaneous real connections, one shared GPU device, four isolated canvases.
    /// All canvases remain visible in a test-only grid so a headless/occluded view
    /// cannot prevent the background rendering checks. No clipboard or guest input.
    private func runLoopbackSpiceMultiProbe(files: [URL]) {
        Task { @MainActor in
            let expected: [Set<UInt32>] = [
                [0xff0000, 0x00ff00], [0x0000ff, 0xffff00],
                [0x00ffff, 0xff00ff], [0xffffff, 0x808080],
            ]
            let rect = CGRect(x: 0, y: 0, width: 640, height: 480)
            let window = NSWindow(contentRect: rect, styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            var controllers: [SessionController] = []
            var canvases: [RemoteCanvasView] = []
            var observed = Array(repeating: Set<UInt32>(), count: 4)
            var completedSamples = Array(repeating: 0, count: 4)
            var timedSamples = Array(repeating: 0, count: 4)
            var totalGPUSeconds = Array(repeating: 0.0, count: 4)
            var maxGPUSeconds = Array(repeating: 0.0, count: 4)
            var foreign = Set<Int>()
            var live = Set(0..<4)
            @MainActor func cleanUp() {
                for canvas in canvases {
                    canvas.setSmokePixelHandler(nil)
                    canvas.prepareForRemoval()
                }
                for controller in controllers { controller.cancel() }
                window.orderOut(nil)
            }
            do {
                let profiles = try files.map { file in
                    let (data, _) = try FoundationFileAccessor().readIdentified(from: file)
                    let profile = try VVParser().parse(data: data)
                    guard profile.host == "127.0.0.1", profile.proxyURL == nil,
                          profile.ticket.value == "mrv-ci-synthetic-ticket", !profile.deleteSourceFile else {
                        throw SessionError.cancelled
                    }
                    return profile
                }
                guard profiles.count == 4, Set(profiles.map(\.tlsPort)).count == 4,
                      let device = MTLCreateSystemDefaultDevice() else {
                    throw SessionError.engineUnavailable
                }
                let grid = NSView(frame: rect)
                window.contentView = grid
                for i in 0..<4 {
                    let controller = SessionController(engine: SpiceEngineAdapter(),
                        connectionTimeout: .seconds(8), displayTimeout: .seconds(12))
                    controller.setClipboardSharingEnabled(false)
                    let canvas = RemoteCanvasView(
                        frame: CGRect(x: (i % 2) * 320, y: (i / 2) * 240, width: 320, height: 240),
                        device: device)
                    canvas.controller = controller
                    canvas.setActive(i == 0)
                    canvas.setupMetal()
                    canvas.setSmokePixelHandler { pixel, gpuSeconds in
                        completedSamples[i] += 1
                        if gpuSeconds.isFinite && gpuSeconds > 0 && gpuSeconds < 60 {
                            timedSamples[i] += 1
                            totalGPUSeconds[i] += gpuSeconds
                            maxGPUSeconds[i] = max(maxGPUSeconds[i], gpuSeconds)
                        }
                        let rgb = pixel & 0x00ffffff
                        // Initial empty black surfaces are allowed, but cannot
                        // satisfy either expected color. Any foreign color fails.
                        if expected[i].contains(rgb) { observed[i].insert(rgb) }
                        else if rgb != 0 {
                            if foreign.insert(i).inserted {
                                print("MRV_MULTI_FOREIGN session=\(i) rgb=\(String(rgb, radix: 16))")
                            }
                        }
                    }
                    grid.addSubview(canvas)
                    controllers.append(controller)
                    canvases.append(canvas)
                }
                window.makeKeyAndOrderFront(nil)
                // Open all four before yielding to the main actor.
                for i in 0..<4 { controllers[i].open(profiles[i]) }

                // getrusage on macOS reports cumulative process CPU time and
                // peak resident bytes (not current RSS or GPU memory).
                @MainActor func resourceSnapshot() throws -> (cpu: Double, peakRSS: Int64) {
                    var usage = rusage()
                    guard Darwin.getrusage(RUSAGE_SELF, &usage) == 0 else {
                        throw SessionError.unknown(code: "getrusage")
                    }
                    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
                    let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
                    return (user + system, Int64(usage.ru_maxrss))
                }

                @MainActor func validatePhase(active: Int) async throws {
                    for i in live { canvases[i].setActive(i == active) }
                    // Reset observations for each phase: require fresh draws, not
                    // cached success from the previous foreground selection.
                    for i in live { observed[i].removeAll() }
                    let deadline = ContinuousClock.now + .seconds(16)
                    var sampleStart: ContinuousClock.Instant?
                    var startCPU = 0.0
                    while ContinuousClock.now < deadline {
                        guard foreign.isEmpty else { throw SessionError.unknown(code: "foreign-color") }
                        for i in live {
                            let controller = controllers[i]
                            if case .failed(let error) = controller.state {
                                print("MRV_MULTI_SESSION_FAILED session=\(i) error=\(error)")
                                throw SessionError.network
                            }
                            if controller.state == .disconnected {
                                print("MRV_MULTI_SESSION_DISCONNECTED session=\(i)")
                                throw SessionError.disconnected
                            }
                            canvases[i].attachRendererIfNeeded()
                            canvases[i].updateViewport()
                        }
                        let ready = live.allSatisfy { i in
                            controllers[i].state == .connected &&
                            controllers[i].displaySize == RemoteFrame(width: 640, height: 480) &&
                            controllers[i].hasRenderedFrame &&
                            canvases[i].preferredFramesPerSecond == (i == active ? 60 : 15)
                        }
                        if !ready {
                            sampleStart = nil
                        } else if let start = sampleStart {
                            let duration = start.duration(to: ContinuousClock.now)
                            if duration >= .seconds(3),
                               live.allSatisfy({ observed[$0] == expected[$0] && completedSamples[$0] > 0 }) {
                                let end = try resourceSnapshot()
                                let seconds = Double(duration.components.seconds) +
                                    Double(duration.components.attoseconds) / 1e18
                                let elapsedMS = Int(seconds * 1000)
                                let cpuMS = Int(max(0, end.cpu - startCPU) * 1000)
                                print("MRV_MULTI_RESOURCES active=\(active) live=\(live.count) elapsed-ms=\(elapsedMS) cpu-ms=\(cpuMS) peak-rss-bytes=\(end.peakRSS)")
                                for i in live.sorted() {
                                    print("MRV_MULTI_SAMPLES active=\(active) live=\(live.count) session=\(i) count=\(completedSamples[i]) elapsed-ms=\(elapsedMS)")
                                    let totalNS = Int64((totalGPUSeconds[i] * 1e9).rounded())
                                    let maxNS = Int64((maxGPUSeconds[i] * 1e9).rounded())
                                    print("MRV_MULTI_GPU active=\(active) live=\(live.count) session=\(i) valid=\(timedSamples[i]) unavailable=\(completedSamples[i] - timedSamples[i]) total-ns=\(totalNS) max-ns=\(maxNS)")
                                }
                                return
                            }
                        } else if live.allSatisfy({ observed[$0] == expected[$0] }) {
                            startCPU = try resourceSnapshot().cpu
                            for i in live {
                                completedSamples[i] = 0
                                timedSamples[i] = 0
                                totalGPUSeconds[i] = 0
                                maxGPUSeconds[i] = 0
                                observed[i].removeAll()
                            }
                            sampleStart = ContinuousClock.now
                        }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    for i in live.sorted() {
                        print("MRV_MULTI_DIAGNOSTIC session=\(i) connected=\(controllers[i].state == .connected) rendered=\(controllers[i].hasRenderedFrame) samples=\(observed[i].count)")
                    }
                    throw SessionError.displayTimeout
                }

                for active in 0..<4 {
                    try await validatePhase(active: active)
                    print("MRV_MULTI_PHASE_OK active=\(active) live=4 targets=60,15")
                }
                // Record all first-frame measurements before closing a controller,
                // which deliberately resets its frame diagnostics.
                for i in 0..<4 {
                    if let elapsed = controllers[i].firstFrameMilliseconds {
                        print("MRV_MULTI_FIRST_FRAME session=\(i) ms=\(elapsed)")
                    }
                }
                // Disconnect one renderer while the remaining three continue.
                canvases[1].setSmokePixelHandler(nil)
                canvases[1].prepareForRemoval()
                canvases[1].removeFromSuperview()
                controllers[1].cancel()
                live.remove(1)
                try await validatePhase(active: 2)
                guard controllers[1].state == .disconnected,
                      controllers[1].displaySize == nil, !controllers[1].hasRenderedFrame,
                      foreign.isEmpty else { throw SessionError.cancelled }
                guard model.sessions.isEmpty else { throw SessionError.cancelled }
                print("MRV_PROBE_WORKSPACE_EMPTY")
                print("MRV_MULTI_CLOSE_OK live=3")
                cleanUp()
                print("MRV_MULTI_OK")
                fflush(nil)
                Darwin.exit(0)
            } catch {
                for i in controllers.indices {
                    print("MRV_MULTI_FINAL session=\(i) connected=\(controllers[i].state == .connected) rendered=\(controllers[i].hasRenderedFrame) samples=\(observed[i].count)")
                }
                cleanUp()
                print("MRV_MULTI_FAILED")
                fflush(nil)
                Darwin.exit(1)
            }
        }
    }

    /// Exercise actual display callbacks and Metal completion using the production canvas.
    private func runScanoutRuntimeProbe(presentDrawable: Bool = false) {
        Task { @MainActor in
            do {
                guard model.sessions.isEmpty, let device = MTLCreateSystemDefaultDevice() else {
                    throw SessionError.engineUnavailable
                }
                let engine = SpiceEngineAdapter()
                try engine.startWorker()
                let view = MTKView(frame: CGRect(x: 0, y: 0, width: 64, height: 64), device: device)
                view.isPaused = true
                let renderer = CSMetalRenderer(metalKitView: view)
                let replacementView = MTKView(frame: view.frame, device: device)
                replacementView.isPaused = true
                let replacement = CSMetalRenderer(metalKitView: replacementView)
                var window: NSWindow?
                if presentDrawable {
                    let frame = CGRect(x: 0, y: 0, width: 256, height: 256)
                    let probeWindow = NSWindow(contentRect: frame, styleMask: [.titled, .closable],
                                               backing: .buffered, defer: false)
                    probeWindow.isReleasedWhenClosed = false
                    view.frame = CGRect(origin: .zero, size: frame.size)
                    view.framebufferOnly = false
                    view.colorPixelFormat = .bgra8Unorm
                    view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
                    view.autoResizeDrawable = false
                    probeWindow.contentView = view
                    probeWindow.makeKeyAndOrderFront(nil)
                    view.drawableSize = CGSize(width: 64, height: 64)
                    view.delegate = renderer
                    renderer.viewportScale = 1
                    view.preferredFramesPerSecond = 60
                    view.enableSetNeedsDisplay = false
                    view.isPaused = false
                    window = probeWindow
                }
                // CocoaSpice delivers completion on the main queue after
                // worker cleanup. The parent process enforces a deadline.
                let ok: Bool = await withCheckedContinuation { continuation in
                    CSDisplay.pve_testScanout(renderer, replacement: replacement,
                        observe: presentDrawable ? { stage, completed in
                            // Only one sample is accepted for each stage.
                            // Captured callbacks from previously submitted draws
                            // cannot complete this stage a second time.
                            var consumed = false
                            renderer.smokeRegionHandler = { center, a, b, c, d in
                                guard !consumed else { return }
                                consumed = true
                                renderer.smokeRegionHandler = nil
                                let wanted: UInt32 = stage == 1 ? 0xffff00 : 0x0000ff
                                let exterior = [a,b,c,d].map { $0 & 0x00ffffff }
                                let actual = center & 0x00ffffff
                                let ok = actual == wanted && exterior.allSatisfy { $0 == 0xffff00 }
                                if !ok {
                                    print("MRV_SCANOUT_DRAWABLE_MISMATCH stage=\(stage) center=\(actual) exterior=\(exterior)")
                                }
                                completed(ok)
                            }
                        } : nil) { ok in
                        continuation.resume(returning: ok)
                    }
                }
                withExtendedLifetime(view) {}
                withExtendedLifetime(renderer) {}
                withExtendedLifetime(replacementView) {}
                withExtendedLifetime(replacement) {}
                renderer.smokeRegionHandler = nil
                view.isPaused = true
                view.delegate = nil
                window?.orderOut(nil)
                guard ok else { throw SessionError.cancelled }
                print("MRV_SCANOUT_RUNTIME_OK")
                fflush(nil)
                Darwin.exit(0)
            } catch {
                print("MRV_SCANOUT_RUNTIME_FAILED")
                fflush(nil)
                Darwin.exit(1)
            }
        }
    }

    private func runLoopbackSpiceDisplayProbe(file: URL, partial: Bool = false) {
        Task { @MainActor in
            let engine = SpiceEngineAdapter()
            let controller = SessionController(engine: engine,
                connectionTimeout: .seconds(8), displayTimeout: .seconds(12))
            let frame = CGRect(x: 0, y: 0, width: 640, height: 480)
            let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            do {
                let (data, _) = try FoundationFileAccessor().readIdentified(from: file)
                let profile = try VVParser().parse(data: data)
                guard profile.host == "127.0.0.1", profile.proxyURL == nil,
                      profile.ticket.value == "mrv-ci-synthetic-ticket", !profile.deleteSourceFile,
                      let device = MTLCreateSystemDefaultDevice() else {
                    throw SessionError.cancelled
                }
                controller.setClipboardSharingEnabled(false)
                let canvas = RemoteCanvasView(frame: frame, device: device)
                canvas.controller = controller
                canvas.setupMetal()
                window.contentView = canvas
                window.makeKeyAndOrderFront(nil)
                for round in 0..<2 {
                    var colors = Set<UInt32>()
                    var regionMismatch = false
                    var sawPatch = false
                    if partial {
                        canvas.setSmokeRegionHandler { center, a, b, c, d in
                            let rgb = center & 0x00ffffff
                            let outside = [a, b, c, d].map { $0 & 0x00ffffff }
                            let isPatch = rgb == 0xff0000 || rgb == 0x00ff00
                            // An initial empty surface may be observed before the
                            // first real frame. Once initialized, every sample
                            // must preserve the four blue exterior points.
                            if outside.allSatisfy({ $0 == 0x0000ff }) &&
                                (isPatch || (!sawPatch && rgb == 0x0000ff)) {
                                if isPatch { sawPatch = true; colors.insert(rgb) }
                            } else if sawPatch || rgb != 0 || outside.contains(where: { $0 != 0 }) {
                                regionMismatch = true
                                print("MRV_PARTIAL_MISMATCH center=\(String(rgb, radix: 16)) outside=\(outside)")
                            }
                        }
                    } else {
                        canvas.setSmokePixelHandler { pixel, _ in
                            let rgb = pixel & 0x00ffffff
                            if colors.count < 16 && colors.insert(rgb).inserted {
                                print("MRV_PIXEL_SAMPLE round=\(round + 1) rgb=\(String(rgb, radix: 16))")
                            }
                        }
                    }
                    controller.open(profile)
                    let deadline = ContinuousClock.now + .seconds(15)
                    while ContinuousClock.now < deadline {
                        if regionMismatch { throw SessionError.unknown(code: "partial-pixel-mismatch") }
                        if case .failed = controller.state { throw SessionError.network }
                        if controller.state == .disconnected { throw SessionError.disconnected }
                        canvas.attachRendererIfNeeded()
                        canvas.updateViewport()
                        if controller.state == .connected,
                           controller.displaySize == RemoteFrame(width: 640, height: 480),
                           controller.hasRenderedFrame, colors.contains(0x00ff0000),
                           colors.contains(0x0000ff00) { break }
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    guard controller.state == .connected,
                          controller.displaySize == RemoteFrame(width: 640, height: 480),
                          controller.hasRenderedFrame, let elapsed = controller.firstFrameMilliseconds,
                          colors.contains(0x00ff0000), colors.contains(0x0000ff00),
                          !regionMismatch, !partial || model.sessions.isEmpty else {
                        print("MRV_DISPLAY_DIAGNOSTIC connected=\(controller.state == .connected) display=\(controller.displaySize != nil) rendered=\(controller.hasRenderedFrame) samples=\(colors.count)")
                        throw SessionError.displayTimeout
                    }
                    if partial {
                        print("MRV_SPICE_PARTIAL_ROUND_OK \(round + 1) 640x480 center=red,green exterior=blue,blue,blue,blue")
                    } else {
                        print("MRV_SPICE_DISPLAY_ROUND_OK \(round + 1) 640x480 first-frame-ms=\(elapsed) pixels=red,green")
                    }
                    canvas.setSmokePixelHandler(nil)
                    canvas.setSmokeRegionHandler(nil)
                    controller.cancel()
                    try await Task.sleep(for: .milliseconds(200))
                    guard controller.state == .disconnected, !controller.hasRenderedFrame,
                          controller.displaySize == nil else { throw SessionError.cancelled }
                }
                canvas.prepareForRemoval()
                window.orderOut(nil)
                print(partial ? "MRV_SPICE_PARTIAL_OK" : "MRV_SPICE_DISPLAY_OK")
                fflush(nil)
                Darwin.exit(0)
            } catch {
                controller.cancel()
                window.orderOut(nil)
                print("MRV_SPICE_DISPLAY_FAILED")
                fflush(nil)
                Darwin.exit(1)
            }
        }
    }

    /// A real SPICE server supplies the main channel, not a guest display.
    /// Reuse the same engine/controller to exercise disconnect and reconnect.
    /// Exercise actual guest-agent capability updates through the packaged
    /// CocoaSpice main channel, without touching the host clipboard.
    /// Real clipboard protocol through a private named pasteboard. Never read
    /// or write NSPasteboard.general, even on a developer's local machine.
    /// Local production delegate boundary tests. Both adapters point at the
    /// same private named pasteboard, as two tabs do at the system board.
    /// Two genuine TLS Main Channels, production selection policy and one
    /// isolated board. No access to the user's general pasteboard.
    private func runClipboardIsolationProbe(files: [URL], lateRequest: URL? = nil, lateDelivered: URL? = nil,
                                            reactivate: Bool = false) {
        Task { @MainActor in
            let board = NSPasteboard.withUniqueName()
            let workspace = SessionWorkspace { _ in
                SessionController(engine: SpiceEngineAdapter(pasteboardName: board.name),
                                  connectionTimeout: .seconds(8), displayTimeout: .zero)
            }
            @MainActor func closeAll() {
                for id in workspace.sessions.map(\.sessionID) { workspace.close(id) }
            }
            do {
                let profiles = try files.map { file in
                    let (data, _) = try FoundationFileAccessor().readIdentified(from: file)
                    return try VVParser().parse(data: data)
                }
                guard profiles.count == 2,
                      Set(profiles.map(\.tlsPort)).count == 2,
                      profiles.allSatisfy({ $0.host == "127.0.0.1" && $0.proxyURL == nil &&
                          $0.ticket.value == "mrv-ci-synthetic-ticket" && !$0.deleteSourceFile }),
                      model.sessions.isEmpty else { throw SessionError.cancelled }
                board.clearContents()
                workspace.open(profiles)
                let sessions = workspace.sessions
                guard sessions.count == 2, workspace.selectedSessionID == sessions[1].sessionID else {
                    throw SessionError.cancelled
                }
                let deadline = ContinuousClock.now + .seconds(10)
                while !sessions.allSatisfy({ $0.state == .connected && $0.agent.isConnected && $0.agent.supportsClipboard }) {
                    guard ContinuousClock.now < deadline else { throw SessionError.network }
                    try await Task.sleep(for: .milliseconds(50))
                }
                let unexpected = "MRV inactive guest must not overwrite"
                let lateText = "MRV delayed inactive guest overwrite"
                @MainActor func exchange(index: Int, host: String, guest: String) async throws {
                    guard workspace.selectedSessionID == sessions[index].sessionID else { throw SessionError.cancelled }
                    board.clearContents()
                    guard board.setString(host, forType: .string) else { throw SessionError.cancelled }
                    let end = ContinuousClock.now + .seconds(5)
                    while ContinuousClock.now < end {
                        guard sessions.allSatisfy({ $0.state == .connected && $0.agent.isConnected }),
                              board.string(forType: .string) != unexpected,
                              board.string(forType: .string) != lateText else { throw SessionError.cancelled }
                        if board.string(forType: .string) == guest { return }
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    throw SessionError.network
                }
                try await exchange(index: 1, host: "MRV host B 繁中", guest: "MRV guest B ☀️")
                print("MRV_CLIP_ISOLATION_B_OK")
                // Keep A inactive through its independently scheduled
                // 1s/1.2s/1.4s server attempts, checking the selected value.
                let hold = ContinuousClock.now + .seconds(3)
                while ContinuousClock.now < hold {
                    guard board.string(forType: .string) == "MRV guest B ☀️",
                          workspace.selectedSessionID == sessions[1].sessionID,
                          sessions.allSatisfy({ $0.state == .connected && $0.agent.isConnected }) else {
                        throw SessionError.cancelled
                    }
                    try await Task.sleep(for: .milliseconds(25))
                }
                print("MRV_CLIP_ISOLATION_BACKGROUND_OK")
                if let lateRequest {
                    let deadline = ContinuousClock.now + .seconds(8)
                    while !FileManager.default.fileExists(atPath: lateRequest.path) {
                        guard ContinuousClock.now < deadline,
                              board.string(forType: .string) == "MRV guest B ☀️",
                              sessions.allSatisfy({ $0.state == .connected && $0.agent.isConnected }) else {
                            throw SessionError.cancelled
                        }
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    print("MRV_CLIP_LATE_REQUEST_CONFIRMED")
                }
                workspace.select(sessions[0].sessionID)
                try await exchange(index: 0, host: "MRV host A 繁中", guest: "MRV guest A 🚀")
                print("MRV_CLIP_ISOLATION_A_OK")
                if let lateDelivered {
                    if reactivate {
                        workspace.select(sessions[1].sessionID)
                        guard workspace.selectedSessionID == sessions[1].sessionID else { throw SessionError.cancelled }
                        print("MRV_CLIP_LATE_REACTIVATED")
                    }
                    let count = board.changeCount
                    // Python permits B's delayed response only after observing
                    // this marker, after A's exchange (and optional B reactivation).
                    print("MRV_CLIP_LATE_A_READY")
                    fflush(nil)
                    let deadline = ContinuousClock.now + .seconds(8)
                    while !FileManager.default.fileExists(atPath: lateDelivered.path) {
                        guard ContinuousClock.now < deadline, board.changeCount == count,
                              board.string(forType: .string) == "MRV guest A 🚀",
                              sessions.allSatisfy({ $0.state == .connected && $0.agent.isConnected }) else {
                            throw SessionError.cancelled
                        }
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    let grace = ContinuousClock.now + .seconds(1)
                    while ContinuousClock.now < grace {
                        guard board.changeCount == count, board.string(forType: .string) == "MRV guest A 🚀",
                              sessions.allSatisfy({ $0.state == .connected && $0.agent.isConnected }) else {
                            throw SessionError.cancelled
                        }
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    print("MRV_CLIP_LATE_PRESERVED_OK")
                }
                let settle = ContinuousClock.now + .seconds(1)
                while ContinuousClock.now < settle {
                    guard board.string(forType: .string) == "MRV guest A 🚀",
                          sessions.allSatisfy({ $0.state == .connected && $0.agent.isConnected }) else {
                        throw SessionError.cancelled
                    }
                    try await Task.sleep(for: .milliseconds(25))
                }
                closeAll()
                guard workspace.sessions.isEmpty, workspace.selectedSessionID == nil,
                      sessions.allSatisfy({ $0.state == .disconnected }), model.sessions.isEmpty else {
                    throw SessionError.cancelled
                }
                board.releaseGlobally()
                print("MRV_CLIP_ISOLATION_OK")
                fflush(nil)
                Darwin.exit(0)
            } catch {
                closeAll()
                board.releaseGlobally()
                print("MRV_CLIP_ISOLATION_FAILED")
                fflush(nil)
                Darwin.exit(1)
            }
        }
    }

    private func runClipboardSecurityProbe() {
        Task { @MainActor in
            let board = NSPasteboard.withUniqueName()
            let first = CocoaSpicePasteboard(pasteboardName: board.name)
            let second = CocoaSpicePasteboard(pasteboardName: board.name)
            let limit = 16 * 1024 * 1024
            let original = "MRV private board 繁中"
            do {
                board.clearContents()
                guard board.setString(original, forType: .string) else { throw SessionError.cancelled }
                first.startPolling()
                guard first.string() == original, second.string() == nil,
                      !second.canReadItem(for: .string) else { throw SessionError.cancelled }
                first.setData(Data([0xff, 0xfe]), for: .string)
                first.setData(Data(repeating: 65, count: limit + 1), for: .string)
                second.setString("inactive write")
                second.clearContents()
                try await Task.sleep(for: .milliseconds(100))
                guard board.string(forType: .string) == original else { throw SessionError.cancelled }
                print("MRV_CLIP_SECURITY_INVALID_OVERSIZE_DISABLED_OK")

                // Enqueue a guest write but change tab before the MainActor
                // drain can run. Re-enabling the old delegate must not revive it.
                first.setString("old queued write")
                first.stopPolling()
                second.startPolling()
                second.setString("selected tab")
                try await Task.sleep(for: .milliseconds(100))
                guard board.string(forType: .string) == "selected tab",
                      first.data(for: .string) == nil, second.string() == "selected tab" else {
                    throw SessionError.cancelled
                }
                second.stopPolling()
                first.startPolling()
                first.setString("stale generation")
                first.stopPolling()
                first.startPolling()
                try await Task.sleep(for: .milliseconds(100))
                guard board.string(forType: .string) == "selected tab" else { throw SessionError.cancelled }
                print("MRV_CLIP_SECURITY_GENERATION_OK")

                first.stopPolling()
                board.clearContents()
                let boundary = Data(repeating: 65, count: limit)
                guard board.setData(boundary, forType: .png),
                      board.setData(boundary, forType: .tiff),
                      board.setData(boundary, forType: NSPasteboard.PasteboardType("public.jpeg")) else {
                    throw SessionError.cancelled
                }
                first.startPolling()
                // Raw bytes here test storage bounds, not image decoding.
                guard first.data(for: .png)?.count == limit,
                      first.data(for: .tiff)?.count == limit,
                      first.data(for: .jpg) == nil else { throw SessionError.cancelled }
                first.stopPolling()
                board.clearContents()
                guard board.setData(Data(repeating: 65, count: limit + 1), forType: .png) else {
                    throw SessionError.cancelled
                }
                first.startPolling()
                guard first.data(for: .png) == nil else { throw SessionError.cancelled }
                print("MRV_CLIP_SECURITY_LIMITS_OK item=16777216 snapshot=33554432")
                first.stopPolling()
                second.stopPolling()
                board.releaseGlobally()
                print("MRV_CLIP_SECURITY_OK")
                fflush(nil)
                Darwin.exit(0)
            } catch {
                first.stopPolling()
                second.stopPolling()
                board.releaseGlobally()
                print("MRV_CLIP_SECURITY_FAILED")
                fflush(nil)
                Darwin.exit(1)
            }
        }
    }

    private func runLoopbackSpiceClipboardProbe(file: URL, invalid: Bool = false, bulk: Bool = false) {
        Task { @MainActor in
            let board = NSPasteboard.withUniqueName()
            let controller = SessionController(engine: SpiceEngineAdapter(pasteboardName: board.name),
                                               connectionTimeout: .seconds(8), displayTimeout: .zero)
            let hostText = "MRV Mac 繁體中文 ☀️\nline-2"
            let guestText = "MRV Guest 測試剪貼簿 🚀\nline-2"
            do {
                let (data, _) = try FoundationFileAccessor().readIdentified(from: file)
                let profile = try VVParser().parse(data: data)
                guard profile.host == "127.0.0.1", profile.proxyURL == nil,
                      profile.ticket.value == "mrv-ci-synthetic-ticket", !profile.deleteSourceFile,
                      model.sessions.isEmpty else { throw SessionError.cancelled }
                board.clearContents()
                controller.setClipboardSharingEnabled(false)
                controller.open(profile)
                let deadline = ContinuousClock.now + .seconds(bulk ? 42 : 20)
                var sent = false
                var received = false
                var recovered = false
                var boundaryReceived = false
                let boundary = String(repeating: "A", count: bulk ? 16 * 1024 * 1024 : 0)
                var preservedChangeCount: Int?
                let recoveredText = "MRV recovered 繁中 🚀"
                while ContinuousClock.now < deadline {
                    if case .failed = controller.state { throw SessionError.network }
                    if controller.state == .disconnected { throw SessionError.disconnected }
                    if controller.state == .connected {
                        if !sent && controller.agent.isConnected && controller.agent.supportsClipboard &&
                            controller.agent.supportsMonitorsConfig {
                            controller.setClipboardSharingEnabled(true)
                            board.clearContents()
                            guard board.setString(hostText, forType: .string) else { throw SessionError.cancelled }
                            sent = true
                            print("MRV_CLIP_HOST_READY")
                        }
                        if sent && !received, let value = board.string(forType: .string),
                           Data(value.utf8) == Data(guestText.utf8) {
                            received = true
                            preservedChangeCount = board.changeCount
                            print("MRV_CLIP_GUEST_UTF8_OK")
                        }
                        if bulk && received && !recovered {
                            // Avoid reading the large pasteboard repeatedly
                            // unless a real change occurs.
                            let count = board.changeCount
                            if count != preservedChangeCount {
                                let value = board.string(forType: .string)
                                if !boundaryReceived && value == boundary {
                                    boundaryReceived = true
                                    preservedChangeCount = count
                                    print("MRV_CLIP_BULK_BOUNDARY_OK bytes=16777216")
                                } else if boundaryReceived && value == recoveredText {
                                    recovered = true
                                    print("MRV_CLIP_BULK_RECOVERY_OK")
                                } else {
                                    throw SessionError.cancelled
                                }
                            }
                        }
                        if invalid && received && !recovered {
                            let value = board.string(forType: .string)
                            if value == recoveredText {
                                recovered = true
                                print("MRV_CLIP_INVALID_RECOVERY_OK")
                            } else {
                                // Reject even a same-value rewrite or a transient
                                // change reverted before this observation.
                                guard value == guestText, board.changeCount == preservedChangeCount else {
                                    throw SessionError.cancelled
                                }
                            }
                        }
                        if received && !controller.agent.isConnected {
                            guard !controller.agent.supportsClipboard, model.sessions.isEmpty,
                                  (!(invalid || bulk) || recovered),
                                  (!bulk || boundaryReceived),
                                  board.string(forType: .string) == ((invalid || bulk) ? recoveredText : guestText) else { throw SessionError.cancelled }
                            controller.setClipboardSharingEnabled(false)
                            controller.cancel()
                            guard controller.state == .disconnected else { throw SessionError.cancelled }
                            board.releaseGlobally()
                            print("MRV_SPICE_CLIPBOARD_OK")
                            fflush(nil)
                            Darwin.exit(0)
                        }
                    }
                    try await Task.sleep(for: .milliseconds(50))
                }
                print("MRV_CLIP_TIMEOUT sent=\(sent) received=\(received)")
                throw SessionError.network
            } catch {
                controller.setClipboardSharingEnabled(false)
                controller.cancel()
                board.releaseGlobally()
                print("MRV_SPICE_CLIPBOARD_FAILED")
                fflush(nil)
                Darwin.exit(1)
            }
        }
    }

    private func runLoopbackSpiceAgentProbe(file: URL, full: Bool, monitor: Bool, resize: Bool) {
        Task { @MainActor in
            let controller = SessionController(engine: SpiceEngineAdapter(),
                resolutionDebounce: .zero, resolutionRetryDelay: resize ? .seconds(3) : .seconds(1),
                resolutionRetryLimit: 1, resolutionPreference: resize ? .keepGuest : .matchWindow,
                connectionTimeout: .seconds(8),
                displayTimeout: monitor ? .seconds(10) : .zero)
            var resizeWindow: NSWindow?
            var resizeCanvas: RemoteCanvasView?
            var colors = Set<UInt32>()
            do {
                let (data, _) = try FoundationFileAccessor().readIdentified(from: file)
                let profile = try VVParser().parse(data: data)
                guard profile.host == "127.0.0.1", profile.proxyURL == nil,
                      profile.ticket.value == "mrv-ci-synthetic-ticket", !profile.deleteSourceFile,
                      model.sessions.isEmpty else { throw SessionError.cancelled }
                controller.setClipboardSharingEnabled(false)
                if resize {
                    guard let device = MTLCreateSystemDefaultDevice() else { throw SessionError.engineUnavailable }
                    let frame = CGRect(x: 0, y: 0, width: 800, height: 450)
                    let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable],
                                          backing: .buffered, defer: false)
                    window.isReleasedWhenClosed = false
                    let canvas = RemoteCanvasView(frame: frame, device: device)
                    canvas.controller = controller
                    canvas.setupMetal()
                    canvas.setSmokePixelHandler { pixel, _ in colors.insert(pixel & 0x00ffffff) }
                    window.contentView = canvas
                    resizeWindow = window
                    resizeCanvas = canvas
                    window.makeKeyAndOrderFront(nil)
                }
                controller.open(profile)
                let deadline = ContinuousClock.now + .seconds(15)
                var matchedAt: ContinuousClock.Instant?
                var matched = false
                var requested = false
                var unapplied = false
                let originalFrame = RemoteFrame(width: 640, height: 480)
                let targetFrame = RemoteFrame(width: 1024, height: 768)
                var resized = false
                while ContinuousClock.now < deadline {
                    resizeCanvas?.attachRendererIfNeeded()
                    resizeCanvas?.updateViewport()
                    if case .failed = controller.state { throw SessionError.network }
                    if controller.state == .disconnected { throw SessionError.disconnected }
                    if controller.state == .connected {
                        let caps = controller.agent
                        if caps.isConnected && caps.supportsMonitorsConfig == full &&
                            caps.supportsClipboard == full {
                            if let since = matchedAt {
                                if !matched && since.duration(to: ContinuousClock.now) >= .milliseconds(500) {
                                    matched = true
                                    print("MRV_AGENT_CAPS_OK monitors=\(full ? 1 : 0) clipboard=\(full ? 1 : 0)")
                                }
                            } else {
                                matchedAt = ContinuousClock.now
                            }
                        } else {
                            matchedAt = nil
                        }
                        let initialPixelsReady = !resize || (colors.contains(0xff0000) && colors.contains(0x00ff00) &&
                            resizeCanvas?.smokeMappingMatches(originalFrame) == true && controller.hasRenderedFrame)
                        if monitor && matched && caps.isConnected && controller.displaySize == originalFrame && !requested && initialPixelsReady {
                            // Exercise the production viewport policy/adapter.
                            // The fixture intentionally never changes its display.
                            if resize {
                                print("MRV_AGENT_RESIZE_INITIAL_OK 640x480")
                                colors.removeAll()
                                // Preset avoids a window-size callback overriding the target.
                                controller.applyResolutionPreference(.preset(targetFrame))
                            } else {
                                controller.updateViewportSize(CGSize(width: 1024, height: 768))
                            }
                            requested = true
                            print("MRV_AGENT_MONITOR_TARGET 1024x768")
                        }
                        if resize && requested && !resized && controller.displaySize == targetFrame &&
                            colors.contains(0x00ffff) && colors.contains(0xff00ff) &&
                            resizeCanvas?.smokeMappingMatches(targetFrame) == true && controller.hasRenderedFrame &&
                            !controller.guestDidNotApplyResolution {
                            resized = true
                            print("MRV_AGENT_RESIZE_APPLIED_OK 1024x768 pixels=cyan,magenta mapping=ok")
                        }
                        if monitor && requested && controller.guestDidNotApplyResolution && !unapplied {
                            guard !resize, full, controller.displaySize == originalFrame else { throw SessionError.cancelled }
                            unapplied = true
                            print("MRV_AGENT_MONITOR_UNAPPLIED_OK")
                        }
                        if matched && !caps.isConnected {
                            if monitor {
                                guard requested, unapplied == (full && !resize),
                                      controller.displaySize == (resize ? targetFrame : originalFrame),
                                      (!resize || resized),
                                      !controller.guestDidNotApplyResolution else { throw SessionError.cancelled }
                                print("MRV_AGENT_MONITOR_OFFLINE_OK")
                            }
                            guard !caps.supportsMonitorsConfig, !caps.supportsClipboard,
                                  model.sessions.isEmpty else { throw SessionError.cancelled }
                            print("MRV_AGENT_REMOVED_OK main=connected")
                            controller.cancel()
                            guard controller.state == .disconnected, !controller.agent.isConnected,
                                  !controller.agent.supportsMonitorsConfig,
                                  !controller.agent.supportsClipboard else { throw SessionError.cancelled }
                            resizeCanvas?.setSmokePixelHandler(nil)
                            resizeCanvas?.prepareForRemoval()
                            resizeWindow?.orderOut(nil)
                            print("MRV_SPICE_AGENT_OK")
                            fflush(nil)
                            Darwin.exit(0)
                        }
                    }
                    try await Task.sleep(for: .milliseconds(25))
                }
                print("MRV_AGENT_TIMEOUT connected=\(controller.agent.isConnected) monitors=\(controller.agent.supportsMonitorsConfig) clipboard=\(controller.agent.supportsClipboard)")
                throw SessionError.network
            } catch {
                controller.cancel()
                resizeCanvas?.setSmokePixelHandler(nil)
                resizeCanvas?.prepareForRemoval()
                resizeWindow?.orderOut(nil)
                print("MRV_SPICE_AGENT_FAILED")
                fflush(nil)
                Darwin.exit(1)
            }
        }
    }

    private func runLoopbackSpiceAuthProbe(file: URL) {
        Task { @MainActor in
            let engine = SpiceEngineAdapter()
            let controller = SessionController(engine: engine,
                connectionTimeout: .seconds(8), displayTimeout: .seconds(10))
            do {
                let (data, _) = try FoundationFileAccessor().readIdentified(from: file)
                let profile = try VVParser().parse(data: data)
                guard profile.host == "127.0.0.1", profile.proxyURL == nil,
                      profile.ticket.value == "mrv-ci-synthetic-ticket", !profile.deleteSourceFile else {
                    throw SessionError.cancelled
                }
                // Exercise real native proxy storage without connecting to any
                // proxy. Only synthetic values are used, and never printed.
                try engine.startWorker()
                let offline = CSConnection(host: "127.0.0.1", port: String(profile.tlsPort))
                try offline.pve_applyHost(
                    "pvespiceproxy:synthetic-disposable-destination",
                    tlsPort: String(profile.tlsPort),
                    proxy: "http://synthetic-user:synthetic-password@127.0.0.1:3128",
                    ca: profile.caPEM, certSubject: profile.hostSubject,
                    password: profile.ticket.value)
                guard offline.hasPVEProxyCredentials(),
                      offline.disconnectPVEAndClearCredentials(),
                      !offline.hasPVEProxyCredentials(),
                      offline.disconnectPVEAndClearCredentials() else {
                    throw SessionError.engineUnavailable
                }
                print("MRV_NATIVE_PROXY_CLEANUP_OK")
                controller.setClipboardSharingEnabled(false)
                for round in 0..<3 {
                    controller.open(profile)
                    let deadline = ContinuousClock.now + .seconds(10)
                    while controller.state == .connecting && ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    if case .failed(.authenticationRejected) = controller.state, round == 0 {
                        controller.cancel()
                        guard engine.lastNativeCredentialCleanupSucceeded == true else {
                            throw SessionError.engineUnavailable
                        }
                        print("MRV_NATIVE_AUTH_CLEANUP_OK")
                        print("MRV_SPICE_AUTH_REJECTED")
                        fflush(nil)
                        Darwin.exit(0)
                    }
                    guard controller.state == .connected else { throw SessionError.network }
                    // Allow initial main-channel messages to run before cancelling.
                    try await Task.sleep(for: .milliseconds(150))
                    guard controller.state == .connected else { throw SessionError.network }
                    controller.cancel()
                    guard controller.state == .disconnected else { throw SessionError.cancelled }
                    guard engine.lastNativeCredentialCleanupSucceeded == true else {
                        throw SessionError.engineUnavailable
                    }
                    print("MRV_NATIVE_AUTH_CLEANUP_OK")
                    // Drain callbacks from the old connection before opening again.
                    try await Task.sleep(for: .milliseconds(150))
                    guard controller.state == .disconnected else { throw SessionError.cancelled }
                    print("MRV_SPICE_AUTH_ROUND_OK \(round + 1)")
                }
                print("MRV_SPICE_AUTH_OK")
                fflush(nil)
                Darwin.exit(0)
            } catch {
                controller.cancel()
                print("MRV_SPICE_AUTH_FAILED")
                fflush(nil)
                Darwin.exit(1)
            }
        }
    }

    /// Integration-only probe. Restrict both destination and optional HTTP
    /// CONNECT proxy to synthetic IPv4 loopback; never use real PVE credentials.
    private func runLoopbackTLSProbe(file: URL) {
        Task { @MainActor in
            let engine = SpiceEngineAdapter()
            let controller = SessionController(engine: engine, connectionTimeout: .seconds(12))
            do {
                let (data, _) = try FoundationFileAccessor().readIdentified(from: file)
                let profile = try VVParser().parse(data: data)
                guard profile.host == "127.0.0.1",
                      profile.ticket.value == "mrv-ci-synthetic-ticket", !profile.deleteSourceFile else {
                    throw SessionError.cancelled
                }
                if let proxy = profile.proxyURL {
                    guard proxy.scheme == "http", proxy.host == "127.0.0.1",
                          proxy.port != nil, proxy.user == nil, proxy.password == nil else {
                        throw SessionError.cancelled
                    }
                }
                controller.setClipboardSharingEnabled(false)
                controller.open(profile)
                let deadline = ContinuousClock.now + .seconds(15)
                while ContinuousClock.now < deadline {
                    switch controller.state {
                    case .failed(let error):
                        // Do not expose certificate contents, credentials or raw library messages.
                        print(error == .tls ? "MRV_TLS_PROBE_REJECTED_TLS" : "MRV_TLS_PROBE_TERMINAL")
                        controller.cancel()
                        fflush(nil)
                        Darwin.exit(0)
                    case .disconnected:
                        controller.cancel()
                        print("MRV_TLS_PROBE_TERMINAL")
                        fflush(nil)
                        Darwin.exit(0)
                    case .connected:
                        // The fixture implements TLS and observes the link header only.
                        throw SessionError.unknown(code: "unexpected-connected")
                    default:
                        try await Task.sleep(for: .milliseconds(50))
                    }
                }
                throw SessionError.network
            } catch {
                controller.cancel()
                print("MRV_TLS_PROBE_FAILED")
                fflush(nil)
                Darwin.exit(1)
            }
        }
    }

    /// Explicit test mode only. No .vv, credentials, network connection or guest input.
    private func runStartupSmokeTest() {
        Task { @MainActor in
            do {
                guard let device = MTLCreateSystemDefaultDevice(),
                      device.makeCommandQueue() != nil else {
                    throw SessionError.engineUnavailable
                }
                let engine = SpiceEngineAdapter()
                try engine.startWorker()
                // Let SwiftUI create and present its main scene before reporting success.
                let deadline = ContinuousClock.now + .seconds(10)
                while !NSApp.windows.contains(where: { $0.canBecomeMain && $0.isVisible }) {
                    guard ContinuousClock.now < deadline else {
                        throw SessionError.engineUnavailable
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                // Join the worker so gst_init and the actual registry inspection
                // finish before this short-lived probe reports success.
                CSMain.shared.spiceStop()
                if let directory = portableRegistryDirectory {
                    let registry = directory.appendingPathComponent("registry.bin")
                    let attributes = try FileManager.default.attributesOfItem(atPath: registry.path)
                    guard let mode = attributes[.posixPermissions] as? NSNumber,
                          mode.intValue & 0o077 == 0 else {
                        throw SessionError.engineUnavailable
                    }
                    removePortableRegistry()
                }
                // A distinct, machine-readable sentinel, emitted only after all checks.
                print("MRV_STARTUP_SMOKE_OK")
                fflush(nil)
                Darwin.exit(0)
            } catch {
                CSMain.shared.spiceStop()
                removePortableRegistry()
                print("MRV_STARTUP_SMOKE_FAILED")
                fflush(nil)
                Darwin.exit(1)
            }
        }
    }

    private func removePortableRegistry() {
        if let directory = portableRegistryDirectory {
            try? FileManager.default.removeItem(at: directory)
            portableRegistryDirectory = nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        removePortableRegistry()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        guard probeLaunch == .normal else { return false }
        presentMainWindowWhenReady()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Probe completion must be explicit; a last-window event must never
        // convert an unfinished integration test into a zero exit status.
        !isIntegrationProbe
    }

    /// 開檔回呼可能早於 SwiftUI 建立視窗；沒有可顯示視窗時下一輪再試。
    /// `application(_:open:)` 與 `didFinishLaunching` 會連續觸發，合併成一次 retry。
    private func presentMainWindowWhenReady() {
        let first = presentAndRememberMainWindow()
        guard WindowPresentationPolicy.shouldRetryAfterSceneReady(first) else { return }
        guard !isWaitingToPresentMainWindow else { return }
        isWaitingToPresentMainWindow = true
        DispatchQueue.main.async { [self] in
            isWaitingToPresentMainWindow = false
            _ = presentAndRememberMainWindow()
        }
    }

    /// `Window(id:)` 仍可能在開檔回呼之後才插入多餘主窗；延後一到兩輪再關。
    private func closeExtraMainWindowsAfterSceneUpdate() {
        DispatchQueue.main.async { [self] in
            logWindowOutcome(
                AppWindowPresenter.closeExtraMainWindows(
                    application: NSApp,
                    keeping: keptMainWindow
                )
            )
            DispatchQueue.main.async { [self] in
                logWindowOutcome(
                    AppWindowPresenter.closeExtraMainWindows(
                        application: NSApp,
                        keeping: keptMainWindow
                    )
                )
            }
        }
    }

    @discardableResult
    private func presentAndRememberMainWindow() -> WindowPresentationAction {
        let outcome = AppWindowPresenter.present(application: NSApp, keeping: keptMainWindow)
        keptMainWindow = outcome.keptWindow
        logWindowOutcome(outcome)
        return outcome.action
    }

    private func logWindowOutcome(_ outcome: WindowPresentationOutcome) {
        guard outcome.windowCount > 1 || outcome.extraClosedCount > 0 else { return }
        model.settings.fileLog.write(
            level: "INFO",
            message: "window-present count=\(outcome.windowCount) extras-closed=\(outcome.extraClosedCount) remembered=\(outcome.keptWindow != nil)",
            sessionID: "window"
        )
    }
}

/// 前景決策後要記住哪扇主窗，以及關掉了幾扇多餘窗。
struct WindowPresentationOutcome {
    let action: WindowPresentationAction
    let keptWindow: NSWindow?
    let windowCount: Int
    let extraClosedCount: Int
}

/// 把主視窗叫到前景。雙擊 `.vv` 時 Finder 仍可能保持 active。
@MainActor
enum AppWindowPresenter {
    @discardableResult
    static func present(
        application: NSApplication,
        keeping keptWindow: NSWindow?
    ) -> WindowPresentationOutcome {
        let windows = application.windows
        let candidates = windows.map(candidate(from:))
        let action = WindowPresentationPolicy.action(for: candidates)
        activate(application)
        switch action {
        case .none:
            break
        case .orderFront(let index):
            windows[index].makeKeyAndOrderFront(nil)
        case .deminiaturizeAndOrderFront(let index):
            windows[index].deminiaturize(nil)
            windows[index].makeKeyAndOrderFront(nil)
        }
        return closeExtraMainWindows(
            windows: windows,
            candidates: candidates,
            action: action,
            keeping: keptWindow
        )
    }

    static func closeExtraMainWindows(
        application: NSApplication,
        keeping keptWindow: NSWindow?
    ) -> WindowPresentationOutcome {
        let windows = application.windows
        let candidates = windows.map(candidate(from:))
        return closeExtraMainWindows(
            windows: windows,
            candidates: candidates,
            action: WindowPresentationPolicy.action(for: candidates),
            keeping: keptWindow
        )
    }

    private static func closeExtraMainWindows(
        windows: [NSWindow],
        candidates: [WindowPresentationCandidate],
        action: WindowPresentationAction,
        keeping keptWindow: NSWindow?
    ) -> WindowPresentationOutcome {
        let rememberedIndex = keptWindow.flatMap { kept in
            windows.firstIndex(where: { $0 === kept })
        }
        let keptIndex = WindowPresentationPolicy.keptIndexForClosingExtras(
            rememberedIndex: rememberedIndex,
            action: action
        )
        var extraClosedCount = 0
        if let keptIndex {
            for index in WindowPresentationPolicy.extraMainWindowIndices(in: candidates, keptIndex: keptIndex) {
                windows[index].close()
                extraClosedCount += 1
            }
        }
        let nextKept: NSWindow?
        if let keptIndex {
            nextKept = windows[keptIndex]
        } else {
            nextKept = keptWindow
        }
        return WindowPresentationOutcome(
            action: action,
            keptWindow: nextKept,
            windowCount: windows.count,
            extraClosedCount: extraClosedCount
        )
    }

    private static func candidate(from window: NSWindow) -> WindowPresentationCandidate {
        WindowPresentationCandidate(
            canBecomeMain: window.canBecomeMain,
            isVisible: window.isVisible,
            isMiniaturized: window.isMiniaturized,
            isPanel: window is NSPanel
                || window.styleMask.contains(.utilityWindow)
                || window.styleMask.contains(.nonactivatingPanel)
        )
    }

    private static func activate(_ application: NSApplication) {
        application.unhide(nil)
        // Finder 用文件啟動時，無參數的 `activate()` 不會搶前景。
        application.activate(ignoringOtherApps: true)
    }
}

/// Configure GStreamer before the worker calls gst_init(NULL, NULL).
/// Bundled applications must not inherit host plugin paths or registry caches.
/// A local Xcode build retains the existing Homebrew development behavior.
private func preparePortableRuntime(verifyRegistry: Bool, integrationProbe: Bool) throws -> URL? {
    // Do not inherit native diagnostic verbosity or fatal warning policy.
    // GLib may already have initialized before the delegate, so this is not
    // a guarantee about pre-main diagnostics or crash dumps.
    for key in ["SPICE_DEBUG", "G_MESSAGES_DEBUG", "G_DEBUG"] {
        guard unsetenv(key) == 0 else { throw SessionError.engineUnavailable }
    }
    if !integrationProbe {
        guard unsetenv("MRV_GLIB_TRACE") == 0 else { throw SessionError.engineUnavailable }
    }
    // Only the explicitly opted-in startup probe may emit the fixed canary.
    if !verifyRegistry {
        guard unsetenv("MRV_NATIVE_LOG_CANARY") == 0 else { throw SessionError.engineUnavailable }
    }
    let contents = Bundle.main.bundleURL.appendingPathComponent("Contents", isDirectory: true)
    let fileManager = FileManager.default
    let gstPlugins = contents.appendingPathComponent("Resources/gstreamer-1.0", isDirectory: true)
    let scanner = contents.appendingPathComponent("MacOS/gst-plugin-scanner")
    let opensslModules = contents.appendingPathComponent("Resources/ossl-modules", isDirectory: true)
    let opensslConfig = contents.appendingPathComponent("Resources/mrv-openssl.cnf")

    // spice_session_new() and setting proxy=NULL both consult SPICE_PROXY.
    // Apply this for development and packaged launches before the worker starts.
    // Explicit, validated .vv proxy settings are the sole SPICE proxy authority.
    for key in ["SPICE_PROXY", "spice_proxy"] {
        guard unsetenv(key) == 0 else { throw SessionError.engineUnavailable }
    }
    // Only the packaged runtime may enable the registry inspection.
    guard unsetenv("MRV_VERIFY_PACKAGED_GST") == 0 else { throw SessionError.engineUnavailable }
    let bundled = fileManager.fileExists(atPath: gstPlugins.path) ||
                  fileManager.fileExists(atPath: scanner.path) ||
                  fileManager.fileExists(atPath: opensslConfig.path)
    if bundled {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: gstPlugins.path, isDirectory: &isDirectory),
              isDirectory.boolValue, !gstPlugins.path.contains(":"),
              fileManager.isExecutableFile(atPath: scanner.path) else {
            throw SessionError.engineUnavailable
        }
        // mkdtemp creates a new 0700 directory atomically, with no preexisting cache.
        var template = Array(fileManager.temporaryDirectory
            .appendingPathComponent("mrv-gst-XXXXXX").path.utf8CString)
        let created = template.withUnsafeMutableBufferPointer { buffer -> String? in
            guard let base = buffer.baseAddress, let path = mkdtemp(base) else { return nil }
            return String(cString: path)
        }
        guard let created else { throw SessionError.engineUnavailable }
        let directory = URL(fileURLWithPath: created, isDirectory: true)
        let registry = directory.appendingPathComponent("registry.bin").path
        do {
            for key in ["GST_REGISTRY_FORK", "GST_REGISTRY_UPDATE",
                        "GST_REGISTRY_REUSE_PLUGIN_SCANNER", "GST_PLUGIN_LOADING_WHITELIST",
                        "GST_DEBUG_FILE", "GST_DEBUG_DUMP_DOT_DIR", "GST_TRACERS", "GST_DEBUG"] {
                guard unsetenv(key) == 0 else { throw SessionError.engineUnavailable }
            }
            let settings = [
                "GST_PLUGIN_PATH": "", "GST_PLUGIN_PATH_1_0": "",
                "GST_PLUGIN_SYSTEM_PATH": gstPlugins.path,
                "GST_PLUGIN_SYSTEM_PATH_1_0": gstPlugins.path,
                "GST_PLUGIN_SCANNER": scanner.path, "GST_PLUGIN_SCANNER_1_0": scanner.path,
                "GST_REGISTRY": registry, "GST_REGISTRY_1_0": registry,
                "GST_REGISTRY_MODE": "0600",
            ]
            for (key, value) in settings {
                guard setenv(key, value, 1) == 0 else { throw SessionError.engineUnavailable }
            }
            if verifyRegistry {
                guard setenv("MRV_VERIFY_PACKAGED_GST", "1", 1) == 0 else {
                    throw SessionError.engineUnavailable
                }
            }
            // PVE trust is supplied explicitly by the validated .vv CA.
            // Do not inherit host OpenSSL configuration, providers, engines,
            // key logging, or ambient default trust paths in the packaged app.
            // This must run before the SPICE worker and gst_init.
            var modulesIsDirectory: ObjCBool = false
            let configValues = try opensslConfig.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard configValues.isRegularFile == true, configValues.isSymbolicLink != true,
                  fileManager.fileExists(atPath: opensslModules.path, isDirectory: &modulesIsDirectory),
                  modulesIsDirectory.boolValue else {
                throw SessionError.engineUnavailable
            }
            for key in ["SSLKEYLOGFILE", "OPENSSL_TRACE", "OPENSSL_FORCE_FIPS_MODE",
                        "OPENSSL_CONF_INCLUDE", "OPENSSL_ENGINES", "SSL_CERT_FILE",
                        "SSL_CERT_DIR", "RANDFILE", "CTLOG_FILE"] {
                guard unsetenv(key) == 0 else { throw SessionError.engineUnavailable }
            }
            let opensslSettings = [
                "OPENSSL_CONF": opensslConfig.path,
                "OPENSSL_MODULES": opensslModules.path,
                "OPENSSL_CONF_INCLUDE": directory.path,
                "OPENSSL_ENGINES": directory.path,
                "SSL_CERT_FILE": "/dev/null",
                "SSL_CERT_DIR": directory.path,
            ]
            for (key, value) in opensslSettings {
                guard setenv(key, value, 1) == 0 else { throw SessionError.engineUnavailable }
            }
            return directory
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
    }

    if getenv("GST_PLUGIN_PATH") == nil {
        let homebrewPlugins = [
            "/opt/homebrew/lib/gstreamer-1.0",
            "/usr/local/lib/gstreamer-1.0",
        ]
        for path in homebrewPlugins where fileManager.fileExists(atPath: path) {
            setenv("GST_PLUGIN_PATH", path, 0)
            setenv("GST_PLUGIN_SYSTEM_PATH", path, 0)
            break
        }
    }
    if fileManager.fileExists(atPath: opensslModules.path) {
        setenv("OPENSSL_MODULES", opensslModules.path, 1)
    }
    return nil
}
