# ClickMan for Swift

ClickMan records analytics events on Apple platforms and sends them to a
ClickMan server. A local SQLite queue keeps events across restarts and offline
periods. The client sends gzip batches, retries failed requests, and tracks app
lifecycle events on iOS.

Requires Swift 6, iOS 16 or later, or macOS 13 or later. The package uses GRDB
for its queue and URLSession for delivery.

## Add the package

For a local checkout, add the package and library product to your `Package.swift`:

```swift
dependencies: [
    .package(path: "../clickman-swift")
],
targets: [
    .target(name: "YourApp", dependencies: [
        .product(name: "ClickMan", package: "clickman-swift")
    ])
]
```

In Xcode, add the package directory as a local package and link the `ClickMan`
product to your app target. Link `ClickManEvents` as well to declare typed events
with its macro.

## Record events

Create one client at app startup and keep it alive for the application's lifetime:

```swift
import ClickMan
import Foundation

let analytics = try ClickMan(configuration: .init(
    endpoint: URL(string: "https://analytics.example.com")!,
    writeKey: "your-project-write-key"
))
analytics.identify("user_42")
analytics.setTraits(["plan": "pro"])
analytics.track("page_viewed", properties: ["screen": "home"])
```

Opening the queue can throw. Tracking does not wait for the network; invalid
properties or storage failures are logged. Properties accept JSON values, plus
`Date`, `URL`, and `UUID` values encoded as strings.

Sending runs in the background. By default, a batch becomes due after 20 queued
events or 30 seconds. The client also attempts to flush when the network returns
or the iOS app enters the background. You can request a send explicitly with
`await analytics.flush()`; retry delays still apply.
Flushes and scheduled sends remove events older than 30 days even while a longer
retry delay is still waiting.

## Typed events and catalog

The `ClickManEvents` product declares the app's events as the cases of an enum.
Its `@ClickManEvents` macro derives each event's name, properties and
descriptions from the declaration and exports them as the source's catalog
([Event catalog](docs/PROTOCOL.md#event-catalog)). The events sent do not change:

```swift
import ClickManEvents

enum ExportFormat: String, ClickManValues {
    case wav, flac
}

@ClickManEvents
enum AppEvent {
    /// Export wrote every file
    /// and they are ready to use.
    ///
    /// - Parameters:
    ///   - format: File format of the export.
    ///   - tracks: How many tracks the export contains.
    ///   - durationSeconds: Length of the exported audio in seconds.
    ///   - title: Title the user gave the export.
    case exportCompleted(format: ExportFormat, tracks: Int, durationSeconds: Double? = nil, title: ClickManText? = nil)

    /// A new empty project was created.
    case projectCreated
}

// export_completed with {"format": "flac", "tracks": 3, "title": "Demo"}
analytics.track(AppEvent.exportCompleted(format: .flac, tracks: 3, title: "Demo"))
```

The doc comment of a case describes the event, and its DocC `- Parameter name:`
or `- Parameters:` entries describe the properties; the lines of a description
are joined with single spaces. Names become snake case: `exportCompleted` is
`export_completed`, `durationSeconds` is `duration_seconds`, and a
`ClickManValues` case `perTrack` is `per_track`. To choose names yourself, mark
the case `@ClickManName("export_done", properties: ["durationSeconds": "duration"])`
or implement `clickManValue` in the values enum.

A property is an integer, a floating-point number, `Bool`, a `ClickManValues`
enum or free text declared as `ClickManText`. An optional property is left out
when nil, never sent as null. Free text can carry personal data, so a plain
`String` is a compile-time error, as are an event or property without a
description, other types, repeated names and standard events such as
`app_opened`.

`AppEvent.catalog.json` and `.jsonString` hold the catalog to upload;
`ClickManCatalog(AppEvent.catalog, OtherEvent.catalog)` combines declarations.
`try AppEvent.catalog.validate()` checks it as the server does on upload,
including the values of `ClickManValues` enums, and throws the server's reason.
An app can print it from its command line:

```swift
if CommandLine.arguments.contains("--analytics-catalog") {
    print(AppEvent.catalog.jsonString)
    exit(0)
}
```

The macro runs only while the app compiles: swift-syntax is a build-time
dependency of `ClickManEvents`, and the `ClickMan` runtime does not use it. A
type can also conform to `ClickManEvent` by hand.

## Configuration and identity

Set options before creating the client:

```swift
var configuration = ClickMan.Configuration(
    endpoint: URL(string: "https://analytics.example.com")!,
    writeKey: "your-project-write-key"
)
configuration.flushAt = 10
configuration.flushInterval = .seconds(15)
configuration.tracksLifecycle = false
let analytics = try ClickMan(configuration: configuration)
```

The default queue lives in Application Support, is excluded from backups, and
holds at most 10,000 events. `storage` selects a different file and `maxQueue`
changes the event limit. Call `reset()` after sign-out to clear identity and traits.

Use the server's base URL as `endpoint`: the client appends `/v1/batch`. For a
server mounted at `/analytics`, use `https://example.com/analytics`.
The endpoint must be an absolute HTTP(S) URL without credentials, query or
fragment. Source keys must contain visible ASCII characters without whitespace.
Configuration is checked before opening the queue; limits and intervals must be
positive, and custom storage must be a file URL. Keep a separate queue file for
each endpoint and source key. Redirect responses retain the batch for retry
instead of forwarding events to another URL.

Properties and traits reject cycles, non-finite numbers and nesting beyond 64
levels. Failed conversions are logged and do not store an event or replace
existing traits. Signed and unsigned 64-bit integer properties keep their exact
values.

## Visitors

Events are tracked as the anonymous actor `*` until `identify`. To count an
installation as a visitor before sign-in, call `identifyInstallation()` at
launch: the client then tracks as `anon:<UUID>`, kept across launches. The call
does nothing while the client tracks as a visitor or an account, so it is safe
to repeat.

```swift
analytics.identifyInstallation()
analytics.track("paywall_viewed")    // the visitor's event
analytics.identify("user_42")        // links the visitor to user_42
analytics.track("export_completed")  // the account's event
```

Identifying a visitor as an account queues a link between them. The link is
sent alone to `/v1/identify`, after the visitor's events and before the
account's; it counts toward `maxQueue` and `pendingEvents`. Switching to
another account or identifying `*` links nothing, and `identify` refuses visitor
IDs (`anon:…`). After `reset()`, call `identifyInstallation()` again to start a
new visitor: a visitor never links to two accounts. Use opaque account IDs,
never an email address.

## Develop and test

```sh
swift test
python3 scripts/queue-schema.py --check
```

`swift test` runs the client tests and the macro tests, which check the
compile-time errors of `@ClickManEvents`. To build and run the tests for iOS:

```sh
xcodebuild build-for-testing -scheme ClickMan-Package -destination 'generic/platform=iOS Simulator' -derivedDataPath .build/xcode
xcodebuild test-without-building -xctestrun .build/xcode/Build/Products/*.xctestrun -destination 'platform=iOS Simulator,name=<simulator>'
```

The [protocol](docs/PROTOCOL.md) covers event fields, the event catalog, queue
behavior, identity, visitors and delivery rules. The
[local protocol snapshot](protocol/README.md) includes the shared fixtures used
by tests; no server checkout is needed. The `ClickManE2EWorker` executable is a
command-line driver for integration tests.

## License

[MIT](LICENSE).
