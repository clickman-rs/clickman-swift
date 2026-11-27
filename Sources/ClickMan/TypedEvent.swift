/// An event the app declares in code (docs/PROTOCOL.md, Event catalog): the
/// name it is tracked under, its typed properties, and the catalog of every
/// event of its declaration. The `@ClickManEvents` macro of the
/// `ClickManEvents` product derives all three from an enum; a hand-written
/// conformance must keep them consistent itself.
public protocol ClickManEvent {
    /// The name the event is tracked under, e.g. `export_completed`.
    var name: String { get }
    /// The properties tracked with the event. An optional property without a
    /// value is left out, never sent as null.
    var properties: [String: ClickManPropertyValue] { get }
    /// Every event of the declaration with its meaning and property types,
    /// for upload as the source's catalog.
    static var catalog: ClickManCatalog { get }
}

/// The only strings a property takes, in declaration order, e.g.
/// `enum Format: String, ClickManValues { case wav, flac }`. A value is its
/// raw value in snake case, so `case perTrack` is `per_track`; implement
/// `clickManValue` to choose the values yourself.
public protocol ClickManValues: CaseIterable {
    /// The value the property is tracked with and declared in the catalog.
    var clickManValue: String { get }
}

extension ClickManValues where Self: RawRepresentable, RawValue == String {
    public var clickManValue: String {
        ClickManNaming.snakeCase(rawValue)
    }
}

/// A free-text string property, e.g. `title: ClickManText?`. Free text can
/// carry personal data, so `@ClickManEvents` takes a string only when it is
/// declared as `ClickManText` or as a `ClickManValues` enum.
public typealias ClickManText = String

/// The value of one property of a typed event.
public struct ClickManPropertyValue: Equatable, Sendable, CustomStringConvertible {
    let json: JSONValue

    /// An integer, sent exactly: unsigned 64-bit values above `Int64.max` too.
    public static func integer<Value: BinaryInteger>(_ value: Value) -> Self {
        if let signed = Int64(exactly: value) {
            return Self(json: .integer(signed))
        }
        if let unsigned = UInt64(exactly: value) {
            return Self(json: .unsigned(unsigned))
        }
        return Self(json: .number(Double(value)))
    }

    /// A floating-point number; an event with a non-finite one is not stored.
    public static func number<Value: BinaryFloatingPoint>(_ value: Value) -> Self {
        Self(json: .number(Double(value)))
    }

    public static func boolean(_ value: Bool) -> Self {
        Self(json: .bool(value))
    }

    /// Free text, declared as `ClickManText`.
    public static func text(_ value: String) -> Self {
        Self(json: .string(value))
    }

    /// One of the values a `ClickManValues` enum declares.
    public static func value<Value: ClickManValues>(_ value: Value) -> Self {
        Self(json: .string(value.clickManValue))
    }

    public var description: String {
        (try? json.json()) ?? String(describing: json)
    }
}

extension ClickMan {
    /// Queues a declared event with exactly its properties, e.g.
    /// `analytics.track(AppEvent.exportCompleted(format: .wav, tracks: 2))`.
    /// Like the string `track`, it never throws: an event that cannot be
    /// stored is dropped and logged.
    public func track(_ event: some ClickManEvent) {
        tracker.track(Event(name: event.name, properties: event.properties.mapValues(\.json)))
    }
}
