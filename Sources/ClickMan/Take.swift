/// What one request sends from the oldest waiting rows (docs/PROTOCOL.md,
/// Visitors and links; identity.json `takes`): a link alone, or a batch of the
/// track rows before the next link, within the batch limits.
enum Take: Equatable, Sendable {
    case batch(Batch)
    /// A link row: its place and its JSON.
    case link(seq: Int64, body: String)

    /// The take the oldest of `rows`, oldest first, make; nil when none wait.
    init?(taking rows: [QueuedEvent]) {
        guard let first = rows.first else {
            return nil
        }
        if Link.isLink(first.body) {
            self = .link(seq: first.seq, body: first.body)
            return
        }
        guard let batch = Batch(taking: Array(rows.prefix { !Link.isLink($0.body) })) else {
            return nil
        }
        self = .batch(batch)
    }

    /// How many of the oldest rows the take holds.
    var count: Int {
        switch self {
        case .batch(let batch): batch.bodies.count
        case .link: 1
        }
    }

    /// The `seq` of the newest row taken: the take leaves the queue through it.
    var lastSeq: Int64 {
        switch self {
        case .batch(let batch): batch.lastSeq
        case .link(let seq, _): seq
        }
    }
}
