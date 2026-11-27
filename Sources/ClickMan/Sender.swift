import Foundation
import os

/// Which waiting events a drain sends.
enum DrainScope: Sendable {
    /// Only once enough are waiting or the oldest has waited long enough.
    case due
    /// Everything waiting: a flush, leaving the foreground, the network returning.
    case everything
}

/// Sends the waiting events in batches and the links between them alone, one
/// request in flight at a time, and backs off after a failed send
/// (docs/PROTOCOL.md, Sending; Visitors and links). The failures are counted in
/// memory, so a restarted client sends at once.
actor Sender {
    /// How long an event may wait unsent before it is deleted.
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    /// Whether the next take may go out.
    private enum Pace {
        /// The last take left the queue.
        case open
        /// `failures` takes in a row stayed; the next attempt waits until `nextAttemptAt`.
        case backingOff(failures: Int, nextAttemptAt: Date)
    }

    /// What the server said to a take; status 0 when nothing came back.
    private struct Answer {
        let status: Int
        let retryAfter: TimeInterval?
        let detail: String
    }

    private let queue: Queue
    private let batchRequest: URLRequest
    private let linkRequest: URLRequest
    private let session: URLSession
    private let flushAt: Int
    private let flushInterval: Duration
    private let clock: @Sendable () -> Date
    private let logger: Logger
    private var pace = Pace.open
    private var drains: Task<Void, Never>?

    init(queue: Queue, configuration: ClickMan.Configuration, clock: @escaping @Sendable () -> Date, logger: Logger) throws {
        self.queue = queue
        self.batchRequest = try configuration.request(.batch)
        self.linkRequest = try configuration.request(.identify)
        self.session = configuration.session
        self.flushAt = configuration.flushAt
        self.flushInterval = configuration.flushInterval
        self.clock = clock
        self.logger = logger
    }

    /// Sends takes until none is due or a send fails, after the drains asked for before it.
    func drain(_ scope: DrainScope) async {
        let previous = drains
        let current = Task {
            await previous?.value
            await sendTakes(scope)
        }
        drains = current
        await current.value
    }

    private func sendTakes(_ scope: DrainScope) async {
        do {
            while let take = try dueTake(scope) {
                guard try await send(take) != .retry else {
                    return
                }
            }
        } catch {
            logger.error("ClickMan could not send what is waiting: \(String(describing: error), privacy: .public)")
        }
    }

    /// The take to send now: none while a retry waits, while nothing is due, or when nothing waits.
    private func dueTake(_ scope: DrainScope) throws -> Take? {
        let now = clock()
        try queue.purge(createdBefore: now.addingTimeInterval(-Self.maxAge))
        guard mayAttempt(at: now), try isDue(scope, at: now) else {
            return nil
        }
        return Take(taking: try queue.oldest(Batch.maxEvents))
    }

    private func mayAttempt(at date: Date) -> Bool {
        switch pace {
        case .open: true
        case .backingOff(_, let nextAttemptAt): date >= nextAttemptAt
        }
    }

    private func isDue(_ scope: DrainScope, at date: Date) throws -> Bool {
        guard let waiting = try queue.waiting() else {
            return false
        }
        switch scope {
        case .everything:
            return true
        case .due:
            return waiting.count >= flushAt || .seconds(date.timeIntervalSince(waiting.oldestCreatedAt)) >= flushInterval
        }
    }

    private func send(_ take: Take) async throws -> Outcome {
        switch take {
        case .batch(let batch):
            var request = batchRequest
            request.httpBody = try Gzip.compress(batch.payload(sentAt: clock()))
            let answer = await post(request)
            let outcome = Outcome(status: answer.status)
            try settle(take, outcome: outcome, answer: answer, sent: "\(batch.bodies.count) events")
            return outcome
        case .link(let seq, let body):
            guard let link = Link(body: body) else {
                logger.error("ClickMan dropped a link it cannot send: \(body, privacy: .private)")
                try queue.delete(through: seq)
                return .refused
            }
            var request = linkRequest
            request.httpBody = try link.payload()
            let answer = await post(request)
            let outcome = Outcome(linkStatus: answer.status)
            try settle(take, outcome: outcome, answer: answer, sent: "a link")
            return outcome
        }
    }

    private func post(_ request: URLRequest) async -> Answer {
        do {
            let (data, response) = try await session.data(for: request, delegate: RedirectPolicy.shared)
            guard let http = response as? HTTPURLResponse else {
                return Answer(status: 0, retryAfter: nil, detail: "the answer was not HTTP")
            }
            let retryAfter = RetryDelay.retryAfter(http.value(forHTTPHeaderField: "Retry-After"))
            return Answer(status: http.statusCode, retryAfter: retryAfter, detail: String(decoding: data.prefix(512), as: UTF8.self))
        } catch {
            return Answer(status: 0, retryAfter: nil, detail: error.localizedDescription)
        }
    }

    /// `sent` names what the take sent for the log, e.g. `3 events`.
    private func settle(_ take: Take, outcome: Outcome, answer: Answer, sent: String) throws {
        switch outcome {
        case .delivered:
            try remove(take)
        case .refused:
            logger.error("ClickMan dropped \(sent, privacy: .public) the server refused with \(answer.status): \(answer.detail, privacy: .public)")
            try remove(take)
        case .retry:
            backOff(after: answer, sent: sent)
        }
    }

    private func remove(_ take: Take) throws {
        try queue.delete(through: take.lastSeq)
        pace = .open
    }

    private func backOff(after answer: Answer, sent: String) {
        let failures = min(failures, Int.max - 1) + 1
        let delay = RetryDelay.seconds(failures: failures, retryAfter: answer.retryAfter)
        pace = .backingOff(failures: failures, nextAttemptAt: clock().addingTimeInterval(delay))
        logger.error("ClickMan will retry \(sent, privacy: .public) in \(delay.rounded(.up))s, the answer was \(answer.status): \(answer.detail, privacy: .public)")
    }

    private var failures: Int {
        switch pace {
        case .open: 0
        case .backingOff(let failures, _): failures
        }
    }

}

/// A redirect remains a retry response; it cannot forward an event or source key to another URL.
private final class RedirectPolicy: NSObject, URLSessionTaskDelegate {
    static let shared = RedirectPolicy()

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}
