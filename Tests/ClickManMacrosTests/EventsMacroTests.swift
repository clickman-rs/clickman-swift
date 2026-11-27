import Foundation
@testable import ClickManMacros
import SwiftSyntaxBuilder
import SwiftSyntaxMacroExpansion
import SwiftSyntaxMacros
import SwiftSyntaxMacrosTestSupport
import XCTest

/// The compile-time refusals of `@ClickManEvents`: a declaration the catalog
/// cannot take is an error at its source, and nothing is generated for it.
final class EventsMacroTests: XCTestCase {
    private let macros: [String: Macro.Type] = ["ClickManEvents": EventsMacro.self, "ClickManName": NameMacro.self]

    private func assertRefused(
        _ source: String, _ expanded: String, _ diagnostics: [DiagnosticSpec], file: StaticString = #filePath, line: UInt = #line
    ) {
        assertMacroExpansion(source, expandedSource: expanded, diagnostics: diagnostics, macros: macros, file: file, line: line)
    }

    func testAnEnumExpandsToItsEventsAndCatalog() {
        assertMacroExpansion(
            """
            @ClickManEvents
            enum AppEvent {
                /// Export wrote every file
                /// and they are ready to use.
                ///
                /// - Parameters:
                ///   - format: File format of the export.
                ///   - title: Title the user gave the export.
                case exportCompleted(format: Format, title: ClickManText? = nil)

                /// A new empty project was created.
                case projectCreated
            }
            """,
            expandedSource: """
            enum AppEvent {
                /// Export wrote every file
                /// and they are ready to use.
                ///
                /// - Parameters:
                ///   - format: File format of the export.
                ///   - title: Title the user gave the export.
                case exportCompleted(format: Format, title: ClickManText? = nil)

                /// A new empty project was created.
                case projectCreated
            }

            extension AppEvent: ClickManEvent {
                public var name: String {
                    switch self {
                    case .exportCompleted:
                        return "export_completed"
                    case .projectCreated:
                        return "project_created"
                    }
                }

                public var properties: [String: ClickManPropertyValue] {
                    switch self {
                    case let .exportCompleted(format: value0, title: value1):
                        var result: [String: ClickManPropertyValue] = [:]
                        result["format"] = ClickManPropertyValue.value(value0)
                        if let value1 {
                            result["title"] = ClickManPropertyValue.text(value1)
                        }
                        return result
                    case .projectCreated:
                        return [:]
                    }
                }

                public static var catalog: ClickManCatalog {
                    ClickManCatalog(events: [
                        ClickManCatalog.Event(
                            name: "export_completed",
                            description: "Export wrote every file and they are ready to use.",
                            properties: [
                                .values("format", description: "File format of the export.", of: Format.self, required: true),
                                .text("title", description: "Title the user gave the export.", required: false),
                            ]
                        ),
                        ClickManCatalog.Event(
                            name: "project_created",
                            description: "A new empty project was created.",
                            properties: []
                        ),
                    ])
                }
            }
            """,
            macroSpecs: ["ClickManEvents": MacroSpec(type: EventsMacro.self, conformances: ["ClickManEvent"])]
        )
    }

    func testAnEventWithoutADescriptionIsRefused() {
        assertRefused(
            """
            @ClickManEvents
            enum AppEvent {
                case projectCreated
            }
            """,
            """
            enum AppEvent {
                case projectCreated
            }
            """,
            [DiagnosticSpec(message: "event `projectCreated` needs a description: write what it means in a `///` doc comment on the case", line: 3, column: 10)]
        )
    }

    func testADescriptionWithAControlCharacterIsRefused() {
        assertRefused(
            """
            @ClickManEvents
            enum AppEvent {
                /// A new\tproject was created.
                case projectCreated
            }
            """,
            """
            enum AppEvent {
                /// A new\tproject was created.
                case projectCreated
            }
            """,
            [DiagnosticSpec(message: "the description of event `projectCreated` is one line without control characters such as tabs", line: 4, column: 10)]
        )
    }

    func testAPropertyWithoutADescriptionIsRefused() {
        assertRefused(
            """
            @ClickManEvents
            enum AppEvent {
                /// Export wrote every file.
                /// - Parameter format: File format.
                case exportCompleted(format: Format, tracks: Int)
            }
            """,
            """
            enum AppEvent {
                /// Export wrote every file.
                /// - Parameter format: File format.
                case exportCompleted(format: Format, tracks: Int)
            }
            """,
            [
                DiagnosticSpec(
                    message: "property `tracks` of event `exportCompleted` needs a description: add `- Parameter tracks:` to the doc comment of the case",
                    line: 5, column: 42
                ),
            ]
        )
    }

    func testAStringNotDeclaredAsFreeTextIsRefused() {
        assertRefused(
            """
            @ClickManEvents
            enum AppEvent {
                /// Export wrote every file.
                /// - Parameter title: Title the user gave the export.
                case exportCompleted(title: String?)
            }
            """,
            """
            enum AppEvent {
                /// Export wrote every file.
                /// - Parameter title: Title the user gave the export.
                case exportCompleted(title: String?)
            }
            """,
            [
                DiagnosticSpec(
                    message: "property `title` is a String, which can carry personal data: declare it `ClickManText` for free text, or a `ClickManValues` enum of the strings it takes",
                    line: 5, column: 33
                ),
            ]
        )
    }

    func testAnUnsupportedTypeIsRefused() {
        assertRefused(
            """
            @ClickManEvents
            enum AppEvent {
                /// Export wrote every file.
                /// - Parameter files: The files.
                case exportCompleted(files: [Int])
            }
            """,
            """
            enum AppEvent {
                /// Export wrote every file.
                /// - Parameter files: The files.
                case exportCompleted(files: [Int])
            }
            """,
            [
                DiagnosticSpec(
                    message: "property `files` is a `[Int]`; a catalog property is an integer, a floating-point number, Bool, ClickManText or a ClickManValues enum, optional when it may be absent",
                    line: 5, column: 33
                ),
            ]
        )
    }

    func testAStandardEventAnUnknownParameterAndARepeatedNameAreRefused() {
        assertRefused(
            """
            @ClickManEvents
            enum AppEvent {
                /// The app opened.
                case appOpened
                /// Export wrote every file.
                /// - Parameter titel: A misspelled property.
                case exportCompleted
                /// Export wrote every file again.
                @ClickManName("export_completed")
                case exportRepeated
            }
            """,
            """
            enum AppEvent {
                /// The app opened.
                case appOpened
                /// Export wrote every file.
                /// - Parameter titel: A misspelled property.
                case exportCompleted
                /// Export wrote every file again.
                case exportRepeated
            }
            """,
            [
                DiagnosticSpec(message: "`app_opened` is a standard event the SDK records itself; an app cannot declare it", line: 4, column: 10),
                DiagnosticSpec(message: "event `exportCompleted` has no property `titel`", line: 7, column: 10),
                DiagnosticSpec(message: "another event is already named `export_completed`", line: 10, column: 10),
            ]
        )
    }

    func testANameThatIsNotSnakeCaseAndAnUnlabeledValueAreRefused() {
        assertRefused(
            """
            @ClickManEvents
            enum AppEvent {
                /// Export wrote every file.
                @ClickManName("Export-Done")
                case exportCompleted(Int)
            }
            """,
            """
            enum AppEvent {
                /// Export wrote every file.
                case exportCompleted(Int)
            }
            """,
            [
                DiagnosticSpec(
                    message: "event `exportCompleted` is named `Export-Done`, which is not a catalog name: snake case, ^[a-z][a-z0-9_]*$, at most 200 characters",
                    line: 4, column: 19
                ),
                DiagnosticSpec(message: "every associated value of event `exportCompleted` needs a label: the label names the property", line: 5, column: 26),
            ]
        )
    }

    func testTheStandardEventsAreTheProtocols() throws {
        let url = (0..<3)
            .reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
            .appending(path: "protocol/standard-events.json")
        let standard = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let names = try XCTUnwrap(standard["events"] as? [[String: Any]]).compactMap { $0["name"] as? String }

        XCTAssertEqual(Set(names), Naming.standardEvents)
    }

    func testNamesBecomeSnakeCaseAsInTheRuntime() {
        let names = [
            "ExportCompleted": "export_completed", "exportCompleted": "export_completed", "EXPORT_COMPLETED": "export_completed",
            "perTrack": "per_track", "HTTPStatus": "http_status", "mp3Export": "mp3_export", "`default`": "default",
        ]
        for (declared, expected) in names {
            XCTAssertEqual(Naming.snakeCase(declared), expected, declared)
        }
    }

    func testOnlyAnEnumDeclaresEvents() {
        assertRefused(
            """
            @ClickManEvents
            struct AppEvent {}
            """,
            """
            struct AppEvent {}
            """,
            [DiagnosticSpec(message: "@ClickManEvents declares events as the cases of an enum", line: 1, column: 1)]
        )
    }
}
