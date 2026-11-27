import SwiftCompilerPlugin
import SwiftSyntaxMacros

/// The compiler plugin behind the `ClickManEvents` product. It runs only while
/// the app compiles; nothing of it links into the app.
@main
struct ClickManMacrosPlugin: CompilerPlugin {
    let providingMacros: [Macro.Type] = [EventsMacro.self, NameMacro.self]
}
