import SwiftSyntax

/// The documentation of an event case: the text describes the event, and the
/// DocC `- Parameter name:` and `- Parameters:` entries its properties. Lines
/// of one description are joined with single spaces and trimmed; other
/// callouts such as `- Note:` are not part of any description.
struct DocComment {
    private(set) var description = ""
    /// The described parameters, in the order they are described.
    private(set) var parameters: [(name: String, description: String)] = []

    func description(of parameter: String) -> String? {
        parameters.first { $0.name == parameter }?.description
    }

    init(_ trivia: [TriviaPiece]) {
        let lines = Self.lines(trivia)
        enum Target: Equatable {
            case description
            case parameter(Int)
            case ignored
        }
        var target = Target.description
        var itemIndent = 0
        var parametersIndent: Int?
        var afterBlank = false
        var descriptionLines: [String] = []
        var names: [String] = []
        var parameterLines: [[String]] = []

        func describe(_ name: String, _ text: String) {
            if let index = names.firstIndex(of: name) {
                target = .parameter(index)
                parameterLines[index].append(text)
            } else {
                names.append(name)
                parameterLines.append([text])
                target = .parameter(names.count - 1)
            }
        }

        for line in lines {
            let indent = line.prefix { $0 == " " }.count
            let text = Naming.trimmed(line)
            guard !text.isEmpty else {
                afterBlank = true
                continue
            }
            defer { afterBlank = false }

            if let item = Self.listItem(text) {
                let lowercased = item.lowercased()
                if let header = parametersIndent, indent > header, let (name, rest) = Self.entry(item) {
                    describe(name, rest)
                } else if lowercased.hasPrefix("parameters:") {
                    parametersIndent = indent
                    target = .ignored
                } else if lowercased.hasPrefix("parameter "), let (name, rest) = Self.entry(item.dropFirst("parameter ".count)) {
                    parametersIndent = nil
                    describe(name, rest)
                } else {
                    if let header = parametersIndent, indent <= header {
                        parametersIndent = nil
                    }
                    target = .ignored
                }
                itemIndent = indent
                continue
            }

            switch target {
            case .parameter(let index) where !afterBlank || indent > itemIndent:
                parameterLines[index].append(text)
            case .ignored where !afterBlank || indent > itemIndent:
                continue
            default:
                target = .description
                parametersIndent = nil
                descriptionLines.append(text)
            }
        }

        description = Naming.joined(descriptionLines)
        parameters = zip(names, parameterLines).map { ($0, Naming.joined($1)) }
    }

    /// The text of the doc comments among `trivia`, one entry per line, the
    /// comment markers and the indentation all lines share removed.
    private static func lines(_ trivia: [TriviaPiece]) -> [String] {
        var lines: [String] = []
        for piece in trivia {
            switch piece {
            case .docLineComment(let text):
                lines.append(String(text.dropFirst(3)))
            case .docBlockComment(let text):
                for line in text.dropFirst(3).dropLast(2).split(separator: "\n", omittingEmptySubsequences: false) {
                    let content = line.drop { $0 == " " || $0 == "\t" }
                    lines.append(String(content.hasPrefix("*") ? content.dropFirst() : line))
                }
            default:
                continue
            }
        }
        let shared = lines.filter { !Naming.trimmed($0).isEmpty }.map { $0.prefix { $0 == " " }.count }.min() ?? 0
        return lines.map { String($0.dropFirst(min(shared, $0.prefix { $0 == " " }.count))) }
    }

    /// The text of a Markdown list item, e.g. `Parameter title: Title.` of `- Parameter title: Title.`.
    private static func listItem(_ text: String) -> Substring? {
        guard let marker = text.first, "-*+".contains(marker) else {
            return nil
        }
        let rest = text.dropFirst()
        guard let space = rest.first, space == " " || space == "\t" else {
            return nil
        }
        return rest.drop { $0 == " " || $0 == "\t" }
    }

    /// The name and text of a `name: text` parameter entry.
    private static func entry(_ item: Substring) -> (String, String)? {
        guard let colon = item.firstIndex(of: ":") else {
            return nil
        }
        let name = Naming.trimmed(item[..<colon])
        guard !name.isEmpty, !name.contains(where: \.isWhitespace) else {
            return nil
        }
        return (name.trimmingBackticks, Naming.trimmed(item[item.index(after: colon)...]))
    }
}

extension String {
    /// The identifier without the backticks that escape a keyword.
    var trimmingBackticks: String {
        hasPrefix("`") && hasSuffix("`") && count > 1 ? String(dropFirst().dropLast()) : self
    }
}
