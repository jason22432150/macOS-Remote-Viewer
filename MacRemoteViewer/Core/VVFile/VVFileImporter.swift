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
        let identity: SourceFileIdentity?
        do {
            (data, identity) = try files.readIdentified(from: url)
        } catch let error as SessionError {
            throw error
        } catch {
            throw SessionError.sourceFileUnavailable
        }
        return try parser.parse(data: data, sourceIdentity: identity)
    }
}
