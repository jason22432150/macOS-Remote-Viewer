import AppKit
import SwiftUI
import MetalKit
import Darwin

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
    private let isIntegrationProbe = ProcessInfo.processInfo.arguments.contains {
        ["--startup-smoke-test", "--loopback-tls-probe",
         "--loopback-spice-auth-probe", "--loopback-spice-display-probe",
         "--loopback-spice-wrapper-probe", "--loopback-spice-multi-probe",
         "--loopback-spice-partial-probe", "--loopback-spice-workspace-probe",
         "--loopback-spice-agent-probe"].contains($0)
    }
    private var isWaitingToPresentMainWindow = false
    /// 已在畫面上、帶 Metal 的那扇主窗。關多餘窗時必須對這個物件，不可改選最前面那扇。
    private weak var keptMainWindow: NSWindow?

    func applicationWillFinishLaunching(_ notification: Notification) {
        preparePortableRuntime()
        NSWindow.allowsAutomaticWindowTabbing = false
        if !isIntegrationProbe {
            incomingFiles.setHandler { [model] urls in
                model.open(urls: urls)
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard !isIntegrationProbe else {
            print("MRV_PROBE_IGNORED_OPEN_URLS count=\(urls.count)")
            return
        }
        incomingFiles.handle(urls)
        presentMainWindowWhenReady()
        closeExtraMainWindowsAfterSceneUpdate()
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        guard !isIntegrationProbe else {
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
        } else if arguments.contains("--startup-smoke-test") {
            // Startup smoke still requires the actual main window.
            presentMainWindowWhenReady()
        }
        if arguments.contains("--startup-smoke-test") {
            runStartupSmokeTest()
        } else if let index = arguments.firstIndex(of: "--loopback-tls-probe") {
            guard index + 1 < arguments.count else { Darwin.exit(2) }
            runLoopbackTLSProbe(file: URL(fileURLWithPath: arguments[index + 1]))
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
                controller.setClipboardSharingEnabled(false)
                for round in 0..<3 {
                    controller.open(profile)
                    let deadline = ContinuousClock.now + .seconds(10)
                    while controller.state == .connecting && ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    if case .failed(.authenticationRejected) = controller.state, round == 0 {
                        controller.cancel()
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

    /// Integration-only probe. Restrict it to a synthetic loopback profile; never
    /// send a real PVE ticket or enable clipboard, source deletion or a proxy.
    private func runLoopbackTLSProbe(file: URL) {
        Task { @MainActor in
            let engine = SpiceEngineAdapter()
            let controller = SessionController(engine: engine, connectionTimeout: .seconds(12))
            do {
                let (data, _) = try FoundationFileAccessor().readIdentified(from: file)
                let profile = try VVParser().parse(data: data)
                guard profile.host == "127.0.0.1", profile.proxyURL == nil,
                      profile.ticket.value == "mrv-ci-synthetic-ticket", !profile.deleteSourceFile else {
                    throw SessionError.cancelled
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
                // A distinct, machine-readable sentinel, emitted only after all checks.
                print("MRV_STARTUP_SMOKE_OK")
                fflush(nil)
                Darwin.exit(0)
            } catch {
                print("MRV_STARTUP_SMOKE_FAILED")
                fflush(nil)
                Darwin.exit(1)
            }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows _: Bool) -> Bool {
        guard !isIntegrationProbe else { return false }
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

/// 在 `gst_init` 之前設定可攜 runtime 路徑。
/// 打包後的 App 使用 bundle 內 plugin／OpenSSL modules；本機 Xcode 執行才退回 Homebrew。
private func preparePortableRuntime() {
    let contents = Bundle.main.bundleURL.appendingPathComponent("Contents", isDirectory: true)
    let fileManager = FileManager.default
    let gstPlugins = contents.appendingPathComponent("Resources/gstreamer-1.0", isDirectory: true)
    let scanner = contents.appendingPathComponent("MacOS/gst-plugin-scanner")
    let opensslModules = contents.appendingPathComponent("Resources/ossl-modules", isDirectory: true)

    if fileManager.fileExists(atPath: gstPlugins.path) {
        setenv("GST_PLUGIN_SYSTEM_PATH", gstPlugins.path, 1)
        setenv("GST_PLUGIN_PATH", gstPlugins.path, 1)
    } else if getenv("GST_PLUGIN_PATH") == nil {
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

    if fileManager.fileExists(atPath: scanner.path) {
        setenv("GST_PLUGIN_SCANNER", scanner.path, 1)
    }

    if fileManager.fileExists(atPath: opensslModules.path) {
        setenv("OPENSSL_MODULES", opensslModules.path, 1)
    }
}
