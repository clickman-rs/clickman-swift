@_exported import ClickMan

/// Makes the cases of an enum the app's events (docs/PROTOCOL.md, Event
/// catalog). Each case is an event and its labeled associated values are the
/// properties; the doc comment of the case describes the event, and its
/// DocC `- Parameter name:` or `- Parameters:` entries describe the
/// properties. Names become snake case: `exportCompleted(durationSeconds:)`
/// tracks `export_completed` with `duration_seconds`.
///
/// ```swift
/// @ClickManEvents
/// enum AppEvent {
///     /// Export wrote every file
///     /// and they are ready to use.
///     ///
///     /// - Parameters:
///     ///   - format: File format of the export.
///     ///   - tracks: How many tracks the export contains.
///     ///   - title: Title the user gave the export.
///     case exportCompleted(format: Format, tracks: Int, title: ClickManText? = nil)
/// }
/// ```
///
/// A property is an integer, a floating-point number, a `Bool`, a
/// `ClickManValues` enum or free text declared as `ClickManText`; an
/// optional one is left out when nil. The macro refuses at compile time an
/// event or property without a description, a plain `String` property, an
/// unsupported type, a name that is not snake case after conversion, a
/// repeated name and a standard event (protocol/standard-events.json). It
/// makes the enum a `ClickManEvent`: `name`, `properties` and the `catalog`
/// of all its cases, in declaration order.
@attached(extension, conformances: ClickManEvent, names: named(name), named(properties), named(catalog))
public macro ClickManEvents() = #externalMacro(module: "ClickManMacros", type: "EventsMacro")

/// Names an event of a `@ClickManEvents` enum, or some of its properties,
/// explicitly instead of by snake case of the Swift names, e.g.
/// `@ClickManName("export_done", properties: ["durationSeconds": "duration"])`.
/// The names must still be snake case.
@attached(peer)
public macro ClickManName(_ event: String? = nil, properties: [String: String] = [:]) =
    #externalMacro(module: "ClickManMacros", type: "NameMacro")
