import Foundation
import Darwin

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
    public struct Ticket: Sendable, Equatable, CustomStringConvertible,
                          CustomDebugStringConvertible, CustomReflectable {
        // The shared backing allocation is immutable until its last owner
        // releases it. Copying a Ticket does not duplicate its secret bytes.
        let storage: Storage

        public init(_ value: String) {
            storage = Storage(value)
        }

        /// Compatibility boundary. A materialized String is a separate
        /// temporary copy; Swift/NSString storage cannot be reliably erased.
        public var value: String { storage.stringValue() }

        public var description: String { "<redacted>" }
        public var debugDescription: String { description }
        public var customMirror: Mirror {
            Mirror(self, children: ["value": "<redacted>"], displayStyle: .struct)
        }

        public static func == (lhs: Ticket, rhs: Ticket) -> Bool {
            // Preserve Swift String equality (including canonical Unicode
            // equivalence), but avoid materializing strings for equal bytes.
            lhs.storage === rhs.storage || lhs.storage.sameBytes(rhs.storage) ||
                lhs.value == rhs.value
        }

        /// C11 memset_s is not permitted to be optimized away as a dead store.
        /// The caller must own the entire supplied writable memory range.
        static func clearOwnedBytes(_ buffer: UnsafeMutableRawBufferPointer) {
            guard buffer.count > 0, let base = buffer.baseAddress else { return }
            let result = memset_s(base, buffer.count, 0, buffer.count)
            precondition(result == 0, "Ticket buffer zeroization failed")
        }

        // SAFETY: the pointer never escapes this class, all initialization
        // happens before publication, and no mutation occurs while any
        // reader owns a strong reference. Only deinit overwrites the bytes.
        final class Storage: @unchecked Sendable {
            private let bytes: UnsafeMutableRawPointer
            private let count: Int
            private let capacity: Int

            init(_ value: String) {
                let size = value.utf8.count
                count = size
                capacity = max(1, size)
                let allocation = UnsafeMutableRawPointer.allocate(byteCount: max(1, size), alignment: 1)
                bytes = allocation
                if size == 0 {
                    allocation.storeBytes(of: UInt8(0), as: UInt8.self)
                } else {
                    for (index, byte) in value.utf8.enumerated() {
                        allocation.storeBytes(of: byte, toByteOffset: index, as: UInt8.self)
                    }
                }
            }

            func stringValue() -> String {
                withExtendedLifetime(self) {
                    String(decoding: UnsafeRawBufferPointer(start: bytes, count: count), as: UTF8.self)
                }
            }

            func sameBytes(_ other: Storage) -> Bool {
                guard count == other.count else { return false }
                return withExtendedLifetime(self) {
                    withExtendedLifetime(other) {
                        memcmp(bytes, other.bytes, count) == 0
                    }
                }
            }

            deinit {
                Ticket.clearOwnedBytes(UnsafeMutableRawBufferPointer(start: bytes, count: capacity))
                bytes.deallocate()
            }
        }
    }
}

extension ConnectionProfile: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "ConnectionProfile(sessionID: \(DiagnosticLogPolicy.session(sessionID)), title: \(redactedTitle), tlsPort: \(tlsPort))"
    }

    public var debugDescription: String { description }

    private var redactedTitle: String {
        title.isEmpty ? "(empty)" : "<title>"
    }
}

/// UI-only projection. Do not store the transport profile in a controller:
/// PVE's destination token, proxy credentials, ticket and CA are not needed
/// to render a tab or dispatch a local shortcut.
public struct SessionPresentationProfile: Sendable, Equatable {
    public let title: String
    public let remoteAddress: String?
    public let toggleFullscreen: HotKeyChord
    public let releaseCursor: HotKeyChord
    public let secureAttention: HotKeyChord
    public let unknownFieldNames: [String]

    public init(_ profile: ConnectionProfile) {
        title = profile.title
        remoteAddress = SessionStatusText.displayAddress(from: profile)
        toggleFullscreen = profile.toggleFullscreen
        releaseCursor = profile.releaseCursor
        secureAttention = profile.secureAttention
        unknownFieldNames = profile.unknownFieldNames
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
