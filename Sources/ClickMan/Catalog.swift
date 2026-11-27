import Foundation

/// What a source tracks (docs/PROTOCOL.md, Event catalog; catalog.json): every
/// event with its meaning and every property with its meaning, type and
/// whether it is required, in declaration order. Export it with `json` or
/// `jsonString` for upload; the events on the wire do not change.
public struct ClickManCatalog: Equatable, Sendable {
    /// The catalog format.
    public static let version = 1

    public var events: [Event]

    public init(events: [Event]) {
        self.events = events
    }

    /// The events of several declarations, in order, as one catalog.
    public init(_ catalogs: ClickManCatalog...) {
        events = catalogs.flatMap(\.events)
    }

    public struct Event: Equatable, Sendable {
        public var name: String
        public var description: String
        public var properties: [Property]

        /// `description` may span lines: they are joined with single spaces and trimmed.
        public init(name: String, description: String, properties: [Property] = []) {
            self.name = name
            self.description = ClickManNaming.description(description)
            self.properties = properties
        }
    }

    public struct Property: Equatable, Sendable {
        public enum Kind: String, Sendable {
            case string
            case integer
            case number
            case boolean
        }

        public var name: String
        public var description: String
        public var type: Kind
        /// The only strings a `string` property takes; nil for free text and other types.
        public var values: [String]?
        /// Whether a `string` property is free text.
        public var isText: Bool
        /// A required property is in every event; an optional one is left out when absent.
        public var isRequired: Bool

        public init(name: String, description: String, type: Kind, values: [String]? = nil, isText: Bool = false, isRequired: Bool) {
            self.name = name
            self.description = ClickManNaming.description(description)
            self.type = type
            self.values = values
            self.isText = isText
            self.isRequired = isRequired
        }

        public static func integer(_ name: String, description: String, required: Bool) -> Self {
            Self(name: name, description: description, type: .integer, isRequired: required)
        }

        public static func number(_ name: String, description: String, required: Bool) -> Self {
            Self(name: name, description: description, type: .number, isRequired: required)
        }

        public static func boolean(_ name: String, description: String, required: Bool) -> Self {
            Self(name: name, description: description, type: .boolean, isRequired: required)
        }

        /// A free-text string, declared as `ClickManText`.
        public static func text(_ name: String, description: String, required: Bool) -> Self {
            Self(name: name, description: description, type: .string, isText: true, isRequired: required)
        }

        /// A string that takes only the values of `Values`, in declaration order.
        public static func values<Values: ClickManValues>(
            _ name: String, description: String, of _: Values.Type, required: Bool
        ) -> Self {
            Self(name: name, description: description, type: .string, values: Values.allCases.map(\.clickManValue), isRequired: required)
        }
    }

    /// The catalog as JSON, the same text for the same declarations: fields in
    /// catalog.json order, one line per property.
    public var json: Data {
        Data(jsonString.utf8)
    }

    /// The catalog as JSON text, e.g. for an app's command line to print for upload.
    public var jsonString: String {
        let events = events.map { event in
            let properties = event.properties.map { property in
                var fields = [
                    "\"name\": \(Self.quoted(property.name))",
                    "\"description\": \(Self.quoted(property.description))",
                    "\"type\": \(Self.quoted(property.type.rawValue))",
                ]
                if let values = property.values {
                    fields.append("\"values\": [\(values.map(Self.quoted).joined(separator: ", "))]")
                }
                if property.isText {
                    fields.append("\"text\": true")
                }
                fields.append("\"required\": \(property.isRequired)")
                return "        { \(fields.joined(separator: ", ")) }"
            }
            return """
                {
                  "name": \(Self.quoted(event.name)),
                  "description": \(Self.quoted(event.description)),
                  "properties": \(Self.list(properties, closing: "      "))
                }
            """
        }
        return """
        {
          "version": \(Self.version),
          "events": \(Self.list(events, closing: "  "))
        }

        """
    }

    /// A JSON array of `items`, each on a line of its own.
    private static func list(_ items: [String], closing indent: String) -> String {
        items.isEmpty ? "[]" : "[\n\(items.joined(separator: ",\n"))\n\(indent)]"
    }

    /// `text` as a JSON string (RFC 8259).
    private static func quoted(_ text: String) -> String {
        var quoted = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": quoted += "\\\""
            case "\\": quoted += "\\\\"
            case "\n": quoted += "\\n"
            case "\r": quoted += "\\r"
            case "\t": quoted += "\\t"
            case _ where scalar.value < 0x20:
                quoted += "\\u" + String(repeating: "0", count: 4 - String(scalar.value, radix: 16).count) + String(scalar.value, radix: 16)
            default: quoted.unicodeScalars.append(scalar)
            }
        }
        return quoted + "\""
    }
}

extension ClickManCatalog {
    /// Why the server refuses a catalog on upload, with its reason from
    /// catalog.json, e.g. `invalid_values`.
    public struct Problem: Error, Equatable, CustomStringConvertible {
        public let reason: String
        public let detail: String

        public var description: String {
            "\(reason): \(detail)"
        }
    }

    /// The events the SDKs record themselves (protocol/standard-events.json),
    /// which an application catalog cannot declare.
    static let standardEvents: Set<String> = ["app_installed", "app_updated", "app_opened", "app_backgrounded", "page_view"]

    /// Checks the catalog as the server does on upload and throws its first
    /// problem. `@ClickManEvents` refuses most problems at compile time; this
    /// also covers the values of `ClickManValues` enums and hand-written
    /// catalogs, e.g. `try AppEvent.catalog.validate()` in a unit test.
    public func validate() throws {
        guard events.count <= 1_000 else {
            throw Problem(reason: "malformed_catalog", detail: "a catalog declares at most 1000 events")
        }
        var eventNames: Set<String> = []
        for event in events {
            guard Self.isName(event.name, limit: 200) else {
                throw Problem(reason: "invalid_name", detail: "event \(event.name) is not snake case of 1 to 200 characters")
            }
            guard !Self.standardEvents.contains(event.name) else {
                throw Problem(reason: "standard_event", detail: "event \(event.name) is recorded by the SDKs themselves")
            }
            guard eventNames.insert(event.name).inserted else {
                throw Problem(reason: "duplicate_name", detail: "event \(event.name) is declared twice")
            }
            try Self.check(event.description, of: "event \(event.name)")
            guard event.properties.count <= 128 else {
                throw Problem(reason: "malformed_catalog", detail: "event \(event.name) declares more than 128 properties")
            }
            var propertyNames: Set<String> = []
            for property in event.properties {
                try Self.check(property, of: "\(event.name).\(property.name)", names: &propertyNames)
            }
        }
    }

    private static func check(_ property: Property, of path: String, names: inout Set<String>) throws {
        guard isName(property.name, limit: 128) else {
            throw Problem(reason: "invalid_name", detail: "property \(path) is not snake case of 1 to 128 characters")
        }
        guard names.insert(property.name).inserted else {
            throw Problem(reason: "duplicate_name", detail: "property \(path) is declared twice")
        }
        try check(property.description, of: "property \(path)")
        switch (property.type, property.values, property.isText) {
        case (.string, .some, true):
            throw Problem(reason: "invalid_values", detail: "property \(path) declares both values and text")
        case (.string, nil, false):
            throw Problem(reason: "undeclared_text", detail: "string property \(path) declares neither values nor text")
        case (.string, let values?, false):
            guard (1...100).contains(values.count) else {
                throw Problem(reason: "invalid_values", detail: "property \(path) declares 1 to 100 values")
            }
            var seen: Set<String> = []
            for value in values {
                guard (1...1_024).contains(value.unicodeScalars.count),
                      !value.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
                      seen.insert(value).inserted else {
                    throw Problem(reason: "invalid_values", detail: "property \(path) has an empty, long, repeated or control-character value \(value)")
                }
            }
        case (.string, nil, true), (_, nil, false):
            return
        default:
            throw Problem(reason: "invalid_values", detail: "property \(path) declares values or text but is not a string")
        }
    }

    private static func check(_ description: String, of subject: String) throws {
        guard !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Problem(reason: "missing_description", detail: "\(subject) has no description")
        }
        guard description.unicodeScalars.count <= 1_000, !description.unicodeScalars.contains(where: isOffTheLine) else {
            throw Problem(reason: "invalid_description", detail: "the description of \(subject) is not one line of at most 1000 characters without control characters")
        }
    }

    /// A control character, line breaks included, or a Unicode line or paragraph separator.
    private static func isOffTheLine(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.generalCategory == .control || scalar == "\u{2028}" || scalar == "\u{2029}"
    }

    /// `^[a-z][a-z0-9_]*$` with at most `limit` characters.
    private static func isName(_ name: String, limit: Int) -> Bool {
        guard let first = name.unicodeScalars.first, ("a"..."z").contains(first), name.unicodeScalars.count <= limit else {
            return false
        }
        return name.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
    }
}

/// How declarations become catalog names and descriptions, the same in every
/// SDK and in the `@ClickManEvents` macro (ClickManMacros/Naming.swift).
enum ClickManNaming {
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

    /// The lines of a description joined with single spaces and trimmed.
    static func description(_ text: String) -> String {
        text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
