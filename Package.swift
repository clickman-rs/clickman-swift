// swift-tools-version: 6.0
import CompilerPluginSupport
import PackageDescription

/// ClickMan for Apple platforms: a native client of docs/PROTOCOL.md. Events wait
/// in a GRDB store (protocol/queue.sql) and leave in gzipped batches.
///
/// `ClickMan` is the runtime. `ClickManEvents` adds the `@ClickManEvents` macro,
/// which derives typed events and their catalog from declarations; its
/// implementation, `ClickManMacros`, runs in the compiler and never links into
/// the app.
let package = Package(
    name: "ClickMan",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "ClickMan", targets: ["ClickMan"]),
        .library(name: "ClickManEvents", targets: ["ClickManEvents"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "600.0.0"..<"700.0.0"),
    ],
    targets: [
        .target(
            name: "ClickMan",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
            path: "Sources/ClickMan"
        ),
        .macro(
            name: "ClickManMacros",
            dependencies: [
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ],
            path: "Sources/ClickManMacros"
        ),
        .target(
            name: "ClickManEvents",
            dependencies: ["ClickMan", "ClickManMacros"],
            path: "Sources/ClickManEvents"
        ),
        .executableTarget(
            name: "ClickManE2EWorker",
            dependencies: ["ClickMan"],
            path: "Sources/ClickManE2EWorker"
        ),
        .testTarget(
            name: "ClickManTests",
            dependencies: ["ClickMan", "ClickManEvents", .product(name: "GRDB", package: "GRDB.swift")],
            path: "Tests/ClickManTests"
        ),
        .testTarget(
            name: "ClickManMacrosTests",
            dependencies: [
                "ClickManMacros",
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            path: "Tests/ClickManMacrosTests"
        ),
    ]
)
