import XCTest
import Darwin
@testable import MacRemoteViewerCore

final class FileLogWriterTests: XCTestCase {
    func testDailyFileNameUsesCalendarDate() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 1, day: 27))!
        XCTAssertEqual(
            FoundationFileLogWriter.fileName(for: date, calendar: calendar),
            "MacRemoteViewer-2026-01-27.log"
        )
    }

    func testAppendCreatesDirectoryAndFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacRemoteViewer-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = FoundationFileLogWriter(directoryURL: directory)
        try writer.append("hello")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let contents = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertEqual(contents, "hello\n")
        try writer.append("world")
        let appended = try String(contentsOf: files[0], encoding: .utf8)
        XCTAssertEqual(appended, "hello\nworld\n")
    }

    func testLogRotationBoundsFileCountAndSize() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacRemoteViewer-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = FoundationFileLogWriter(directoryURL: directory, maximumFileBytes: 12, retainedRotations: 2)
        for line in ["aaa", "bbb", "ccc", "ddd", "eee", "fff", "ggg", "hhh", "iii", "jjj"] {
            try writer.append(line)
        }
        let active = directory.appendingPathComponent(FoundationFileLogWriter.fileName(for: Date()))
        XCTAssertEqual(try String(contentsOf: active, encoding: .utf8), "jjj\n")
        XCTAssertEqual(try String(contentsOf: active.appendingPathExtension("1"), encoding: .utf8), "ggg\nhhh\niii\n")
        XCTAssertEqual(try String(contentsOf: active.appendingPathExtension("2"), encoding: .utf8), "ddd\neee\nfff\n")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])
        XCTAssertEqual(files.count, 3)
        for url in files {
            XCTAssertLessThanOrEqual(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max, 12)
        }
    }

    func testLogWriterRefusesSymbolicLink() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacRemoteViewer-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent("untouched.txt")
        try Data("original".utf8).write(to: target)
        let active = directory.appendingPathComponent(FoundationFileLogWriter.fileName(for: Date()))
        try FileManager.default.createSymbolicLink(at: active, withDestinationURL: target)
        XCTAssertThrowsError(try FoundationFileLogWriter(directoryURL: directory).append("new log"))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
    }

    func testLogWriterMakesExistingOwnedFilePrivateBeforeAppend() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacRemoteViewer-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = FoundationFileLogWriter(directoryURL: directory)
        try writer.ensureDirectoryExists()
        let active = directory.appendingPathComponent(FoundationFileLogWriter.fileName(for: Date()))
        try Data("old\n".utf8).write(to: active)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: active.path)
        try writer.append("new")
        let attributes = try FileManager.default.attributesOfItem(atPath: active.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try String(contentsOf: active, encoding: .utf8), "old\nnew\n")
    }

    func testLogWriterRefusesRedirectedOrSharedWritableDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacRemoteViewer-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try FoundationFileLogWriter(directoryURL: link).append("blocked"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: target.path)
        XCTAssertThrowsError(try FoundationFileLogWriter(directoryURL: target).append("blocked"))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
    }

    func testHistoricalMaintenanceProtectsOwnedLogsAndPrunesOnlyExpiredEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacRemoteViewer-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        let directory = root.appendingPathComponent("logs", isDirectory: true)
        let writer = FoundationFileLogWriter(directoryURL: directory)
        try writer.maintainExistingLogs()
        XCTAssertFalse(fm.fileExists(atPath: directory.path))
        try writer.ensureDirectoryExists()
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let old = now.addingTimeInterval(-40 * 86400)
        let recent = now.addingTimeInterval(-5 * 86400)
        func make(_ name: String, modified: Date) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data("historical\n".utf8).write(to: url)
            try fm.setAttributes([.posixPermissions: 0o644, .modificationDate: modified], ofItemAtPath: url.path)
            return url
        }
        let expired = try make("MacRemoteViewer-2026-01-01.log.1", modified: old)
        let active = try make("MacRemoteViewer-2026-02-01.log", modified: recent)
        let rotated = try make("MacRemoteViewer-2026-02-01.log.3", modified: recent)
        let unrelated = try make("unrelated.log", modified: old)
        let link = directory.appendingPathComponent("MacRemoteViewer-2026-01-02.log")
        try fm.createSymbolicLink(at: link, withDestinationURL: unrelated)
        let hardLink = directory.appendingPathComponent("MacRemoteViewer-2026-01-03.log")
        try fm.linkItem(at: unrelated, to: hardLink)
        let fifo = directory.appendingPathComponent("MacRemoteViewer-2026-01-04.log")
        XCTAssertEqual(mkfifo(fifo.path, mode_t(0o600)), 0)
        try writer.maintainExistingLogs(now: now)
        XCTAssertFalse(fm.fileExists(atPath: expired.path))
        for url in [active, rotated] {
            let attributes = try fm.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "historical\n")
        }
        let mode = try fm.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: link.path), unrelated.path)
        XCTAssertTrue(fm.fileExists(atPath: hardLink.path))
        XCTAssertTrue(fm.fileExists(atPath: fifo.path))
        let unrelatedMode = try fm.attributesOfItem(atPath: unrelated.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(unrelatedMode?.intValue, 0o644)
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), "historical\n")
    }

    func testRotationRefusesSuspiciousHistoricalEntryWithoutOverwritingTarget() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacRemoteViewer-log-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = FoundationFileLogWriter(directoryURL: directory, maximumFileBytes: 8, retainedRotations: 2)
        try writer.append("1234567")
        let active = directory.appendingPathComponent(FoundationFileLogWriter.fileName(for: Date()))
        let target = directory.appendingPathComponent("untouched.txt")
        try Data("original".utf8).write(to: target)
        let rotation = active.appendingPathExtension("2")
        try FileManager.default.createSymbolicLink(at: rotation, withDestinationURL: target)
        XCTAssertThrowsError(try writer.append("next"))
        XCTAssertEqual(try String(contentsOf: active, encoding: .utf8), "1234567\n")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "original")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: rotation.path), target.path)
    }

    func testSinkDoesNotWriteWhenDisabled() throws {
        let writer = MemoryFileLogWriter()
        let sink = FileLogSink(enabled: false, writer: writer)
        sink.write(level: "INFO", message: "connected", sessionID: "abc")
        XCTAssertTrue(writer.lines.isEmpty)
        sink.isEnabled = true
        sink.write(level: "INFO", message: "connected", sessionID: "abc")
        XCTAssertEqual(writer.lines.count, 1)
        XCTAssertTrue(writer.lines[0].contains("INFO connected session=<redacted>"))
    }
}

final class MemoryFileLogWriter: FileLogWriting, @unchecked Sendable {
    var lines: [String] = []
    let directoryURL = URL(fileURLWithPath: "/tmp/MacRemoteViewerTests")

    func ensureDirectoryExists() throws {}

    func append(_ line: String) throws {
        lines.append(line)
    }
}
