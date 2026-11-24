import Foundation
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

    public init(directoryURL: URL = FileLogLocation.defaultDirectory) {
        self.directoryURL = directoryURL
    }

    public func ensureDirectoryExists() throws {
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    public func append(_ line: String) throws {
        try ensureDirectoryExists()
        let url = directoryURL.appendingPathComponent(Self.fileName(for: Date()), isDirectory: false)
        let data = Data((line + "\n").utf8)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        } else {
            try data.write(to: url, options: .atomic)
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
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: now) else { return }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directoryURL,
            includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else { return }
        for url in urls {
            guard url.lastPathComponent.range(of: #"^MacRemoteViewer-[0-9]{4}-[0-9]{2}-[0-9]{2}\.log$"#,
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
        let line = "\(Date().ISO8601Format()) \(level) \(message) session=\(sessionID)"
        do {
            try writer.append(line)
        } catch {
            logger.error("file-log-write-failed")
        }
    }
}
