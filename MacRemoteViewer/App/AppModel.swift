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
    let settings: AppSettings

    let importer = VVFileImporter()
    private let engine = SpiceEngineAdapter()

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
        settings.onChange = { [weak self] in
            self?.applySettingsToActiveSession()
        }
    }

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
        panel.message = L10n.string(.chooseVVMessage, language: settings.language)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(urls: [url])
    }

    func closeSession() {
        session?.cancel()
        session = nil
    }

    /// 即使尚未寫入任何 log，也先建立資料夾再開啟 Finder。
    func revealLogFolder() {
        do {
            try settings.fileLog.ensureDirectoryExists()
        } catch {
            settings.fileLog.write(
                level: "ERROR",
                message: "log-directory-unavailable",
                sessionID: "settings"
            )
        }
        NSWorkspace.shared.open(settings.fileLog.directoryURL)
    }

    func applySettingsToActiveSession() {
        session?.applyResolutionPreference(settings.preferences.resolutionPreference)
    }

    private func startSession(with profile: ConnectionProfile) {
        session?.cancel()
        let controller = SessionController(
            engine: engine,
            cleanup: SourceFileCleanup(
                deleteAfterSuccessfulConnect: settings.preferences.deleteVVFileAfterConnect
            ),
            diagnostics: DiagnosticsLog(
                sessionID: profile.sessionID,
                fileLog: settings.fileLog
            ),
            resolutionPreference: settings.preferences.resolutionPreference
        )
        session = controller
        controller.open(profile)
    }
}
