import ArgumentParser


struct IPhoneUse: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iphone-use",
        abstract: "See and control a connected iPhone or iPad over USB or Wi-Fi.",
        discussion: """
            Reads the screen from screenshots (OCR on the Mac) and sends touches and keys through the private \
            CoreDevice stack Xcode's Device Hub uses. Needs no entitlements, no sudo and no app on the device, \
            but the device must be paired and trusted.
            """,
        version: "0.4.0",
        subcommands: [
            // Read the screen's text and act on it (the default)
            UICommand.self, PressCommand.self, TypeCommand.self, HomeCommand.self,
            // Apps
            AppsCommand.self, LaunchCommand.self, OpenCommand.self,
            // Device settings
            SettingsCommand.self, LocationCommand.self,
            // Screenshots and coordinate input (icons and anything without text)
            ScreenshotCommand.self, WaitCommand.self,
            TouchCommand.self, SwipeCommand.self, ScrollCommand.self, TextCommand.self, KeyCommand.self, ButtonCommand.self, PasteCommand.self, ClipboardCommand.self,
            // Device / diagnostics
            DaemonCommand.self, DevicesCommand.self, HIDInfoCommand.self, InvokeCommand.self,
        ]
    )
}

/// Option shared by device listing/selection.
struct DeviceOptions: ParsableArguments {
    @Option(
        name: .long,
        help: "UDID or name of the target device (as shown by devices, e.g. \"Home iPad\"). May be omitted when only one device is connected.")
    var udid: String?
}
