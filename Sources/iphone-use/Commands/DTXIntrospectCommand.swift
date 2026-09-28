import ArgumentParser
import CDTXBridge
import Foundation

/// Prints the actual methods of a private DTX class.
///
/// Guessing selectors from a string dump easily picks up strings belonging to another class.
/// (We guessed `DTXMessage` had `count` or `argumentsCount` and were wrong twice.)
struct DTXIntrospectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dtx-introspect",
        abstract: "Print the method list of a loaded private class."
    )

    @Argument(help: "Class name, e.g. DTXMessage, DTXChannel, DTXConnection")
    var className: String

    @Option(name: .long, help: "Only show methods containing this string.")
    var filter: String?

    @Option(name: .long, help: "Extra framework path to dlopen.")
    var framework: [String] = []

    @Flag(name: .long, help: "Print ivars instead of methods.")
    var ivars: Bool = false

    func run() throws {
        try IUDTXConnection.loadFramework(atPath: AXSession.dtxFrameworkPath())
        for path in framework {
            try IUDTXConnection.openBundle(atPath: path)
        }

        let source = ivars
            ? IUDTXConnection.ivars(forClassNamed: className)
            : IUDTXConnection.methods(forClassNamed: className)
        guard let methods = source else {
            throw ValidationError("Class not found: \(className)")
        }

        let shown = filter.map { needle in
            methods.filter { $0.localizedCaseInsensitiveContains(needle) }
        } ?? methods

        print("\(className): \(shown.count)/\(methods.count)")
        for method in shown {
            print("  \(method)")
        }
    }
}
