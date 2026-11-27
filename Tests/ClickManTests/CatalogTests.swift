import ClickManEvents
import Foundation
import XCTest
@testable import ClickMan

/// The reference events of protocol/fixtures/catalog.json, declared as an app would.
@ClickManEvents
enum ReferenceEvent {
    enum Format: String, ClickManValues {
        case wav
        case flac
    }

    enum Mode: String, ClickManValues {
        case fullMix
        case perTrack
    }

    /// Export wrote every file
    /// and they are ready to use.
    ///
    /// - Parameters:
    ///   - format: File format of the export.
    ///   - mode:   Whether one mix or one file per track was written.  
    ///   - tracks: How many tracks the export contains.
    ///   - durationSeconds: Length of the exported audio in seconds.
    ///   - normalized: Whether loudness normalization was applied.
    ///   - title: Title the user gave the export.
    case exportCompleted(
        format: Format,
        mode: Mode,
        tracks: UInt,
        durationSeconds: Double? = nil,
        normalized: Bool? = nil,
        title: ClickManText? = nil
    )

    /// A new empty project was created.
    case projectCreated
}

/// Overrides, block comments, single parameter entries and values that choose themselves.
@ClickManEvents
enum OverriddenEvent {
    enum Quality: Int, ClickManValues {
        case low
        case high

        var clickManValue: String {
            switch self {
            case .low: "lo-fi"
            case .high: "hi-fi"
            }
        }
    }

    /**
     * Export finished
     *   after `retries` attempts.
     *
     * - Parameter durationSeconds: Length of the export
     *   in seconds.
     * - Parameter quality: Quality the user chose.
     * - Note: This is not part of any description.
     */
    @ClickManName("export_done", properties: ["durationSeconds": "duration"])
    case exportCompleted(durationSeconds: Float, quality: Quality?)

    /// The HTTP status of an upload arrived.
    /// - Parameter HTTPStatus: Status code of the response.
    /// - Parameter isRetry: Whether the upload was a retry.
    case uploadAnswered(HTTPStatus: Int64, isRetry: Optional<Bool>)
}

final class CatalogTests: StoreTestCase {
    private static let fixture: JSONValue = {
        let url = (0..<3)
            .reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
            .appending(path: "protocol/fixtures/catalog.json")
        do {
            return try JSONValue(JSONSerialization.jsonObject(with: Data(contentsOf: url)))
        } catch {
            fatalError("catalog.json cannot be read: \(error)")
        }
    }()

    private static var samples: [JSONValue] {
        fixture["samples"]?.array ?? []
    }

    func testTheReferenceDeclarationsExportTheFixtureCatalog() throws {
        let expected = try XCTUnwrap(Self.fixture["catalog"])

        XCTAssertEqual(try JSONValue(JSONSerialization.jsonObject(with: ReferenceEvent.catalog.json)), expected)
        XCTAssertEqual(try JSONValue(JSONSerialization.jsonObject(with: Data(ReferenceEvent.catalog.jsonString.utf8))), expected)
    }

    func testEverySampleTracksExactlyItsNameAndProperties() throws {
        XCTAssertFalse(Self.samples.isEmpty)
        for sample in Self.samples {
            let name = try XCTUnwrap(sample["name"]?.string)
            let event = try referenceEvent(XCTUnwrap(sample["value"], name))
            XCTAssertEqual(event.name, sample["event"]?.string, name)
            XCTAssertEqual(JSONValue.object(event.properties.mapValues(\.json)), sample["properties"], name)
        }
    }

    func testTrackedSamplesAreSentWithExactlyTheirProperties() async throws {
        var configuration = ClickMan.Configuration.test(storage: storage)
        configuration.tracksLifecycle = false
        let clickMan = try ClickMan(configuration: configuration)
        for sample in Self.samples {
            clickMan.track(try referenceEvent(XCTUnwrap(sample["value"])))
        }
        await clickMan.flush()

        let events = try StubServer.events()
        XCTAssertEqual(events.map { $0["event"] }, Self.samples.map { $0["event"] })
        XCTAssertEqual(events.map { $0["properties"] }, Self.samples.map { $0["properties"] })
    }

    func testOverridesBlockCommentsAndChosenValues() throws {
        let catalog = try JSONValue(JSONSerialization.jsonObject(with: OverriddenEvent.catalog.json))
        let expected: JSONValue = .object([
            "version": .integer(1),
            "events": .array([
                .object([
                    "name": .string("export_done"),
                    "description": .string("Export finished after `retries` attempts."),
                    "properties": .array([
                        .object([
                            "name": .string("duration"), "description": .string("Length of the export in seconds."),
                            "type": .string("number"), "required": .bool(true),
                        ]),
                        .object([
                            "name": .string("quality"), "description": .string("Quality the user chose."),
                            "type": .string("string"), "values": .array([.string("lo-fi"), .string("hi-fi")]), "required": .bool(false),
                        ]),
                    ]),
                ]),
                .object([
                    "name": .string("upload_answered"),
                    "description": .string("The HTTP status of an upload arrived."),
                    "properties": .array([
                        .object([
                            "name": .string("http_status"), "description": .string("Status code of the response."),
                            "type": .string("integer"), "required": .bool(true),
                        ]),
                        .object([
                            "name": .string("is_retry"), "description": .string("Whether the upload was a retry."),
                            "type": .string("boolean"), "required": .bool(false),
                        ]),
                    ]),
                ]),
            ]),
        ])
        XCTAssertEqual(catalog, expected)

        let export = OverriddenEvent.exportCompleted(durationSeconds: 1.5, quality: .high)
        XCTAssertEqual(export.name, "export_done")
        XCTAssertEqual(export.properties, ["duration": .number(1.5), "quality": .value(OverriddenEvent.Quality.high)])
        XCTAssertEqual(OverriddenEvent.exportCompleted(durationSeconds: 2, quality: nil).properties, ["duration": .number(2)])
        XCTAssertEqual(OverriddenEvent.uploadAnswered(HTTPStatus: 503, isRetry: false).properties["is_retry"], .boolean(false))
    }

    func testTheJSONKeepsTheCatalogOrderAndEscapesText() {
        let catalog = ClickManCatalog(events: [
            .init(name: "a", description: "Says \"hi\" \\ there.", properties: [
                .values("b", description: "B.", of: ReferenceEvent.Format.self, required: true),
                .text("c", description: "C\u{1}.", required: false),
            ]),
            .init(name: "d", description: "D."),
        ])

        XCTAssertEqual(catalog.jsonString, """
        {
          "version": 1,
          "events": [
            {
              "name": "a",
              "description": "Says \\"hi\\" \\\\ there.",
              "properties": [
                { "name": "b", "description": "B.", "type": "string", "values": ["wav", "flac"], "required": true },
                { "name": "c", "description": "C\\u0001.", "type": "string", "text": true, "required": false }
              ]
            },
            {
              "name": "d",
              "description": "D.",
              "properties": []
            }
          ]
        }

        """)
        XCTAssertEqual(ClickManCatalog(events: []).jsonString, "{\n  \"version\": 1,\n  \"events\": []\n}\n")
    }

    func testDeclaredCatalogsAreValid() throws {
        try ReferenceEvent.catalog.validate()
        try OverriddenEvent.catalog.validate()
    }

    /// The fixture's refusals that a `ClickManCatalog` can hold are found with
    /// the server's reason; the rest (another version, an unknown type, a
    /// missing field) cannot be expressed by the type at all.
    func testEveryInvalidFixtureCatalogIsRefusedWithItsReason() throws {
        let cases = try XCTUnwrap(Self.fixture["invalid"]?.array)
        XCTAssertFalse(cases.isEmpty)
        var checked = 0
        for scenario in cases {
            let name = try XCTUnwrap(scenario["name"]?.string)
            let reason = try XCTUnwrap(scenario["reason"]?.string)
            guard let catalog = Self.catalog(try XCTUnwrap(scenario["catalog"])) else {
                XCTAssertTrue(["unsupported_version", "invalid_type", "malformed_catalog"].contains(reason), "\(name) is a catalog")
                continue
            }
            XCTAssertThrowsError(try catalog.validate(), name) { error in
                XCTAssertEqual((error as? ClickManCatalog.Problem)?.reason, reason, name)
            }
            checked += 1
        }
        XCTAssertEqual(checked, cases.count - 3)
    }

    func testValuesThatRepeatInSnakeCaseAreRefused() {
        enum Repeated: String, ClickManValues {
            case fullMix
            case full_mix
        }
        let catalog = ClickManCatalog(events: [
            .init(name: "a", description: "A.", properties: [.values("b", description: "B.", of: Repeated.self, required: true)]),
        ])

        XCTAssertThrowsError(try catalog.validate()) { error in
            XCTAssertEqual((error as? ClickManCatalog.Problem)?.reason, "invalid_values")
        }
    }

    func testTheStandardEventsAreTheProtocols() throws {
        let url = (0..<3)
            .reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
            .appending(path: "protocol/standard-events.json")
        let standard = try JSONValue(JSONSerialization.jsonObject(with: Data(contentsOf: url)))
        let names = try XCTUnwrap(standard["events"]?.array).compactMap { $0["name"]?.string }

        XCTAssertEqual(Set(names), ClickManCatalog.standardEvents)
    }

    func testCatalogsCombineInOrder() {
        let combined = ClickManCatalog(ReferenceEvent.catalog, OverriddenEvent.catalog)

        XCTAssertEqual(combined.events.map(\.name), ["export_completed", "project_created", "export_done", "upload_answered"])
    }

    func testNamesBecomeSnakeCase() {
        let names = [
            "ExportCompleted": "export_completed", "exportCompleted": "export_completed", "EXPORT_COMPLETED": "export_completed",
            "perTrack": "per_track", "fullMix": "full_mix", "durationSeconds": "duration_seconds", "HTTPStatus": "http_status",
            "mp3Export": "mp3_export", "export2": "export2", "Export Completed": "export_completed", "a": "a",
        ]
        for (declared, expected) in names {
            XCTAssertEqual(ClickManNaming.snakeCase(declared), expected, declared)
        }
    }

    func testIntegersKeepTheirExactValue() {
        XCTAssertEqual(ClickManPropertyValue.integer(UInt64.max).json, .unsigned(UInt64.max))
        XCTAssertEqual(ClickManPropertyValue.integer(Int8.min).json, .integer(-128))
        XCTAssertEqual(ClickManPropertyValue.number(Float(0.5)).json, .number(0.5))
    }

    func testHandWrittenDescriptionsAreJoinedAndTrimmed() {
        let event = ClickManCatalog.Event(name: "a", description: "  One\n  two.  \n", properties: [.boolean("b", description: "\tB.\n", required: true)])

        XCTAssertEqual(event.description, "One two.")
        XCTAssertEqual(event.properties.first?.description, "B.")
    }

    private func referenceEvent(_ value: JSONValue) throws -> ReferenceEvent {
        switch value["event"]?.string {
        case "ExportCompleted":
            return .exportCompleted(
                format: try XCTUnwrap(value["format"]?.string.flatMap(ReferenceEvent.Format.init(rawValue:))),
                mode: try XCTUnwrap(value["mode"]?.string.flatMap(ReferenceEvent.Mode.init(rawValue:))),
                tracks: try XCTUnwrap(Self.unsigned(value["tracks"])),
                durationSeconds: Self.double(value["durationSeconds"]),
                normalized: Self.bool(value["normalized"]),
                title: value["title"]?.string
            )
        case "ProjectCreated":
            return .projectCreated
        case let other:
            throw JSONValue.NotJSON(description: "no reference event \(other ?? "(none)")")
        }
    }

    /// A catalog as the JSON gives it, descriptions verbatim; nil when the type cannot hold it.
    private static func catalog(_ json: JSONValue) -> ClickManCatalog? {
        guard json["version"] == .integer(1), let events = json["events"]?.array else {
            return nil
        }
        var catalog = ClickManCatalog(events: [])
        for event in events {
            guard let name = event["name"]?.string, let description = event["description"]?.string,
                  let properties = event["properties"]?.array else {
                return nil
            }
            var declared = ClickManCatalog.Event(name: name, description: "")
            declared.description = description
            for property in properties {
                guard let name = property["name"]?.string, let description = property["description"]?.string,
                      let type = property["type"]?.string.flatMap(ClickManCatalog.Property.Kind.init(rawValue:)),
                      let isRequired = bool(property["required"]) else {
                    return nil
                }
                var value = ClickManCatalog.Property(
                    name: name, description: "", type: type, values: property["values"]?.array?.compactMap(\.string),
                    isText: bool(property["text"]) ?? false, isRequired: isRequired
                )
                value.description = description
                declared.properties.append(value)
            }
            catalog.events.append(declared)
        }
        return catalog
    }

    private static func unsigned(_ value: JSONValue?) -> UInt? {
        guard case .integer(let integer)? = value else { return nil }
        return UInt(exactly: integer)
    }

    private static func double(_ value: JSONValue?) -> Double? {
        switch value {
        case .number(let number)?: number
        case .integer(let integer)?: Double(integer)
        default: nil
        }
    }

    private static func bool(_ value: JSONValue?) -> Bool? {
        guard case .bool(let bool)? = value else { return nil }
        return bool
    }
}
