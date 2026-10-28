import AppKit
import Observation
import UniformTypeIdentifiers

extension UTType {
    static let virtViewer = UTType(exportedAs: "com.macremoteviewer.virt-viewer")
}

@MainActor
@Observable
final class AppModel {
    var welcomeError: SessionError?
    let settings: AppSettings
    let workspace: SessionWorkspace

    let importer = VVFileImporter()

    var session: SessionController? { workspace.selectedSession }
    var sessions: [SessionController] { workspace.sessions }
    var selectedSessionID: String? { workspace.selectedSessionID }
    var showsTabBar: Bool { workspace.showsTabBar }

    init(
        settings: AppSettings = AppSettings(),
        makeEngine: @escaping () -> SpiceEngineing = { SpiceEngineAdapter() }
    ) {
        self.settings = settings
        self.workspace = SessionWorkspace { [settings, makeEngine] profile in
            SessionController(
                engine: makeEngine(),
                cleanup: SourceFileCleanup(
                    deleteAfterSuccessfulConnect: settings.preferences.deleteVVFileAfterConnect
                ),
                diagnostics: DiagnosticsLog(
                    sessionID: profile.sessionID,
                    fileLog: settings.fileLog
                ),
                resolutionPreference: settings.preferences.resolutionPreference,
                sessionID: profile.sessionID
            )
        }
        settings.onChange = { [weak self] in
            self?.applySettingsToActiveSession()
        }
    }

    func open(urls: [URL]) {
        guard !urls.isEmpty else { return }
        var profiles: [ConnectionProfile] = []
        var lastError: SessionError?
        for url in urls {
            do {
                profiles.append(try importer.importFile(at: url))
            } catch let error as SessionError {
                lastError = error
            } catch {
                lastError = .sourceFileUnavailable
            }
        }
        workspace.open(profiles)
        welcomeError = lastError
    }

    func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.virtViewer, .data]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.message = L10n.string(.chooseVVMessage, language: settings.language)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        open(urls: panel.urls)
    }

    func selectSession(_ sessionID: String) {
        workspace.select(sessionID)
    }

    func closeSession() {
        workspace.closeSelected()
    }

    func closeSession(_ sessionID: String) {
        workspace.close(sessionID)
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
        workspace.applyResolutionPreference(settings.preferences.resolutionPreference)
    }

    func releaseKeysOnAll() {
        workspace.releaseKeysOnAll()
    }
}
