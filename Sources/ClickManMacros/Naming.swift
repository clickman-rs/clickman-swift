/// How declarations become catalog names and descriptions (docs/PROTOCOL.md,
/// Event catalog), the same as `ClickManNaming` in the ClickMan runtime.
enum Naming {
    static let maxEvents = 1_000
    static let maxProperties = 128
    static let maxEventName = 200
    static let maxPropertyName = 128
    static let maxDescription = 1_000

    /// The events the SDKs record themselves (protocol/standard-events.json),
    /// which an application catalog cannot declare.
    static let standardEvents: Set<String> = ["app_installed", "app_updated", "app_opened", "app_backgrounded", "page_view"]

    /// `ExportCompleted`, `exportCompleted` and `EXPORT_COMPLETED` all become
    /// `export_completed`: words split at non-alphanumerics, at a lowercase
    /// letter or digit before an uppercase letter, and before the last
    /// capital of an acronym (`HTTPStatus` is `http_status`).
    static func snakeCase(_ name: String) -> String {
        enum Mode { case boundary, lowercase, uppercase }
        var words: [String] = []
        for part in name.split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
            let characters = Array(part)
            var start = 0
            var mode = Mode.boundary
            for index in characters.indices {
                let character = characters[index]
                guard index + 1 < characters.count else {
                    words.append(String(characters[start...]))
                    break
                }
                let next = characters[index + 1]
                let nextMode = character.isLowercase ? .lowercase : character.isUppercase ? .uppercase : mode
                if nextMode == .lowercase && next.isUppercase {
                    words.append(String(characters[start...index]))
                    start = index + 1
                    mode = .boundary
                } else if mode == .uppercase && character.isUppercase && next.isLowercase {
                    words.append(String(characters[start..<index]))
                    start = index
                    mode = .boundary
                } else {
                    mode = nextMode
                }
            }
        }
        return words.map { $0.lowercased() }.joined(separator: "_")
    }

    /// Whether `name` is a catalog name: `^[a-z][a-z0-9_]*$`, at most `limit` characters.
    static func isName(_ name: String, limit: Int) -> Bool {
        guard let first = name.unicodeScalars.first, ("a"..."z").contains(first), name.unicodeScalars.count <= limit else {
            return false
        }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }

    /// Lines joined with single spaces, each trimmed.
    static func joined(_ lines: [String]) -> String {
        lines.map(trimmed).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Whether `text` leaves its line: a control character, such as a tab
    /// inside the text, or a Unicode line or paragraph separator.
    static func leavesTheLine(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.generalCategory == .control || $0 == "\u{2028}" || $0 == "\u{2029}" }
    }

    static func trimmed(_ text: some StringProtocol) -> String {
        let isSpace: (Character) -> Bool = { $0 == " " || $0 == "\t" }
        return String(text.drop(while: isSpace).reversed().drop(while: isSpace).reversed())
    }

    /// `text` as a Swift string literal.
    static func literal(_ text: String) -> String {
        var literal = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": literal += "\\\\"
            case "\"": literal += "\\\""
            case "\t": literal += "\\t"
            case "\n": literal += "\\n"
            case "\r": literal += "\\r"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                literal += "\\u{\(String(scalar.value, radix: 16))}"
            default: literal.unicodeScalars.append(scalar)
            }
        }
        return literal + "\""
    }
}
