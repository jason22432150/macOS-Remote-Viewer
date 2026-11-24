import XCTest
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

    func testSinkDoesNotWriteWhenDisabled() throws {
        let writer = MemoryFileLogWriter()
        let sink = FileLogSink(enabled: false, writer: writer)
        sink.write(level: "INFO", message: "connected", sessionID: "abc")
        XCTAssertTrue(writer.lines.isEmpty)
        sink.isEnabled = true
        sink.write(level: "INFO", message: "connected", sessionID: "abc")
        XCTAssertEqual(writer.lines.count, 1)
        XCTAssertTrue(writer.lines[0].contains("INFO connected session=abc"))
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
