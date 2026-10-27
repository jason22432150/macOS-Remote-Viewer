import Foundation

/// 本次工作階段的不可變連線設定。禁止寫入日誌或 description 的機密欄位。
public struct ConnectionProfile: Sendable, Equatable {
    public let sessionID: String
    public let title: String
    public let host: String
    public let tlsPort: UInt16
    public let proxyURL: URL?
    public let caPEM: Data
    public let hostSubject: String
    public let ticket: Ticket
    public let deleteSourceFile: Bool
    public let toggleFullscreen: HotKeyChord
    public let releaseCursor: HotKeyChord
    public let secureAttention: HotKeyChord
    public let unknownFieldNames: [String]
    public let sourceIdentity: SourceFileIdentity?

    public init(
        sessionID: String = UUID().uuidString,
        title: String,
        host: String,
        tlsPort: UInt16,
        proxyURL: URL?,
        caPEM: Data,
        hostSubject: String,
        ticket: Ticket,
        deleteSourceFile: Bool,
        toggleFullscreen: HotKeyChord,
        releaseCursor: HotKeyChord,
        secureAttention: HotKeyChord,
        unknownFieldNames: [String],
        sourceIdentity: SourceFileIdentity?
    ) {
        self.sessionID = sessionID
        self.title = title
        self.host = host
        self.tlsPort = tlsPort
        self.proxyURL = proxyURL
        self.caPEM = caPEM
        self.hostSubject = hostSubject
        self.ticket = ticket
        self.deleteSourceFile = deleteSourceFile
        self.toggleFullscreen = toggleFullscreen
        self.releaseCursor = releaseCursor
        self.secureAttention = secureAttention
        self.unknownFieldNames = unknownFieldNames
        self.sourceIdentity = sourceIdentity
    }

    /// 僅供 SPICE session 使用的票證；不進日誌、不進最近連線。
    public struct Ticket: Sendable, Equatable, CustomStringConvertible {
        public let value: String

        public init(_ value: String) {
            self.value = value
        }

        public var description: String { "<redacted>" }
    }
}

extension ConnectionProfile: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "ConnectionProfile(sessionID: \(sessionID), title: \(redactedTitle), tlsPort: \(tlsPort))"
    }

    public var debugDescription: String { description }

    private var redactedTitle: String {
        title.isEmpty ? "(empty)" : "<title>"
    }
}

/// 匯入當下的來源檔識別，刪除前用來避免誤刪被替換的檔案。
public struct SourceFileIdentity: Sendable, Equatable {
    public let path: String
    public let fileNumber: UInt64
    public let volumeIdentifier: UInt64
    public let size: UInt64
    public let modificationTime: TimeInterval

    public init(
        path: String,
        fileNumber: UInt64,
        volumeIdentifier: UInt64,
        size: UInt64,
        modificationTime: TimeInterval
    ) {
        self.path = path
        self.fileNumber = fileNumber
        self.volumeIdentifier = volumeIdentifier
        self.size = size
        self.modificationTime = modificationTime
    }
}
