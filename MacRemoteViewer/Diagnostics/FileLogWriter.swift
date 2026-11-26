import Foundation
import Darwin
import OSLog

/// 檔案診斷紀錄的寫入端。測試可換成記憶體實作。
public protocol FileLogWriting: Sendable {
    var directoryURL: URL { get }
    func ensureDirectoryExists() throws
    func append(_ line: String) throws
}

public enum FileLogLocation {
    public static var defaultDirectory: URL {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        return library.appendingPathComponent("Logs/MacRemoteViewer", isDirectory: true)
    }
}

public struct FoundationFileLogWriter: FileLogWriting, Sendable {
    public let directoryURL: URL
    public let maximumFileBytes: Int
    public let retainedRotations: Int

    public init(directoryURL: URL = FileLogLocation.defaultDirectory,
                maximumFileBytes: Int = 5 * 1024 * 1024,
                retainedRotations: Int = 3) {
        self.directoryURL = directoryURL
        self.maximumFileBytes = max(1, maximumFileBytes)
        self.retainedRotations = min(max(1, retainedRotations), 10)
    }

    public func ensureDirectoryExists() throws {
        let fd = try openDirectory(create: true)
        Darwin.close(fd)
    }

    /// Anchor all child operations to the verified directory, not its path.
    /// An existing shared-writable or redirected directory is never adopted.
    private func openDirectory(create: Bool) throws -> Int32 {
        if create {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        let fd = Darwin.open(directoryURL.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0 {
            if !create && errno == ENOENT { return -1 }
            throw CocoaError(.fileWriteNoPermission)
        }
        var info = stat()
        guard fstat(fd, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              info.st_uid == geteuid(), (info.st_mode & mode_t(0o022)) == 0,
              ((info.st_mode & mode_t(0o7777)) == mode_t(0o700) ||
               fchmod(fd, mode_t(0o700)) == 0) else {
            Darwin.close(fd)
            throw CocoaError(.fileWriteNoPermission)
        }
        return fd
    }

    public func append(_ line: String) throws {
        let data = Data((line + "\n").utf8)
        guard data.count <= maximumFileBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        let directory = try openDirectory(create: true)
        defer { Darwin.close(directory) }
        let name = Self.fileName(for: Date())
        var fd = try openLog(directory, name)
        defer { if fd >= 0 { Darwin.close(fd) } }
        var info = stat()
        guard fstat(fd, &info) == 0, isOwnedRegular(info), info.st_size >= 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        if info.st_size > Int64(maximumFileBytes - data.count) {
            Darwin.close(fd)
            fd = -1
            try rotate(directory, name)
            fd = try openLog(directory, name)
        }
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
    }

    private func isOwnedRegular(_ info: stat) -> Bool {
        (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) &&
            info.st_nlink == 1 && info.st_uid == geteuid()
    }

    private func makePrivate(_ fd: Int32, _ info: stat) throws {
        guard isOwnedRegular(info),
              ((info.st_mode & mode_t(0o7777)) == mode_t(0o600) ||
               fchmod(fd, mode_t(0o600)) == 0) else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    private func openLog(_ directory: Int32, _ name: String) throws -> Int32 {
        let fd = Darwin.openat(directory, name,
            O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        do {
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw CocoaError(.fileWriteNoPermission) }
            try makePrivate(fd, info)
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func entry(_ directory: Int32, _ name: String) throws -> stat? {
        var info = stat()
        if fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileWriteNoPermission)
        }
        return info
    }

    private func privateExistingLog(_ directory: Int32, _ name: String, expected: stat) throws -> stat {
        let fd = Darwin.openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, isOwnedRegular(info),
              info.st_dev == expected.st_dev, info.st_ino == expected.st_ino else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try makePrivate(fd, info)
        return info
    }

    private func rotate(_ directory: Int32, _ name: String) throws {
        func rotation(_ number: Int) -> String { "\(name).\(number)" }
        func regularFileExists(_ candidate: String) throws -> Bool {
            guard let info = try entry(directory, candidate) else { return false }
            guard isOwnedRegular(info) else { throw CocoaError(.fileWriteNoPermission) }
            _ = try privateExistingLog(directory, candidate, expected: info)
            return true
        }
        // Check the entire rotation set before any unlink or rename.
        _ = try regularFileExists(name)
        for number in 1...retainedRotations {
            _ = try regularFileExists(rotation(number))
        }
        if try regularFileExists(rotation(retainedRotations)) {
            guard unlinkat(directory, rotation(retainedRotations), 0) == 0 else {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        if retainedRotations > 1 {
            for number in stride(from: retainedRotations - 1, through: 1, by: -1) {
                let source = rotation(number)
                if try regularFileExists(source) {
                    guard renameat(directory, source, directory, rotation(number + 1)) == 0 else {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                }
            }
        }
        if try regularFileExists(name) {
            guard renameat(directory, name, directory, rotation(1)) == 0 else {
                throw CocoaError(.fileWriteNoPermission)
            }
        }
    }

    /// Maintenance does not create a log directory when logging is disabled.
    /// Never follow links or touch unrelated files. Preserve the existing
    /// 30-day modification-time retention policy for owned regular logs.
    func maintainExistingLogs(now: Date = Date(), calendar: Calendar = .current) throws {
        let directory = try openDirectory(create: false)
        guard directory >= 0 else { return }
        defer { Darwin.close(directory) }
        guard let cutoff = calendar.date(byAdding: .day, value: -30, to: now) else { return }
        let copy = fcntl(directory, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { throw CocoaError(.fileReadUnknown) }
        guard let stream = fdopendir(copy) else {
            Darwin.close(copy)
            throw CocoaError(.fileReadUnknown)
        }
        defer { closedir(stream) }
        var hadError = false
        while true {
            errno = 0
            guard let item = readdir(stream) else {
                if errno != 0 { hadError = true }
                break
            }
            let length = Int(item.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &item.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: length) {
                    String(validatingUTF8: $0)
                }
            }
            guard let name,
                  name.range(of: #"\AMacRemoteViewer-[0-9]{4}-[0-9]{2}-[0-9]{2}\.log(?:\.([1-9]|10))?\z"#,
                             options: .regularExpression) != nil else { continue }
            do {
                guard let expected = try entry(directory, name), isOwnedRegular(expected) else { continue }
                let info = try privateExistingLog(directory, name, expected: expected)
                let modified = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) +
                                    Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
                if modified < cutoff {
                    // Recheck identity and link count immediately before unlink.
                    guard let current = try entry(directory, name), isOwnedRegular(current),
                          current.st_dev == info.st_dev, current.st_ino == info.st_ino,
                          current.st_mtimespec.tv_sec == info.st_mtimespec.tv_sec,
                          current.st_mtimespec.tv_nsec == info.st_mtimespec.tv_nsec else { continue }
                    guard unlinkat(directory, name, 0) == 0 else {
                        throw CocoaError(.fileWriteNoPermission)
                    }
                }
            } catch {
                // Finish protecting other entries even if one failed.
                hadError = true
            }
        }
        if hadError { throw CocoaError(.fileWriteNoPermission) }
    }

    public static func fileName(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "MacRemoteViewer-%04d-%02d-%02d.log",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

/// Default app sink: perform disk I/O on a bounded serial utility queue.
public final class AsyncFileLogWriter: FileLogWriting, @unchecked Sendable {
    private let writer: FoundationFileLogWriter
    private let queue = DispatchQueue(label: "local.MacRemoteViewer.file-log", qos: .utility)
    private let lock = NSLock()
    private let logger = Logger(subsystem: "local.MacRemoteViewer", category: "file-log")
    private var pending = 0
    private var lastPrunedDay: String?

    public init(writer: FoundationFileLogWriter = FoundationFileLogWriter()) {
        self.writer = writer
        // Protect historical logs even when no new event is written. Keep
        // filesystem work off the AppKit thread and on the same serial queue.
        queue.async { [self] in
            pruneIfNeeded()
        }
    }

    public var directoryURL: URL { writer.directoryURL }

    public func ensureDirectoryExists() throws { try writer.ensureDirectoryExists() }

    public func append(_ line: String) throws {
        lock.lock()
        guard pending < 512 else {
            lock.unlock()
            logger.error("file-log-queue-full")
            return
        }
        pending += 1
        lock.unlock()
        queue.async { [self] in
            defer {
                lock.lock()
                pending -= 1
                lock.unlock()
            }
            do {
                try writer.append(line)
                pruneIfNeeded()
            } catch {
                logger.error("file-log-write-failed")
            }
        }
    }

    private func pruneIfNeeded() {
        let now = Date()
        let day = FoundationFileLogWriter.fileName(for: now)
        guard lastPrunedDay != day else { return }
        do {
            try writer.maintainExistingLogs(now: now)
            lastPrunedDay = day
        } catch {
            // Retry on a later write rather than mark a failed pass complete.
            logger.error("file-log-maintenance-failed")
        }
    }
}

/// 可在工作階段中途開關檔案 log，而不必重建 `DiagnosticsLog`。
public final class FileLogSink: @unchecked Sendable {
    public let writer: any FileLogWriting
    private let lock = NSLock()
    private var enabled: Bool
    private let logger = Logger(subsystem: "local.MacRemoteViewer", category: "file-log")

    public init(enabled: Bool, writer: any FileLogWriting) {
        self.enabled = enabled
        self.writer = writer
    }

    public var isEnabled: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return enabled
        }
        set {
            lock.lock()
            enabled = newValue
            lock.unlock()
        }
    }

    public var directoryURL: URL { writer.directoryURL }

    public func ensureDirectoryExists() throws {
        try writer.ensureDirectoryExists()
    }

    public func write(level: String, message: String, sessionID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled else { return }
        let line = "\(Date().ISO8601Format()) \(DiagnosticLogPolicy.level(level)) \(DiagnosticLogPolicy.message(message)) session=\(DiagnosticLogPolicy.session(sessionID))"
        do {
            try writer.append(line)
        } catch {
            logger.error("file-log-write-failed")
        }
    }
}
