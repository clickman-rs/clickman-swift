/// Who later events are about, their traits, and the last launch the store
/// remembers (protocol/queue.sql, `identity`).
struct Identity: Equatable, Sendable {
    /// The prefix of a visitor's `externalId`, `anon:<UUIDv4>` (identity.json).
    static let visitorPrefix = "anon:"

    var externalId: String
    var traits: [String: JSONValue]
    var lastLaunch: Launch?

    /// `stored` merged key by key with `changes`: a change replaces a trait whole
    /// and null removes it (traits.json).
    static func merge(traits stored: [String: JSONValue], with changes: [String: JSONValue]) -> [String: JSONValue] {
        changes.reduce(into: stored) { traits, change in
            traits[change.key] = change.value == .null ? nil : change.value
        }
    }

    /// Whether `externalId` is a visitor that `identifyInstallation` started
    /// rather than an account of the host or the anonymous actor `*`.
    static func isVisitor(_ externalId: String) -> Bool {
        externalId.hasPrefix(visitorPrefix)
    }
}
