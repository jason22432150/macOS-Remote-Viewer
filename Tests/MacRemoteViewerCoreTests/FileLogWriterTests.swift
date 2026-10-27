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
