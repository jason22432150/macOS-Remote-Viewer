import Foundation
import Observation

/// 同時存在的遠端 session 集合。再開 `.vv` 時新增分頁，不取消既有連線。
@MainActor
@Observable
public final class SessionWorkspace {
    public private(set) var sessions: [SessionController] = []
    public private(set) var selectedSessionID: String?

    public var selectedSession: SessionController? {
        guard let selectedSessionID else { return sessions.last }
        return sessions.first { $0.sessionID == selectedSessionID } ?? sessions.last
    }

    public var showsTabBar: Bool {
        SessionTabPolicy.shouldShowTabBar(sessionCount: sessions.count)
    }

    private let makeSession: (ConnectionProfile) -> SessionController

    public init(makeSession: @escaping (ConnectionProfile) -> SessionController) {
        self.makeSession = makeSession
    }

    public func open(_ profile: ConnectionProfile) {
        open([profile])
    }

    public func open(_ profiles: [ConnectionProfile]) {
        guard !profiles.isEmpty else { return }
        let previous = selectedSession
        previous?.setClipboardSharingEnabled(false)
        for profile in profiles {
            let controller = makeSession(profile)
            controller.setClipboardSharingEnabled(false)
            controller.open(profile)
            sessions.append(controller)
        }
        if previous?.sessionID != sessions.last?.sessionID {
            previous?.releaseKeys()
        }
        selectedSessionID = sessions.last?.sessionID
        syncClipboardSharing()
    }

    public func select(_ sessionID: String) {
        guard sessions.contains(where: { $0.sessionID == sessionID }) else { return }
        guard selectedSessionID != sessionID else { return }
        selectedSession?.releaseKeys()
        selectedSessionID = sessionID
        syncClipboardSharing()
    }

    public func close(_ sessionID: String) {
        guard let index = sessions.firstIndex(where: { $0.sessionID == sessionID }) else { return }
        let closingSelected = selectedSessionID == sessionID
        sessions[index].cancel()
        sessions.remove(at: index)
        if sessions.isEmpty {
            selectedSessionID = nil
        } else if closingSelected {
            selectedSessionID = SessionTabPolicy.selectedIndexAfterClosing(
                closedIndex: index,
                remainingCount: sessions.count
            ).map { sessions[$0].sessionID }
        } else if let selectedSessionID,
                  sessions.contains(where: { $0.sessionID == selectedSessionID }) {
            // 關掉背景分頁時維持目前選取。
        } else {
            selectedSessionID = sessions.last?.sessionID
        }
        syncClipboardSharing()
    }

    public func closeSelected() {
        guard let selectedSessionID else { return }
        close(selectedSessionID)
    }

    public func applyResolutionPreference(_ preference: GuestResolutionPreference) {
        for session in sessions {
            session.applyResolutionPreference(preference)
        }
    }

    public func releaseKeysOnAll() {
        for session in sessions {
            session.releaseKeys()
        }
    }

    /// F14：只有作用中分頁同步剪貼簿，避免背景 VM 收到本機複製內容。
    private func syncClipboardSharing() {
        let selected = selectedSessionID
        for session in sessions where session.sessionID != selected {
            session.setClipboardSharingEnabled(false)
        }
        sessions.first { $0.sessionID == selected }?.setClipboardSharingEnabled(true)
    }
}
