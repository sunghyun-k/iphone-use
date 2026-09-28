import ArgumentParser


struct IPhoneUse: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "iphone-use",
        abstract: "See and control a connected iPhone or iPad over USB or Wi-Fi.",
        discussion: """
            Runs on the private stack used by Xcode's Device Hub and Accessibility Inspector.
            Needs no entitlements and no sudo, but the device must be paired and trusted.
            """,
        version: "0.1.0",
        subcommands: [
            // See and act through accessibility (the default)
            UICommand.self, PressCommand.self, TypeCommand.self, BackCommand.self, HomeCommand.self,
            // Apps
            AppsCommand.self, LaunchCommand.self, OpenCommand.self,
            // Device settings
            SettingsCommand.self, LocationCommand.self,
            // Screen viewing and coordinate input (for screens with poor accessibility names)
            ScreenshotCommand.self, WaitCommand.self, ScanCommand.self, AttrCommand.self,
            TouchCommand.self, SwipeCommand.self, ScrollCommand.self, TextCommand.self, KeyCommand.self, ButtonCommand.self, PasteCommand.self, ClipboardCommand.self,
            // Device / diagnostics
            DaemonCommand.self, DevicesCommand.self, HIDInfoCommand.self, InvokeCommand.self, AXProbeCommand.self, DTXIntrospectCommand.self,
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
