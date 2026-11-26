import Foundation
import Darwin

public protocol FileAccessing: Sendable {
    func read(from url: URL) throws -> Data
    func identity(of url: URL) throws -> SourceFileIdentity
    func removeItem(at url: URL) throws
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
    func readIdentified(from url: URL) throws -> (Data, SourceFileIdentity?)
    func removeMatchingItem(at url: URL, identity: SourceFileIdentity) -> SourceCleanupResult
}

public extension FileAccessing {
    func readIdentified(from url: URL) throws -> (Data, SourceFileIdentity?) {
        let before = try? identity(of: url)
        let data = try read(from: url)
        let after = try? identity(of: url)
        let matching = before == after && after?.size == UInt64(data.count)
        return (data, matching ? after : nil)
    }

    func removeMatchingItem(at url: URL, identity expected: SourceFileIdentity) -> SourceCleanupResult {
        do {
            guard try identity(of: url) == expected else { return .replacedFilePreserved }
            try removeItem(at: url)
            return .deleted
        } catch { return .permissionDenied }
    }
}

public struct FoundationFileAccessor: FileAccessing {
    public init() {}

    public func read(from url: URL) throws -> Data {
        try readIdentified(from: url).0
    }

    public func readIdentified(from url: URL) throws -> (Data, SourceFileIdentity?) {
        guard url.isFileURL else { throw SessionError.sourceFileUnavailable }
        // No-follow + nonblocking prevents symlink substitution or blocking on a FIFO.
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw SessionError.sourceFileUnavailable }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, Self.isRegular(before), before.st_size >= 0 else {
            throw SessionError.sourceFileUnavailable
        }
        guard before.st_size <= VVParser.maxFileBytes else {
            throw SessionError.fileTooLarge(maxBytes: VVParser.maxFileBytes)
        }
        // Read into one bounded mutable buffer. Reserve an extra byte to
        // detect growth instead of accumulating independent Data chunks.
        let expectedBytes = Int(before.st_size)
        var data = Data(count: expectedBytes + 1)
        var transferred = 0
        var returned = false
        defer {
            if !returned { data.resetBytes(in: 0..<data.count) }
        }
        try data.withUnsafeMutableBytes { (buffer: UnsafeMutableRawBufferPointer) in
            guard let base = buffer.baseAddress else { throw SessionError.sourceFileUnavailable }
            while transferred < buffer.count {
                let amount = Darwin.read(fd, base.advanced(by: transferred), buffer.count - transferred)
                if amount < 0 {
                    if errno == EINTR { continue }
                    throw SessionError.sourceFileUnavailable
                }
                if amount == 0 { break }
                transferred += amount
            }
        }
        guard transferred <= VVParser.maxFileBytes else {
            throw SessionError.fileTooLarge(maxBytes: VVParser.maxFileBytes)
        }
        guard transferred == expectedBytes else { throw SessionError.sourceFileUnavailable }
        data.count = transferred
        var after = stat()
        guard fstat(fd, &after) == 0, Self.isRegular(after) else {
            throw SessionError.sourceFileUnavailable
        }
        let original = Self.identity(before, path: url.path)
        let final = Self.identity(after, path: url.path)
        guard original == final, final.size == UInt64(data.count),
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw SessionError.sourceFileUnavailable
        }
        // The returned identity is for the actual descriptor that supplied the bytes.
        // If the path changed meanwhile, import remains usable but cleanup is disabled.
        let current = try? identity(of: url)
        returned = true
        return (data, current == final ? final : nil)
    }

    public func identity(of url: URL) throws -> SourceFileIdentity {
        var info = stat()
        guard url.isFileURL, lstat(url.path, &info) == 0,
              Self.isRegular(info), info.st_size >= 0 else {
            throw SessionError.sourceFileUnavailable
        }
        return Self.identity(info, path: url.path)
    }

    private static func isRegular(_ info: stat) -> Bool {
        (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
    }

    private static func identity(_ info: stat, path: String) -> SourceFileIdentity {
        SourceFileIdentity(path: path, fileNumber: UInt64(info.st_ino),
            volumeIdentifier: UInt64(UInt32(bitPattern: info.st_dev)),
            size: UInt64(info.st_size),
            modificationTime: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    /// There is no conditional unlink-by-inode syscall on macOS. First move the
    /// directory entry atomically to a private directory on the same filesystem,
    /// then verify the moved object before unlinking. Never overwrite on restore.
    public func removeMatchingItem(at url: URL, identity expected: SourceFileIdentity) -> SourceCleanupResult {
        guard url.isFileURL, url.path == expected.path,
              url.pathExtension.lowercased() == "vv" else { return .skipped }
        let parent = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        let parentFD = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard parentFD >= 0 else { return .permissionDenied }
        defer { Darwin.close(parentFD) }
        var info = stat()
        guard fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return .permissionDenied }
        guard Self.isRegular(info), info.st_size >= 0,
              Self.identity(info, path: url.path) == expected else { return .replacedFilePreserved }

        let stage = ".macremoteviewer-cleanup-" + UUID().uuidString
        guard mkdirat(parentFD, stage, mode_t(0o700)) == 0 else { return .permissionDenied }
        defer { _ = unlinkat(parentFD, stage, AT_REMOVEDIR) } // only succeeds when empty
        let stageFD = openat(parentFD, stage, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stageFD >= 0 else { return .permissionDenied }
        defer { Darwin.close(stageFD) }
        let stagedName = name
        guard renameatx_np(parentFD, name, stageFD, stagedName, UInt32(RENAME_EXCL)) == 0 else {
            return .permissionDenied
        }
        var moved = stat()
        let matches = fstatat(stageFD, stagedName, &moved, AT_SYMLINK_NOFOLLOW) == 0
            && Self.isRegular(moved) && moved.st_size >= 0
            && Self.identity(moved, path: url.path) == expected
        if matches && unlinkat(stageFD, stagedName, 0) == 0 { return .deleted }

        // A new file may already occupy the original name. Preserve both rather
        // than replace it or delete the staged object; the hidden directory remains.
        let restored = renameatx_np(stageFD, stagedName, parentFD, name, UInt32(RENAME_EXCL)) == 0
        if !restored { return .permissionDenied }
        return matches ? .permissionDenied : .replacedFilePreserved
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
        deleteIfNeeded(sourceIdentity: profile.deleteSourceFile ? profile.sourceIdentity : nil, files: files)
    }

    /// Only an identity for a file explicitly marked for deletion is passed
    /// by the controller. No authentication data is needed for cleanup.
    public func deleteIfNeeded(sourceIdentity: SourceFileIdentity?, files: FileAccessing) -> SourceCleanupResult {
        guard deleteAfterSuccessfulConnect else { return .skipped }
        guard let identity = sourceIdentity, identity.fileNumber != 0,
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
        return files.removeMatchingItem(at: url, identity: identity)
    }
}

public enum SourceCleanupResult: Equatable, Sendable {
    case skipped
    case deleted
    case permissionDenied
    case replacedFilePreserved
}
