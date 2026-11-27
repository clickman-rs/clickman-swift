import Foundation

/// A visitor linked to the account it became (docs/PROTOCOL.md, Visitors and
/// links). The queue keeps it as a row of its own between the visitor's events
/// and the account's, and it is sent alone to `POST /v1/identify`.
struct Link: Equatable, Sendable {
    let anonymousId: String
    let externalId: String

    init(anonymousId: String, externalId: String) {
        self.anonymousId = anonymousId
        self.externalId = externalId
    }

    /// The link a queued row holds; nil when the row is not a link one can send.
    init?(body: String) {
        guard Self.isLink(body), let row = try? JSONValue.object(parsing: body),
              case .string(let anonymousId)? = row["anonymousId"], case .string(let externalId)? = row["externalId"]
        else {
            return nil
        }
        self.init(anonymousId: anonymousId, externalId: externalId)
    }

    /// Whether a queued row is a link rather than a track event: a JSON object of
    /// type `identify`. A link row is small, so a large row is never parsed.
    static func isLink(_ body: String) -> Bool {
        guard body.utf8.count <= 4096, body.contains(#""identify""#),
              let row = try? JSONValue.object(parsing: body)
        else {
            return false
        }
        return row["type"] == .string("identify")
    }

    /// The row the queue keeps: the link with `"type": "identify"`.
    func body() throws -> String {
        try JSONValue.object([
            "type": .string("identify"),
            "anonymousId": .string(anonymousId),
            "externalId": .string(externalId),
        ]).json()
    }

    /// The request body: the link without its type, sent uncompressed.
    func payload() throws -> Data {
        Data(try JSONValue.object(["anonymousId": .string(anonymousId), "externalId": .string(externalId)]).json().utf8)
    }
}
