import AppKit
import Observation
import UniformTypeIdentifiers

extension UTType {
    static let virtViewer = UTType(exportedAs: "com.macremoteviewer.virt-viewer")
}

@MainActor
@Observable
final class AppModel {
    var session: SessionController?
    var welcomeError: SessionError?
    var clipboardMode: ClipboardMode = .manual
    var retainSourceFiles = false

    let importer = VVFileImporter()
    private let engine = StubSpiceEngine()
    private let pasteboard = PasteboardService()
    private let clipboardTransport = EngineClipboardTransport()

    func open(urls: [URL]) {
        guard let url = urls.first else { return }
        welcomeError = nil
        do {
            let profile = try importer.importFile(at: url)
            startSession(with: profile)
        } catch let error as SessionError {
            welcomeError = error
        } catch {
            welcomeError = .sourceFileUnavailable
        }
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.virtViewer, .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "選擇 PVE 下載的 .vv 連線檔"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(urls: [url])
    }

    func closeSession() {
        session?.cancel()
        session = nil
    }

    func applyClipboardMode(_ mode: ClipboardMode) {
        clipboardMode = mode
        session?.clipboard.setMode(mode)
        session?.clipboard.isWindowActive = true
    }

    private func startSession(with profile: ConnectionProfile) {
        session?.cancel()
        clipboardTransport.engine = engine
        let clipboard = ClipboardCoordinator(
            pasteboard: pasteboard,
            transport: clipboardTransport,
            mode: clipboardMode
        )
        let controller = SessionController(
            engine: engine,
            clipboard: clipboard,
            cleanup: SourceFileCleanup(retainEvenIfRequested: retainSourceFiles),
            diagnostics: DiagnosticsLog(sessionID: profile.sessionID)
        )
        session = controller
        controller.open(profile)
    }
}
