import Foundation
import os

/// Stamps events and keeps them in the queue with the identity they are tracked
/// under (docs/PROTOCOL.md, Tracking). A failure is logged, never thrown into
/// the host.
final class Tracker: Sendable {
    private let queue: Queue
    private let bundle: Bundle
    private let context: OSAllocatedUnfairLock<[String: JSONValue]>
    private let clock: @Sendable () -> Date
    private let logger: Logger

    init(queue: Queue, bundle: Bundle, clock: @escaping @Sendable () -> Date, logger: Logger) {
        self.queue = queue
        self.bundle = bundle
        self.context = OSAllocatedUnfairLock(initialState: Context.current(bundle: bundle))
        self.clock = clock
        self.logger = logger
    }

    func track(_ event: Event) {
        guard EventField.event.accepts(event.name) else {
            logger.error("ClickMan did not track \(event.name, privacy: .public): an event name is 1 to 200 characters without control characters")
            return
        }
        write("track \(event.name)") { try self.append([event], to: $0) }
    }

    /// Makes `externalId` the actor of later events. A visitor identified as an
    /// account is linked to it by a row between their events (identity.json);
    /// a visitor id is refused. Returns whether the identity was stored.
    @discardableResult
    func identify(_ externalId: String) -> Bool {
        guard EventField.externalId.accepts(externalId) else {
            logger.error("ClickMan did not identify \(externalId, privacy: .private): an external id is 1 to 256 characters without control characters")
            return false
        }
        guard !Identity.isVisitor(externalId) else {
            logger.error("ClickMan did not identify \(externalId, privacy: .private): a visitor id is set only by identifyInstallation")
            return false
        }
        return write("identify the actor") { transaction in
            let current = try transaction.identity().externalId
            guard current != externalId else {
                return
            }
            if Identity.isVisitor(current), externalId != "*" {
                let link = Link(anonymousId: current, externalId: externalId)
                try transaction.append(link.body(), createdAt: self.clock())
            }
            try transaction.setExternalId(externalId)
        }
    }

    /// Makes a store that tracks as `*` track as a new visitor, kept across
    /// launches; a store that tracks as a visitor or an account keeps its actor.
    func identifyInstallation() {
        write("identify the installation") { try $0.identifyInstallation() }
    }

    func setTraits(_ changes: [String: JSONValue]) {
        write("set the traits") { transaction in
            try transaction.setTraits(Identity.merge(traits: transaction.identity().traits, with: changes))
        }
    }

    func reset() {
        write("reset the actor") { try $0.reset() }
    }

    /// Records `launch`'s events after the last launch and remembers it, in one transaction.
    func recordLaunch(_ launch: Launch) {
        write("record the launch") { transaction in
            try self.append(launch.events(after: transaction.identity().lastLaunch), to: transaction)
            try transaction.setLastLaunch(launch)
        }
    }

    /// Takes the context anew, e.g. when the app returns to the foreground.
    func refreshContext() {
        let current = Context.current(bundle: bundle)
        context.withLock { $0 = current }
    }

    private func append(_ events: [Event], to transaction: QueueTransaction) throws {
        let identity = try transaction.identity()
        let context = context.withLock { $0 }
        let date = clock()
        for event in events {
            try transaction.append(event.body(identity: identity, context: context, at: date), createdAt: date)
        }
    }

    /// Runs `work` in one transaction; a failure is logged and returns false.
    @discardableResult
    private func write(_ action: String, _ work: (QueueTransaction) throws -> Void) -> Bool {
        do {
            try queue.write(work)
            return true
        } catch {
            logger.error("ClickMan could not \(action, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
