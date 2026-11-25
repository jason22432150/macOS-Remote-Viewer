import Foundation
import Security

/// virt-viewer INI／GKeyFile 風格解析器。未知欄位只記錄名稱，不執行其中的文字。
public struct VVParser: Sendable {
    public static let maxFileBytes = 512 * 1024
    public static let virtViewerSection = "virt-viewer"
    public static let criticalFields: Set<String> = [
        "type", "host", "port", "tls-port", "password", "ca", "host-subject", "proxy", "delete-this-file"
    ]

    public init() {}

    public func parse(data: Data, sourceIdentity: SourceFileIdentity? = nil) throws -> ConnectionProfile {
        guard data.count <= Self.maxFileBytes else {
            throw SessionError.fileTooLarge(maxBytes: Self.maxFileBytes)
        }
        // C/GLib APIs consume NUL-terminated strings. Reject embedded NULs
        // rather than silently truncating host, credentials or certificate subjects.
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw SessionError.invalidEncoding
        }
        let document = try INIDocument.parse(text)
        guard let section = document.sections[Self.virtViewerSection] else {
            throw SessionError.missingSection
        }

        for name in Self.criticalFields where section.duplicateKeys.contains(name) {
            throw SessionError.duplicateField(name)
        }

        let type = try requiredString("type", in: section).lowercased()
        guard type == "spice" else {
            throw SessionError.unsupportedType(type)
        }

        let host = try requiredString("host", in: section)
        if section.values["port"] != nil && section.values["tls-port"] == nil {
            throw SessionError.plaintextPortNotAllowed
        }
        let tlsPort = try requiredPort("tls-port", in: section)
        let password = try requiredString("password", in: section)
        let caPEM = try decodeCA(try requiredString("ca", in: section))
        let hostSubject = try requiredString("host-subject", in: section)
        let proxyURL = try optionalProxy(section.values["proxy"])
        try Self.validateTransport(host: host, tlsPort: tlsPort, proxyURL: proxyURL,
                                   hostSubject: hostSubject, ticket: password)
        let title = section.values["title"]?.isEmpty == false ? section.values["title"]! : "SPICE Session"
        let deleteSourceFile = try optionalBool(section.values["delete-this-file"]) ?? false

        let toggleFullscreen = try HotKeyParser.parse(section.values["toggle-fullscreen"] ?? "Shift+F11")
        let releaseCursor = try HotKeyParser.parse(section.values["release-cursor"] ?? "Ctrl+Alt+R")
        let secureAttention = try HotKeyParser.parse(section.values["secure-attention"] ?? "Ctrl+Alt+Ins")

        let knownKeys: Set<String> = [
            "type", "host", "port", "tls-port", "username", "password", "ca", "host-subject",
            "proxy", "title", "delete-this-file", "toggle-fullscreen", "release-cursor",
            "secure-attention", "fullscreen", "enable-usbredir", "enable-usb-autoshare",
            "usb-filter", "tls-ciphers", "secure-channels", "disable-channels",
            "color-depth", "disable-effects", "version", "versions", "newer-version-url",
            "unix-path", "enable-smartcard", "smartcard-insert", "smartcard-remove"
        ]
        let unknownFieldNames = section.values.keys
            .filter { !knownKeys.contains($0) }
            .sorted()

        return ConnectionProfile(
            title: title,
            host: host,
            tlsPort: tlsPort,
            proxyURL: proxyURL,
            caPEM: caPEM,
            hostSubject: hostSubject,
            ticket: .init(password),
            deleteSourceFile: deleteSourceFile,
            toggleFullscreen: toggleFullscreen,
            releaseCursor: releaseCursor,
            secureAttention: secureAttention,
            unknownFieldNames: unknownFieldNames,
            sourceIdentity: sourceIdentity
        )
    }

    private func requiredString(_ key: String, in section: INIDocument.Section) throws -> String {
        guard let value = section.values[key], !value.isEmpty else {
            throw SessionError.missingField(key)
        }
        return value
    }

    private func requiredPort(_ key: String, in section: INIDocument.Section) throws -> UInt16 {
        let raw = try requiredString(key, in: section)
        guard let value = UInt16(raw), value > 0 else {
            throw SessionError.invalidPort(key)
        }
        return value
    }

    private func optionalBool(_ raw: String?) throws -> Bool? {
        guard let raw else { return nil }
        switch raw {
        case "1", "true", "True":
            return true
        case "0", "false", "False":
            return false
        default:
            throw SessionError.invalidBoolean(raw)
        }
    }

    private func optionalProxy(_ raw: String?) throws -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        return try Self.validatedProxy(raw)
    }

    // Check after INI unescaping, not only the raw file bytes. The same
    // validation is used before crossing the Swift/GLib boundary, including
    // profiles constructed programmatically without the parser.
    public static func validateTransport(host: String, tlsPort: UInt16, proxyURL: URL?,
                                         hostSubject: String, ticket: String) throws {
        guard isHostToken(host) else { throw SessionError.invalidHost }
        guard tlsPort != 0 else { throw SessionError.invalidPort("tls-port") }
        guard !hostSubject.isEmpty, !ticket.isEmpty,
              !containsControl(hostSubject), !containsControl(ticket) else {
            throw SessionError.invalidConnectionField
        }
        if let proxyURL {
            _ = try validatedProxy(proxyURL.absoluteString)
        }
    }

    private static func containsControl(_ value: String) -> Bool {
        let forbidden = CharacterSet.controlCharacters.union(.newlines)
        return value.unicodeScalars.contains { forbidden.contains($0) }
    }

    private static func isHostToken(_ value: String) -> Bool {
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
            .union(CharacterSet(charactersIn: "/\\?#@"))
        // Do not impose an ASCII-only DNS policy: existing IPv6, IDN and
        // local hostname forms remain accepted here. Resolution and TLS
        // subject validation are still the native transport's responsibility.
        return !value.isEmpty && !value.unicodeScalars.contains { forbidden.contains($0) }
    }

    private static func validatedProxy(_ raw: String) throws -> URL {
        guard !containsControl(raw),
              !raw.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
              let parts = URLComponents(string: raw),
              let scheme = parts.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = parts.host, isHostToken(host),
              parts.percentEncodedPath.isEmpty || parts.percentEncodedPath == "/",
              parts.query == nil, parts.fragment == nil,
              !containsControl(parts.user ?? ""), !containsControl(parts.password ?? ""),
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              let url = parts.url else {
            throw SessionError.invalidProxy
        }
        return url
    }

    /// GKeyFile 風格還原 `\n` `\t` `\r` `\s` `\\`，供 PEM 使用。
    private func decodeCA(_ raw: String) throws -> Data {
        try Self.validatedCA(raw)
    }

    /// Structural validation of every PEM certificate. This is not server trust
    /// evaluation: SPICE still performs CA-chain and subject verification.
    public static func validatedCA(_ raw: String) throws -> Data {
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        var lines: [String] = []
        var body: [String]? = nil
        var certificates = 0
        for rawLine in raw.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line == begin {
                guard body == nil else { throw SessionError.invalidCA }
                body = []
            } else if line == end {
                guard let parts = body, !parts.isEmpty,
                      let der = Data(base64Encoded: parts.joined()),
                      SecCertificateCreateWithData(nil, der as CFData) != nil else {
                    throw SessionError.invalidCA
                }
                lines.append(begin)
                let encoded = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
                lines.append(encoded)
                lines.append(end)
                certificates += 1
                body = nil
            } else {
                guard body != nil, line.utf8.allSatisfy({
                    (65...90).contains($0) || (97...122).contains($0) ||
                    (48...57).contains($0) || $0 == 43 || $0 == 47 || $0 == 61
                }) else { throw SessionError.invalidCA }
                body?.append(line)
            }
        }
        guard body == nil, certificates > 0 else { throw SessionError.invalidCA }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}

/// 保守的 INI 讀取；重複的必要欄位會被記錄，不靜默覆蓋。
struct INIDocument {
    struct Section {
        var values: [String: String] = [:]
        var duplicateKeys: Set<String> = []
    }

    var sections: [String: Section] = [:]

    static func parse(_ text: String) throws -> INIDocument {
        var document = INIDocument()
        var currentName: String?
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)

        for rawLine in lines {
            var line = String(rawLine)
            if line.hasSuffix("\r") {
                line.removeLast()
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("#") || trimmed.hasPrefix(";") { continue }

            if trimmed.hasPrefix("["), trimmed.hasSuffix("]"), trimmed.count >= 2 {
                let name = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces).lowercased()
                currentName = name
                if document.sections[name] == nil {
                    document.sections[name] = Section()
                }
                continue
            }

            guard let currentName else { continue }
            guard let separator = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<separator]).trimmingCharacters(in: .whitespaces).lowercased()
            let rawValue = String(trimmed[trimmed.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            let value = unescape(rawValue)

            // Mutate through the dictionary's modify accessor instead of copying
            // the section's full values dictionary on every line.
            if document.sections[currentName, default: Section()].values.updateValue(value, forKey: key) != nil {
                document.sections[currentName, default: Section()].duplicateKeys.insert(key)
            }
        }

        return document
    }

    static func unescape(_ raw: String) -> String {
        var result = ""
        result.reserveCapacity(raw.count)
        var iterator = raw.makeIterator()
        while let character = iterator.next() {
            if character == "\\" {
                guard let next = iterator.next() else {
                    result.append(character)
                    break
                }
                switch next {
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "s": result.append(" ")
                case "\\": result.append("\\")
                default:
                    result.append(next)
                }
            } else {
                result.append(character)
            }
        }
        return result
    }
}
