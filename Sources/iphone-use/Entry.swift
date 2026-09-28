import ArgumentParser
import Foundation

/// The real entry point.
///
/// If the daemon is running, the arguments are forwarded as is; otherwise they are parsed and run here as usual.
@main
enum Entry {
    static func main() {
        let args = hoistingDeviceOption(Array(CommandLine.arguments.dropFirst()))

        if DaemonClient.shouldForward(args), let response = DaemonClient.send(args) {
            exit(DaemonClient.relay(response))
        }
        // We consume `--no-daemon` ourselves. The individual commands don't know this option.
        IPhoneUse.main(args.filter { $0 != "--no-daemon" })
    }

    /// Moves a device option placed **before** the subcommand, as in `iphone-use --udid X screenshot ...`, to after it.
    ///
    /// ArgumentParser doesn't accept a subcommand's options in front of it and fails with "Unknown option".
    /// Agents really did read "--udid on every command" and put it first. This makes either position work.
    static func hoistingDeviceOption(_ args: [String]) -> [String] {
        var rest = args
        var moved: [String] = []
        while let first = rest.first, first == "--udid" || first.hasPrefix("--udid=") {
            if first == "--udid" {
                guard rest.count >= 2 else { break }
                moved += rest.prefix(2)
                rest.removeFirst(2)
            } else {
                moved.append(first)
                rest.removeFirst()
            }
        }
        guard !moved.isEmpty, !rest.isEmpty else { return args }
        return [rest[0]] + moved + rest.dropFirst()
    }
}
