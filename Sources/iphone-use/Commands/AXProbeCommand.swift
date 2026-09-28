import ArgumentParser
import Foundation

/// Checks the connection to the accessibility daemon. Counterpart of `capabilities` in the Python prototype.
struct AXProbeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ax-probe",
        abstract: "Attach to the accessibility daemon and print the supported selectors."
    )

    @OptionGroup var device: DeviceOptions

    func run() throws {
        try AXSession.with(udid: device.udid) { session in
            session.resetAuditTarget()

            guard let capabilities = try session.invoke("deviceCapabilities") else {
                print("No response")
                return
            }

            if let list = capabilities as? [String] {
                print("\(list.count) supported selectors:")
                for selector in list.sorted() {
                    print("  \(selector)")
                }
            } else {
                print(capabilities)
            }
        }
    }
}
