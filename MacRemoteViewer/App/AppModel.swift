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
    @ObservationIgnored private var importTask: Task<Void, Never>?

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
        settings.fileLog.write(
            level: "INFO",
            message: "open-urls count=\(urls.count) existing-sessions=\(workspace.sessions.count)",
            sessionID: "app"
        )
        // Preserve open order without blocking AppKit on file I/O.
        let previous = importTask
        let importer = self.importer
        importTask = Task { @MainActor [weak self] in
            await previous?.value
            let result = await Task.detached(priority: .userInitiated) {
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
                return (profiles, lastError)
            }.value
            guard let self else { return }
            self.workspace.open(result.0)
            self.welcomeError = result.1
        }
    }

    func chooseFile() {
        chooseFile(recovery: false)
    }

    /// Recovery always imports an explicitly selected file into a new tab.
    /// Never resurrect a terminal controller or reuse its prior ticket.
    func chooseRecoveryFile() {
        chooseFile(recovery: true)
    }

    private func chooseFile(recovery: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.virtViewer, .data]
        panel.allowsMultipleSelection = !recovery
        panel.canChooseDirectories = false
        panel.message = L10n.string(recovery ? .chooseRecoveryVVMessage : .chooseVVMessage,
                                    language: settings.language)
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
