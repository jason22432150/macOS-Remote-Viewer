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
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        // Refuse a redirected or shared-writable leaf directory. Existing
        // owner-only writable directories remain usable (including 0755).
        guard lstat(directoryURL.path, &info) == 0,
              (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              info.st_uid == geteuid(), (info.st_mode & mode_t(0o022)) == 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
    }

    public func append(_ line: String) throws {
        try ensureDirectoryExists()
        let url = directoryURL.appendingPathComponent(Self.fileName(for: Date()), isDirectory: false)
        let data = Data((line + "\n").utf8)
        guard data.count <= maximumFileBytes else { throw CocoaError(.fileWriteOutOfSpace) }
        // The application uses a single serial AsyncFileLogWriter. Do not follow
        // symlinks or write into special files, and create private log files.
        var fd = try openLog(url)
        defer { if fd >= 0 { Darwin.close(fd) } }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_nlink == 1, info.st_size >= 0 else {
            throw CocoaError(.fileWriteNoPermission)
        }
        if info.st_size > Int64(maximumFileBytes - data.count) {
            Darwin.close(fd)
            fd = -1
            try rotate(url)
            fd = try openLog(url)
        }
        // O_APPEND prevents seek/write races. FileHandle does not own this fd.
        try FileHandle(fileDescriptor: fd, closeOnDealloc: false).write(contentsOf: data)
    }

    private func openLog(_ url: URL) throws -> Int32 {
        let fd = Darwin.open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_nlink == 1, info.st_uid == geteuid() else {
            Darwin.close(fd)
            throw CocoaError(.fileWriteNoPermission)
        }
        // O_CREAT's mode does not change an existing file. Tighten legacy
        // permissions via the verified descriptor before appending, never
        // through a path which might now refer to a different file.
        if (info.st_mode & mode_t(0o7777)) != mode_t(0o600) &&
            fchmod(fd, mode_t(0o600)) != 0 {
            Darwin.close(fd)
            throw CocoaError(.fileWriteNoPermission)
        }
        return fd
    }

    private func rotate(_ url: URL) throws {
        let fm = FileManager.default
        func rotation(_ number: Int) -> URL {
            url.appendingPathExtension(String(number))
        }
        func regularFileExists(_ candidate: URL) throws -> Bool {
            var info = stat()
            if lstat(candidate.path, &info) != 0 {
                if errno == ENOENT { return false }
                throw CocoaError(.fileWriteNoPermission)
            }
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), info.st_nlink == 1,
                  info.st_uid == geteuid() else {
                throw CocoaError(.fileWriteNoPermission)
            }
            return true
        }
        // Refuse suspicious entries before touching any file.
        for number in 1...retainedRotations {
            _ = try regularFileExists(rotation(number))
        }
        if try regularFileExists(rotation(retainedRotations)) {
            try fm.removeItem(at: rotation(retainedRotations))
        }
        if retainedRotations > 1 {
            for number in stride(from: retainedRotations - 1, through: 1, by: -1) {
                let source = rotation(number)
                if try regularFileExists(source) {
                    try fm.moveItem(at: source, to: rotation(number + 1))
                }
            }
        }
        if try regularFileExists(url) {
            try fm.moveItem(at: url, to: rotation(1))
        }
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

    // Only delete this application's dated log files, never unrelated user files.
    private func pruneIfNeeded() {
        let now = Date()
        let day = FoundationFileLogWriter.fileName(for: now)
        guard lastPrunedDay != day else { return }
        lastPrunedDay = day
        guard (try? writer.ensureDirectoryExists()) != nil,
              let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: now) else { return }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directoryURL,
            includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return }
        for url in urls {
            guard url.lastPathComponent.range(of: #"^MacRemoteViewer-[0-9]{4}-[0-9]{2}-[0-9]{2}\.log(\.([1-9]|10))?$"#,
                options: .regularExpression) != nil,
                let values = try? url.resourceValues(forKeys: keys),
                values.isRegularFile == true, values.isSymbolicLink != true,
                let modified = values.contentModificationDate, modified < cutoff else { continue }
            try? FileManager.default.removeItem(at: url)
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
