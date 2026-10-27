import Foundation

public protocol FileAccessing: Sendable {
    func read(from url: URL) throws -> Data
    func identity(of url: URL) throws -> SourceFileIdentity
    func removeItem(at url: URL) throws
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

public struct FoundationFileAccessor: FileAccessing {
    public init() {}

    public func read(from url: URL) throws -> Data {
        try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    public func identity(of url: URL) throws -> SourceFileIdentity {
        let values = try url.resourceValues(forKeys: [
            .fileResourceIdentifierKey,
            .fileSizeKey,
            .contentModificationDateKey,
            .volumeIdentifierKey
        ])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let volume = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
        return SourceFileIdentity(
            path: url.path,
            fileNumber: fileNumber,
            volumeIdentifier: volume,
            size: UInt64(values.fileSize ?? 0),
            modificationTime: values.contentModificationDate?.timeIntervalSince1970 ?? 0
        )
    }

    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    public func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    public func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}

/// 成功建立工作階段後，依使用者偏好刪除匯入的 `.vv`。
/// `.vv` 的 `delete-this-file` 仍會解析保存，但刪除與否以 App 設定為準。
public struct SourceFileCleanup: Sendable {
    public var deleteAfterSuccessfulConnect: Bool

    public init(deleteAfterSuccessfulConnect: Bool = true) {
        self.deleteAfterSuccessfulConnect = deleteAfterSuccessfulConnect
    }

    public func deleteIfNeeded(
        profile: ConnectionProfile,
        files: FileAccessing
    ) -> SourceCleanupResult {
        guard deleteAfterSuccessfulConnect else {
            return .skipped
        }
        guard let identity = profile.sourceIdentity else {
            return .skipped
        }
        let url = URL(fileURLWithPath: identity.path)
        let accessed = files.startAccessing(url)
        defer {
            if accessed {
                files.stopAccessing(url)
            }
        }
        do {
            let current = try files.identity(of: url)
            guard current.fileNumber == identity.fileNumber,
                  current.volumeIdentifier == identity.volumeIdentifier,
                  current.size == identity.size,
                  abs(current.modificationTime - identity.modificationTime) < 1
            else {
                return .replacedFilePreserved
            }
            try files.removeItem(at: url)
            return .deleted
        } catch {
            return .permissionDenied
        }
    }
}

public enum SourceCleanupResult: Equatable, Sendable {
    case skipped
    case deleted
    case permissionDenied
    case replacedFilePreserved
}
