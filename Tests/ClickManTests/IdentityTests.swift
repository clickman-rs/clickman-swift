import Foundation
import XCTest
@testable import ClickMan

/// Visitors and links: every case of protocol/fixtures/identity.json — its
/// `cases`, `takes`, `request` and `outcomes` — against this client.
final class IdentityTests: StoreTestCase {
    private static var visitor: Regex<Substring> { #/anon:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}/# }
    private static let link = Link(anonymousId: "anon:01926a2e-7b1c-4c3d-9f2e-5b1a2c3d4e5f", externalId: "user_42")

    private let clock = TestClock()

    /// The whole of identity.json, for its parts beside `cases`.
    private func fixture() throws -> JSONValue {
        let url = (0..<3)
            .reduce(URL(fileURLWithPath: #filePath)) { url, _ in url.deletingLastPathComponent() }
            .appending(path: "protocol/fixtures/identity.json")
        return try JSONValue(JSONSerialization.jsonObject(with: Data(contentsOf: url)))
    }

    /// A store of its own named `name` in the test's directory, and its tracker.
    private func store(_ name: String, maxQueue: Int = 10_000) throws -> (queue: Queue, tracker: Tracker) {
        let queue = try Queue(path: storage.deletingLastPathComponent().appending(path: "\(name).sqlite"), maxQueue: maxQueue)
        return (queue, Tracker(queue: queue, bundle: .main, clock: clock.reading, logger: ClickMan.logger))
    }

    private func sender(_ queue: Queue, endpoint: String = "https://ingest.test") throws -> Sender {
        var configuration = ClickMan.Configuration.test(storage: storage)
        configuration.endpoint = try XCTUnwrap(URL(string: endpoint))
        return try Sender(queue: queue, configuration: configuration, clock: clock.reading, logger: ClickMan.logger)
    }

    private struct Snapshot: Equatable {
        let identity: Identity
        let rows: [QueuedEvent]
    }

    private func snapshot(_ queue: Queue) throws -> Snapshot {
        Snapshot(identity: try queue.write { try $0.identity() }, rows: try queue.oldest(1_000))
    }

    /// A queued row of `kind`, `track` or `link`.
    private func body(_ kind: String) throws -> String {
        kind == "link"
            ? try Self.link.body()
            : try Event(name: "a", properties: [:]).body(identity: Identity(externalId: "*", traits: [:], lastLaunch: nil), context: [:], at: clock.now)
    }

    /// What each request carried: `link` for a link, `track` per event of a batch.
    private func sentKinds() throws -> [[String]] {
        try StubServer.requests.map { request in
            request.url.path.hasSuffix("/v1/identify") ? ["link"] : try events(request).map { _ in "track" }
        }
    }

    private func events(_ request: StubServer.Request) throws -> [JSONValue] {
        try XCTUnwrap(JSONValue(JSONSerialization.jsonObject(with: gunzip(request.body)))["batch"]?.array)
    }

    private func integer(_ value: JSONValue?) throws -> Int {
        guard case .integer(let integer)? = value else {
            throw JSONValue.NotJSON(description: "\(String(describing: value)) is not an integer")
        }
        return Int(integer)
    }

    // MARK: identity.json

    func testEveryCase() throws {
        for (index, scenario) in try Fixture.cases("identity.json").enumerated() {
            let name = try XCTUnwrap(scenario["name"]?.string)
            let (queue, tracker) = try store("case-\(index)")
            var visitors: [String] = []
            for step in try XCTUnwrap(scenario["steps"]?.array, name) {
                let before = try snapshot(queue)
                let refused = step["error"] == .bool(true)
                if step["identifyInstallation"] == .bool(true) {
                    tracker.identifyInstallation()
                } else if let event = step["track"]?.string {
                    tracker.track(Event(name: event, properties: [:]))
                } else if let externalId = step["identify"]?.string {
                    XCTAssertEqual(tracker.identify(externalId), !refused, "\(name): identify \(externalId)")
                } else if step["reset"] == .bool(true) {
                    tracker.reset()
                } else {
                    XCTFail("\(name): an unknown step \(step)")
                }
                if refused {
                    XCTAssertEqual(try snapshot(queue), before, "\(name): a refused step changed the store")
                }
                let actor = try snapshot(queue).identity.externalId
                if Identity.isVisitor(actor), !visitors.contains(actor) {
                    XCTAssertNotNil(actor.wholeMatch(of: Self.visitor), "\(name): \(actor) is not anon:<UUIDv4>")
                    visitors.append(actor)
                }
            }

            func named(_ externalId: String?) -> JSONValue {
                guard let externalId else { return .null }
                return .string(visitors.firstIndex(of: externalId).map { "visitor \($0 + 1)" } ?? externalId)
            }
            let after = try snapshot(queue)
            XCTAssertEqual(named(after.identity.externalId), scenario["actor"], name)
            let rows = try after.rows.map { row -> JSONValue in
                let body = try JSONValue.object(parsing: row.body)
                guard let link = Link(body: row.body) else {
                    return .object(["track": body["event"] ?? .null, "externalId": named(body["externalId"]?.string)])
                }
                XCTAssertEqual(Set(body.keys), ["type", "anonymousId", "externalId"], name)
                return .object(["link": .object(["anonymousId": named(link.anonymousId), "externalId": named(link.externalId)])])
            }
            XCTAssertEqual(JSONValue.array(rows), scenario["queue"], name)
        }
    }

    func testEveryTake() throws {
        let cases = try XCTUnwrap(fixture()["takes"]?["cases"]?.array)
        XCTAssertFalse(cases.isEmpty)
        for scenario in cases {
            let name = try XCTUnwrap(scenario["name"]?.string)
            let kinds = try XCTUnwrap(scenario["rows"]?.array).compactMap(\.string)
            var rows = try kinds.enumerated().map { QueuedEvent(seq: Int64($0.offset + 1), body: try body($0.element)) }
            var taken: [JSONValue] = []
            while let take = Take(taking: rows) {
                XCTAssertEqual(take.lastSeq, rows[take.count - 1].seq, name)
                taken.append(.array(rows.prefix(take.count).map { .string(kinds[Int($0.seq) - 1]) }))
                rows.removeFirst(take.count)
            }
            XCTAssertEqual(JSONValue.array(taken), scenario["taken"], name)
        }
    }

    func testEveryTakeIsSentAsItsOwnRequest() async throws {
        for (index, scenario) in try XCTUnwrap(fixture()["takes"]?["cases"]?.array).enumerated() {
            let name = try XCTUnwrap(scenario["name"]?.string)
            StubServer.reset()
            let queue = try store("takes-\(index)").queue
            let bodies = try XCTUnwrap(scenario["rows"]?.array).compactMap(\.string).map(body)
            let date = clock.now
            try queue.write { transaction in
                for body in bodies {
                    try transaction.append(body, createdAt: date)
                }
            }
            try await sender(queue).drain(.everything)

            let expected = try XCTUnwrap(scenario["taken"]?.array).map { try XCTUnwrap($0.array).compactMap(\.string) }
            XCTAssertEqual(try sentKinds(), expected, name)
            XCTAssertEqual(try queue.count(), 0, name)
        }
    }

    func testTheBatchLimitsApplyWithinARunOfEvents() throws {
        let kinds = Array(repeating: "track", count: 150) + ["link", "track"]
        var rows = try kinds.enumerated().map { QueuedEvent(seq: Int64($0.offset + 1), body: try body($0.element)) }
        var counts: [Int] = []
        while let take = Take(taking: rows) {
            counts.append(take.count)
            rows.removeFirst(take.count)
        }
        XCTAssertEqual(counts, [100, 50, 1, 1])
    }

    func testALinkIsPostedAloneUncompressedWithTheWriteKey() async throws {
        let expected = try XCTUnwrap(fixture()["request"]?["body"])
        let link = Link(anonymousId: try XCTUnwrap(expected["anonymousId"]?.string), externalId: try XCTUnwrap(expected["externalId"]?.string))
        let queue = try store("request").queue
        let date = clock.now
        try queue.write { try $0.append(link.body(), createdAt: date) }
        try await sender(queue).drain(.everything)

        let request = try XCTUnwrap(StubServer.requests.first)
        XCTAssertEqual(StubServer.requests.count, 1)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url.absoluteString, "https://ingest.test/v1/identify")
        XCTAssertEqual(request.headers["Authorization"], "Bearer ios-key")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertNil(request.headers["Content-Encoding"])
        XCTAssertEqual(try JSONValue(JSONSerialization.jsonObject(with: request.body)), expected)
        XCTAssertEqual(try queue.count(), 0)
    }

    func testEveryLinkOutcome() async throws {
        let queue = try store("outcomes").queue
        let cases = try XCTUnwrap(fixture()["outcomes"]?["cases"]?.array)
        XCTAssertFalse(cases.isEmpty)
        for scenario in cases {
            let name = try XCTUnwrap(scenario["name"]?.string)
            let status = try integer(scenario["status"])
            let outcome = try XCTUnwrap(scenario["outcome"]?.string)
            XCTAssertEqual(Outcome(linkStatus: status).rawValue, outcome, name)

            StubServer.reset(status: status)
            let date = clock.now
            try queue.write { try $0.append(Self.link.body(), createdAt: date) }
            try await sender(queue).drain(.everything)
            XCTAssertEqual(StubServer.requests.map(\.url.path), ["/v1/identify"], name)
            XCTAssertEqual(try queue.count(), outcome == "retry" ? 1 : 0, "\(name): \(status)")
            try queue.delete(through: .max)
        }
    }

    // MARK: Sending

    func testALinkUnderAMountedEndpointKeepsThePath() async throws {
        let queue = try store("mounted").queue
        let date = clock.now
        try queue.write { try $0.append(Self.link.body(), createdAt: date) }
        try await sender(queue, endpoint: "https://ingest.test/analytics/").drain(.everything)

        XCTAssertEqual(StubServer.requests.map(\.url.absoluteString), ["https://ingest.test/analytics/v1/identify"])
    }

    func testARetriedLinkHoldsBackTheAccountsEvents() async throws {
        StubServer.reset(status: 503)
        let (queue, tracker) = try store("retry")
        tracker.identifyInstallation()
        tracker.identify("user_42")
        tracker.track(Event(name: "b", properties: [:]))
        let sender = try sender(queue)

        await sender.drain(.everything)
        XCTAssertEqual(try sentKinds(), [["link"]])
        XCTAssertEqual(try queue.count(), 2)

        clock.advance(by: 6.001)
        StubServer.answer(204)
        await sender.drain(.everything)
        XCTAssertEqual(try sentKinds(), [["link"], ["link"], ["track"]])
        XCTAssertEqual(try queue.count(), 0)
    }

    func testALinkThatCannotBeSentIsDropped() async throws {
        let queue = try store("malformed").queue
        let date = clock.now
        try queue.write { transaction in
            try transaction.append(#"{"type":"identify","anonymousId":7}"#, createdAt: date)
            try transaction.append(body("track"), createdAt: date)
        }
        try await sender(queue).drain(.everything)

        XCTAssertEqual(try sentKinds(), [["track"]])
        XCTAssertEqual(try queue.count(), 0)
    }

    func testLinksAgeOutWithEvents() async throws {
        let queue = try store("expiry").queue
        let old = clock.now
        try queue.write { try $0.append(Self.link.body(), createdAt: old) }
        clock.advance(by: Sender.maxAge + 1)
        let fresh = clock.now
        try queue.write { try $0.append(body("track"), createdAt: fresh) }
        try await sender(queue).drain(.everything)

        XCTAssertEqual(try sentKinds(), [["track"]])
        XCTAssertEqual(try queue.count(), 0)
    }

    // MARK: Storing

    func testLinksCountAgainstTheQueueLimit() throws {
        let (queue, tracker) = try store("limit", maxQueue: 2)
        tracker.identifyInstallation()
        tracker.track(Event(name: "a", properties: [:]))
        tracker.identify("user_42")
        tracker.track(Event(name: "b", properties: [:]))

        let rows = try queue.oldest(10)
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Link(body: rows[0].body)?.externalId, "user_42")
        XCTAssertEqual(try JSONValue.object(parsing: rows[1].body)["event"], .string("b"))
    }

    func testTheVisitorIsKeptAcrossLaunches() throws {
        let visitor: String
        do {
            let (queue, tracker) = try store("launches")
            tracker.identifyInstallation()
            visitor = try snapshot(queue).identity.externalId
        }
        let (queue, tracker) = try store("launches")
        tracker.identifyInstallation()

        XCTAssertNotNil(visitor.wholeMatch(of: Self.visitor))
        XCTAssertEqual(try snapshot(queue).identity.externalId, visitor)
    }

    func testAResetForgetsTheVisitorAndTheTraits() throws {
        let (queue, tracker) = try store("reset")
        tracker.identifyInstallation()
        tracker.setTraits(["plan": .string("pro")])
        let visitor = try snapshot(queue).identity.externalId
        tracker.reset()
        XCTAssertEqual(try snapshot(queue).identity, Identity(externalId: "*", traits: [:], lastLaunch: nil))

        tracker.identifyInstallation()
        let next = try snapshot(queue).identity.externalId
        XCTAssertNotNil(next.wholeMatch(of: Self.visitor))
        XCTAssertNotEqual(next, visitor)
    }

    // MARK: The public API

    func testAVisitorIsLinkedBetweenItsEventsAndTheAccounts() async throws {
        let clickMan = try ClickMan(configuration: .test(storage: storage))
        clickMan.identifyInstallation()
        clickMan.track("a")
        clickMan.identify("user_42")
        clickMan.track("b")
        XCTAssertEqual(clickMan.pendingEvents, 3)
        await clickMan.flush()

        let requests = StubServer.requests
        XCTAssertEqual(requests.map(\.url.path), ["/v1/batch", "/v1/identify", "/v1/batch"])
        guard requests.count == 3 else { return }
        let visitor = try XCTUnwrap(events(requests[0]).first?["externalId"]?.string)
        XCTAssertNotNil(visitor.wholeMatch(of: Self.visitor))
        XCTAssertEqual(
            try JSONValue(JSONSerialization.jsonObject(with: requests[1].body)),
            .object(["anonymousId": .string(visitor), "externalId": .string("user_42")])
        )
        XCTAssertEqual(try events(requests[2]).map { $0["externalId"] }, [.string("user_42")])
        XCTAssertEqual(clickMan.pendingEvents, 0)
    }

    func testAVisitorIdIsRefusedThroughThePublicAPI() async throws {
        let clickMan = try ClickMan(configuration: .test(storage: storage))
        clickMan.identify(Self.link.anonymousId)
        clickMan.track("a")
        await clickMan.flush()

        XCTAssertEqual(try sentKinds(), [["track"]])
        XCTAssertEqual(try events(XCTUnwrap(StubServer.requests.first)).first?["externalId"], .string("*"))
    }
}
