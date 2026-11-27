import SwiftDiagnostics
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros

/// `@ClickManEvents`: the cases of an enum as the app's events, with their
/// catalog (docs/PROTOCOL.md, Event catalog). A declaration the catalog
/// cannot take is a compile-time error, and nothing is generated for it.
public struct EventsMacro: ExtensionMacro {
    public static func expansion(
        of node: AttributeSyntax,
        attachedTo declaration: some DeclGroupSyntax,
        providingExtensionsOf type: some TypeSyntaxProtocol,
        conformingTo protocols: [TypeSyntax],
        in context: some MacroExpansionContext
    ) throws -> [ExtensionDeclSyntax] {
        guard let declaration = declaration.as(EnumDeclSyntax.self) else {
            context.diagnose(Diagnostic(node: node, message: CatalogError.notAnEnum))
            return []
        }
        var reader = DeclarationReader()
        let events = reader.events(of: declaration)
        guard reader.diagnostics.isEmpty else {
            reader.diagnostics.forEach(context.diagnose)
            return []
        }
        let source = Generator(type: type.trimmedDescription, conforms: !protocols.isEmpty, events: events).source
        guard let generated = DeclSyntax("\(raw: source)").as(ExtensionDeclSyntax.self) else {
            context.diagnose(Diagnostic(node: node, message: CatalogError.generation))
            return []
        }
        return [generated]
    }
}

/// `@ClickManName`: read by `@ClickManEvents` from the case it marks; it generates nothing itself.
public struct NameMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        if !declaration.is(EnumCaseDeclSyntax.self) {
            context.diagnose(Diagnostic(node: node, message: CatalogError.nameOutsideCase))
        }
        return []
    }
}

/// An event as declared: its case and catalog entry.
struct EventDeclaration {
    let caseName: String
    let name: String
    let description: String
    let properties: [PropertyDeclaration]
}

struct PropertyDeclaration {
    enum Kind {
        case integer
        case number
        case boolean
        case text
        /// A `ClickManValues` enum, spelled as in the declaration.
        case values(String)
    }

    let label: String
    let name: String
    let description: String
    let kind: Kind
    let isRequired: Bool
}

/// Reads the events of an enum and collects every reason the catalog cannot take them.
struct DeclarationReader {
    private(set) var diagnostics: [Diagnostic] = []

    private static let integers: Set<String> = ["Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64"]
    private static let numbers: Set<String> = ["Double", "Float", "Float16", "Float32", "Float64", "Float80", "CGFloat"]
    private static let strings: Set<String> = ["String", "Substring", "Character", "StaticString", "NSString"]
    private static let unsupported: Set<String> = [
        "Date", "URL", "UUID", "Data", "Decimal", "NSNumber", "Array", "Dictionary", "Set", "Optional", "Any", "AnyObject", "AnyHashable",
    ]

    mutating func events(of declaration: EnumDeclSyntax) -> [EventDeclaration] {
        var events: [EventDeclaration] = []
        var names: Set<String> = []
        for member in declaration.memberBlock.members {
            guard let caseDeclaration = member.decl.as(EnumCaseDeclSyntax.self) else {
                continue
            }
            guard caseDeclaration.elements.count == 1, let element = caseDeclaration.elements.first else {
                diagnose(caseDeclaration.elements.dropFirst().first.map(Syntax.init) ?? Syntax(caseDeclaration), .oneEventPerCase)
                continue
            }
            guard let event = event(element, of: caseDeclaration) else {
                continue
            }
            if !names.insert(event.name).inserted {
                diagnose(element.name, .duplicateEvent(event.name))
            }
            events.append(event)
        }
        if events.count > Naming.maxEvents {
            diagnose(declaration.name, .tooManyEvents)
        }
        return events
    }

    private mutating func event(_ element: EnumCaseElementSyntax, of declaration: EnumCaseDeclSyntax) -> EventDeclaration? {
        let caseName = element.name.text.trimmingBackticks
        let override = Override(declaration.attributes)
        if let problem = override.problem {
            diagnose(problem, .invalidOverride)
        }
        let name = override.event ?? Naming.snakeCase(caseName)
        if !Naming.isName(name, limit: Naming.maxEventName) {
            diagnose(override.eventNode ?? Syntax(element.name), .invalidName(name, of: "event `\(caseName)`", limit: Naming.maxEventName))
        } else if Naming.standardEvents.contains(name) {
            diagnose(override.eventNode ?? Syntax(element.name), .standardEvent(name))
        }

        let documentation = DocComment(Self.leadingTrivia(declaration))
        if documentation.description.isEmpty {
            diagnose(element.name, .missingEventDescription(caseName))
        } else if documentation.description.unicodeScalars.count > Naming.maxDescription {
            diagnose(element.name, .longDescription("event `\(caseName)`"))
        } else if Naming.leavesTheLine(documentation.description) {
            diagnose(element.name, .controlCharacter("event `\(caseName)`"))
        }

        var properties: [PropertyDeclaration] = []
        var labels: Set<String> = []
        var propertyNames: Set<String> = []
        for parameter in element.parameterClause?.parameters ?? [] {
            guard let firstName = parameter.firstName, firstName.tokenKind != .wildcard else {
                diagnose(parameter, .unlabeled(caseName))
                continue
            }
            let label = firstName.text.trimmingBackticks
            labels.insert(label)
            let name = override.properties[label] ?? Naming.snakeCase(label)
            if !Naming.isName(name, limit: Naming.maxPropertyName) {
                diagnose(firstName, .invalidName(name, of: "property `\(label)`", limit: Naming.maxPropertyName))
            } else if !propertyNames.insert(name).inserted {
                diagnose(firstName, .duplicateProperty(name, of: caseName))
            }
            let description = documentation.description(of: label) ?? ""
            if description.isEmpty {
                diagnose(firstName, .missingPropertyDescription(label, of: caseName))
            } else if description.unicodeScalars.count > Naming.maxDescription {
                diagnose(firstName, .longDescription("property `\(label)`"))
            } else if Naming.leavesTheLine(description) {
                diagnose(firstName, .controlCharacter("property `\(label)`"))
            }
            guard let (kind, isRequired) = kind(of: parameter.type, label: label) else {
                continue
            }
            properties.append(PropertyDeclaration(label: label, name: name, description: description, kind: kind, isRequired: isRequired))
        }
        for described in documentation.parameters.map(\.name) where !labels.contains(described) {
            diagnose(element.name, .unknownParameter(described, of: caseName))
        }
        for overridden in override.properties.keys.sorted() where !labels.contains(overridden) {
            diagnose(override.propertiesNode ?? Syntax(element.name), .unknownParameter(overridden, of: caseName))
        }
        if properties.count > Naming.maxProperties {
            diagnose(element.name, .tooManyProperties(caseName))
        }
        return EventDeclaration(caseName: caseName, name: name, description: documentation.description, properties: properties)
    }

    /// The catalog type and whether the property is required; nil when the type is not one a catalog takes.
    private mutating func kind(of type: TypeSyntax, label: String) -> (PropertyDeclaration.Kind, Bool)? {
        var isRequired = true
        var wrapped = type
        if let optional = type.as(OptionalTypeSyntax.self) {
            isRequired = false
            wrapped = optional.wrappedType
        } else if let identifier = type.as(IdentifierTypeSyntax.self), identifier.name.text == "Optional",
                  let arguments = identifier.genericArgumentClause?.arguments, arguments.count == 1, let argument = arguments.first {
            isRequired = false
            wrapped = TypeSyntax("\(raw: argument.trimmedDescription)")
        }
        guard let base = Self.baseName(wrapped) else {
            diagnose(type, .unsupportedType(label, type.trimmedDescription))
            return nil
        }
        switch base {
        case _ where Self.integers.contains(base): return (.integer, isRequired)
        case _ where Self.numbers.contains(base): return (.number, isRequired)
        case "Bool": return (.boolean, isRequired)
        case "ClickManText": return (.text, isRequired)
        case _ where Self.strings.contains(base):
            diagnose(type, .undeclaredText(label))
            return nil
        case _ where Self.unsupported.contains(base):
            diagnose(type, .unsupportedType(label, type.trimmedDescription))
            return nil
        default:
            return (.values(wrapped.trimmedDescription), isRequired)
        }
    }

    /// The name of a plain or qualified type without generic arguments, e.g. `Format` of `Outer.Format`.
    private static func baseName(_ type: TypeSyntax) -> String? {
        if let identifier = type.as(IdentifierTypeSyntax.self), identifier.genericArgumentClause == nil {
            return identifier.name.text.trimmingBackticks
        }
        if let member = type.as(MemberTypeSyntax.self), member.genericArgumentClause == nil {
            return member.name.text.trimmingBackticks
        }
        return nil
    }

    /// The trivia before the `case` keyword, where its doc comment is, attributes included.
    private static func leadingTrivia(_ declaration: EnumCaseDeclSyntax) -> [TriviaPiece] {
        var pieces: [TriviaPiece] = []
        for token in declaration.tokens(viewMode: .sourceAccurate) {
            pieces.append(contentsOf: token.leadingTrivia)
            if token.id == declaration.caseKeyword.id {
                break
            }
        }
        return pieces
    }

    private mutating func diagnose(_ node: some SyntaxProtocol, _ error: CatalogError) {
        diagnostics.append(Diagnostic(node: node, message: error))
    }
}

/// The names `@ClickManName` gives an event and its properties.
private struct Override {
    var event: String?
    var eventNode: Syntax?
    var properties: [String: String] = [:]
    var propertiesNode: Syntax?
    /// An argument that is not a string literal or a dictionary of them.
    var problem: Syntax?

    init(_ attributes: AttributeListSyntax) {
        for case .attribute(let attribute) in attributes {
            let name = attribute.attributeName.trimmedDescription
            guard name == "ClickManName" || name.hasSuffix(".ClickManName") else {
                continue
            }
            guard case .argumentList(let arguments)? = attribute.arguments else {
                continue
            }
            for argument in arguments {
                switch argument.label?.text {
                case nil:
                    if argument.expression.is(NilLiteralExprSyntax.self) {
                        continue
                    }
                    guard let value = Self.string(argument.expression) else {
                        problem = Syntax(argument)
                        continue
                    }
                    event = value
                    eventNode = Syntax(argument)
                case "properties":
                    propertiesNode = Syntax(argument)
                    guard let dictionary = argument.expression.as(DictionaryExprSyntax.self) else {
                        problem = Syntax(argument)
                        continue
                    }
                    guard case .elements(let elements) = dictionary.content else {
                        continue
                    }
                    for element in elements {
                        guard let key = Self.string(element.key), let value = Self.string(element.value) else {
                            problem = Syntax(element)
                            continue
                        }
                        properties[key] = value
                    }
                default:
                    problem = Syntax(argument)
                }
            }
        }
    }

    private static func string(_ expression: ExprSyntax) -> String? {
        expression.as(StringLiteralExprSyntax.self)?.representedLiteralValue
    }
}

/// The source of the `ClickManEvent` extension.
private struct Generator {
    let type: String
    let conforms: Bool
    let events: [EventDeclaration]

    var source: String {
        """
        extension \(type)\(conforms ? ": ClickManEvent" : "") {
            public var name: String {
                switch self {
        \(events.map(nameCase).joined(separator: "\n"))
                }
            }

            public var properties: [String: ClickManPropertyValue] {
                switch self {
        \(events.map(propertiesCase).joined(separator: "\n"))
                }
            }

            public static var catalog: ClickManCatalog {
                ClickManCatalog(events: [
        \(events.map(catalogEvent).joined(separator: "\n"))
                ])
            }
        }
        """
    }

    private func nameCase(_ event: EventDeclaration) -> String {
        """
                case .\(identifier(event.caseName)):
                    return \(Naming.literal(event.name))
        """
    }

    private func propertiesCase(_ event: EventDeclaration) -> String {
        guard !event.properties.isEmpty else {
            return """
                    case .\(identifier(event.caseName)):
                        return [:]
            """
        }
        let bindings = event.properties.enumerated().map { "\($1.label): value\($0)" }.joined(separator: ", ")
        let assignments = event.properties.enumerated().map { index, property in
            let value = "\(constructor(property.kind))(value\(index))"
            guard property.isRequired else {
                return """
                            if let value\(index) {
                                result[\(Naming.literal(property.name))] = \(constructor(property.kind))(value\(index))
                            }
                """
            }
            return "            result[\(Naming.literal(property.name))] = \(value)"
        }
        return """
                case let .\(identifier(event.caseName))(\(bindings)):
                    var result: [String: ClickManPropertyValue] = [:]
        \(assignments.joined(separator: "\n"))
                    return result
        """
    }

    private func catalogEvent(_ event: EventDeclaration) -> String {
        let properties = event.properties.map { property in
            let name = Naming.literal(property.name)
            let description = Naming.literal(property.description)
            let required = property.isRequired ? "true" : "false"
            switch property.kind {
            case .integer: return "                    .integer(\(name), description: \(description), required: \(required)),"
            case .number: return "                    .number(\(name), description: \(description), required: \(required)),"
            case .boolean: return "                    .boolean(\(name), description: \(description), required: \(required)),"
            case .text: return "                    .text(\(name), description: \(description), required: \(required)),"
            case .values(let type):
                return "                    .values(\(name), description: \(description), of: \(type).self, required: \(required)),"
            }
        }
        return """
                    ClickManCatalog.Event(
                        name: \(Naming.literal(event.name)),
                        description: \(Naming.literal(event.description)),
                        properties: [\(properties.isEmpty ? "" : "\n" + properties.joined(separator: "\n") + "\n                ")]
                    ),
        """
    }

    private func constructor(_ kind: PropertyDeclaration.Kind) -> String {
        switch kind {
        case .integer: "ClickManPropertyValue.integer"
        case .number: "ClickManPropertyValue.number"
        case .boolean: "ClickManPropertyValue.boolean"
        case .text: "ClickManPropertyValue.text"
        case .values: "ClickManPropertyValue.value"
        }
    }

    /// A case name as an expression, escaped when it is a keyword.
    private func identifier(_ name: String) -> String {
        Self.keywords.contains(name) ? "`\(name)`" : name
    }

    private static let keywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "func", "import", "init", "inout", "let", "operator",
        "protocol", "static", "struct", "subscript", "typealias", "var", "break", "case", "continue", "default", "defer",
        "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "switch", "where", "while", "as",
        "catch", "false", "is", "nil", "rethrows", "super", "self", "Self", "throw", "throws", "true", "try",
    ]
}

/// Why a declaration cannot be a catalog event; every one is a compile-time error.
enum CatalogError: DiagnosticMessage {
    case notAnEnum
    case generation
    case nameOutsideCase
    case oneEventPerCase
    case invalidOverride
    case tooManyEvents
    case tooManyProperties(String)
    case invalidName(String, of: String, limit: Int)
    case standardEvent(String)
    case duplicateEvent(String)
    case duplicateProperty(String, of: String)
    case missingEventDescription(String)
    case missingPropertyDescription(String, of: String)
    case longDescription(String)
    case controlCharacter(String)
    case unknownParameter(String, of: String)
    case unlabeled(String)
    case undeclaredText(String)
    case unsupportedType(String, String)

    var message: String {
        switch self {
        case .notAnEnum:
            "@ClickManEvents declares events as the cases of an enum"
        case .generation:
            "@ClickManEvents could not generate the event conformance"
        case .nameOutsideCase:
            "@ClickManName names a case of a @ClickManEvents enum"
        case .oneEventPerCase:
            "declare each event in a case of its own, so that each has its own description"
        case .invalidOverride:
            "@ClickManName takes a string literal and `properties:` as a dictionary literal of string literals"
        case .tooManyEvents:
            "a catalog declares at most \(Naming.maxEvents) events"
        case .tooManyProperties(let event):
            "event `\(event)` declares more than \(Naming.maxProperties) properties"
        case .invalidName(let name, let what, let limit):
            "\(what) is named `\(name)`, which is not a catalog name: snake case, ^[a-z][a-z0-9_]*$, at most \(limit) characters"
        case .standardEvent(let name):
            "`\(name)` is a standard event the SDK records itself; an app cannot declare it"
        case .duplicateEvent(let name):
            "another event is already named `\(name)`"
        case .duplicateProperty(let name, let event):
            "event `\(event)` already has a property named `\(name)`"
        case .missingEventDescription(let event):
            "event `\(event)` needs a description: write what it means in a `///` doc comment on the case"
        case .missingPropertyDescription(let property, let event):
            "property `\(property)` of event `\(event)` needs a description: add `- Parameter \(property):` to the doc comment of the case"
        case .longDescription(let what):
            "the description of \(what) is longer than \(Naming.maxDescription) characters"
        case .controlCharacter(let what):
            "the description of \(what) is one line without control characters such as tabs"
        case .unknownParameter(let name, let event):
            "event `\(event)` has no property `\(name)`"
        case .unlabeled(let event):
            "every associated value of event `\(event)` needs a label: the label names the property"
        case .undeclaredText(let property):
            "property `\(property)` is a String, which can carry personal data: declare it `ClickManText` for free text, or a `ClickManValues` enum of the strings it takes"
        case .unsupportedType(let property, let type):
            "property `\(property)` is a `\(type)`; a catalog property is an integer, a floating-point number, Bool, ClickManText or a ClickManValues enum, optional when it may be absent"
        }
    }

    var diagnosticID: MessageID {
        MessageID(domain: "ClickManMacros", id: String(describing: self).prefix { $0 != "(" }.description)
    }

    var severity: DiagnosticSeverity {
        .error
    }
}
