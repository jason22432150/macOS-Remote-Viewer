import Foundation

/// 負責讀檔與 security-scoped 存取，不建立連線。
public struct VVFileImporter: Sendable {
    private let files: FileAccessing
    private let parser: VVParser

    public init(files: FileAccessing = FoundationFileAccessor(), parser: VVParser = VVParser()) {
        self.files = files
        self.parser = parser
    }

    public func importFile(at url: URL) throws -> ConnectionProfile {
        let accessed = files.startAccessing(url)
        defer {
            if accessed {
                files.stopAccessing(url)
            }
        }
        let data: Data
        do {
            data = try files.read(from: url)
        } catch let error as SessionError {
            throw error
        } catch {
            throw SessionError.sourceFileUnavailable
        }
        let identity: SourceFileIdentity?
        do {
            identity = try files.identity(of: url)
        } catch {
            identity = nil
        }
        return try parser.parse(data: data, sourceIdentity: identity)
    }
}
