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
        guard url.isFileURL else { throw SessionError.sourceFileUnavailable }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SessionError.sourceFileUnavailable
        }
        guard (values.fileSize ?? 0) <= VVParser.maxFileBytes else {
            throw SessionError.fileTooLarge(maxBytes: VVParser.maxFileBytes)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        while data.count <= VVParser.maxFileBytes {
            let remaining = VVParser.maxFileBytes + 1 - data.count
            guard let chunk = try handle.read(upToCount: min(remaining, 64 * 1024)), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= VVParser.maxFileBytes else {
            throw SessionError.fileTooLarge(maxBytes: VVParser.maxFileBytes)
        }
        return data
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
/// 只有使用者允許且連線檔明確要求刪除時才清理。
public struct SourceFileCleanup: Sendable {
    public var deleteAfterSuccessfulConnect: Bool

    public init(deleteAfterSuccessfulConnect: Bool = true) {
        self.deleteAfterSuccessfulConnect = deleteAfterSuccessfulConnect
    }

    public func deleteIfNeeded(
        profile: ConnectionProfile,
        files: FileAccessing
    ) -> SourceCleanupResult {
        guard deleteAfterSuccessfulConnect, profile.deleteSourceFile else {
            return .skipped
        }
        guard let identity = profile.sourceIdentity, identity.fileNumber != 0,
              identity.volumeIdentifier != 0 else {
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
                  current.modificationTime == identity.modificationTime
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
