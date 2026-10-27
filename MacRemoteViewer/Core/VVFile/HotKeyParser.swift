import Foundation

/// virt-viewer／SPICE 快捷鍵字串，例如 `Shift+F11`、`Ctrl+Alt+R`。
public struct HotKeyChord: Equatable, Sendable, Hashable {
    public var control: Bool
    public var option: Bool
    public var shift: Bool
    public var command: Bool
    public var symbol: HotKeySymbol

    public init(
        control: Bool = false,
        option: Bool = false,
        shift: Bool = false,
        command: Bool = false,
        symbol: HotKeySymbol
    ) {
        self.control = control
        self.option = option
        self.shift = shift
        self.command = command
        self.symbol = symbol
    }

    public var displayName: String {
        var parts: [String] = []
        if control { parts.append("Ctrl") }
        if option { parts.append("Alt") }
        if shift { parts.append("Shift") }
        if command { parts.append("Cmd") }
        parts.append(symbol.displayName)
        return parts.joined(separator: "+")
    }
}

public enum HotKeySymbol: Equatable, Sendable, Hashable {
    case character(Character)
    case function(Int)
    case insert
    case delete
    case unnamed(String)

    public var displayName: String {
        switch self {
        case .character(let character):
            return String(character).uppercased()
        case .function(let number):
            return "F\(number)"
        case .insert:
            return "Ins"
        case .delete:
            return "Del"
        case .unnamed(let raw):
            return raw
        }
    }
}

public enum HotKeyParser {
    public static func parse(_ raw: String) throws -> HotKeyChord {
        let tokens = raw.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !tokens.isEmpty else { throw SessionError.invalidHotKey(raw) }

        var control = false
        var option = false
        var shift = false
        var command = false
        var symbol: HotKeySymbol?

        for token in tokens {
            switch token.lowercased() {
            case "ctrl", "control":
                control = true
            case "alt", "option", "opt":
                option = true
            case "shift":
                shift = true
            case "cmd", "command", "meta", "super", "win":
                command = true
            case "ins", "insert":
                symbol = .insert
            case "del", "delete":
                symbol = .delete
            default:
                if token.count >= 2, token.uppercased().first == "F",
                   let number = Int(token.dropFirst()), (1...24).contains(number) {
                    symbol = .function(number)
                } else if token.count == 1, let character = token.uppercased().first {
                    symbol = .character(character)
                } else {
                    symbol = .unnamed(token)
                }
            }
        }

        guard let symbol else { throw SessionError.invalidHotKey(raw) }
        return HotKeyChord(
            control: control,
            option: option,
            shift: shift,
            command: command,
            symbol: symbol
        )
    }
}
