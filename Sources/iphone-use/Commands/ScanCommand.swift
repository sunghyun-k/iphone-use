import ArgumentParser
import Foundation

/// Sweeps the accessibility elements of the current screen, values included.
///
/// **This command changes the screen.** It is not read-only. The daemon has no "just give me what's
/// visible" API, so it sweeps the way VoiceOver does — pushing the inspector focus one step at a time —
/// and when focus moves to an off-screen element the system **scrolls** to make it visible. So after a
/// full round the screen has scrolled to the end of the list, and many returned elements aren't on screen
/// now. If you plan to act by coordinates, don't trust the scan; look at `screenshot`.
///
/// Two mitigations:
/// - `--limit` stops after the first N elements (usually about one screenful).
/// - `--restore` (on by default) moves focus back to the first element at the end, scrolling back up.
struct ScanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Sweep accessibility elements and dump them as JSON (warning: scrolls the screen).",
        discussion: """
            It sweeps by pushing focus, so the screen scrolls down. By default it scrolls back to the top
            at the end, but modals and custom containers may not fully recover.
            If you only want what's visible now, `screenshot` is the safer choice.
            """
    )

    /// Attributes read per element. Same set as the Python prototype, so outputs compare directly.
    static let basicAttributes = [
        "Label", "Value", "TraitsHumanReadable", "Identifier", "Hint", "UserInputLabels",
    ]

    @OptionGroup var device: DeviceOptions

    @Option(name: .long, help: "Also read the hierarchy (_AXHierarchyElementsAttribute).")
    var hierarchy: Bool = true

    @Option(name: .long, help: "How long to wait for a focus event (seconds).")
    var timeout: Double = 1.0

    @Option(name: .long, help: "Max number of elements to sweep. 0 does a full round.")
    var limit: Int = 0

    @Flag(
        inversion: .prefixedNo,
        help: "At the end, move focus back to the first element to scroll back up.")
    var restore: Bool = true

    func run() throws {
        try AXSession.with(udid: device.udid) { session in
            session.resetAuditTarget()
            try session.beginFocusWalk()
            try session.moveFocus()

            var nodes: [[String: Any]] = []
            var seen = Set<Data>()
            var silentRounds = 0
            var truncated = false

            while true {
                if limit > 0 && nodes.count >= limit {
                    truncated = true
                    break
                }
                guard let focus = session.nextFocus(timeout: timeout) else {
                    silentRounds += 1
                    if silentRounds >= 5 {
                        if nodes.isEmpty {
                            throw ScanError.noFocusEvents
                        }
                        break
                    }
                    try session.moveFocus()
                    continue
                }
                silentRounds = 0

                guard let token = AXSession.token(of: focus) else { continue }
                if seen.contains(token) {
                    break  // completed a full round
                }
                seen.insert(token)

                nodes.append(try node(for: token, focus: focus, session: session))
                try session.moveFocus()
            }

            if restore {
                // Moving focus back to the first element makes the system scroll up to show it.
                // If the focus event isn't consumed once, it overlaps the next move and breaks the daemon.
                try? session.moveFocus(.first)
                _ = session.nextFocus(timeout: timeout)
            }

            var payload: [String: Any] = ["elements": AXWire.jsonReady(nodes)]
            payload["count"] = nodes.count
            payload["truncated"] = truncated
            payload["note"] =
                "scan sweeps by pushing focus, so the screen has scrolled. Take coordinates from screenshot."

            let json = try JSONSerialization.data(
                withJSONObject: payload,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            print(String(decoding: json, as: UTF8.self))
        }
    }

    private func node(
        for token: Data, focus: [String: Any], session: AXSession
    ) throws -> [String: Any] {
        var node: [String: Any] = [
            "ref": token.map { String(format: "%02X", $0) }.joined()
        ]
        if let caption = focus["CaptionTextValue_v1"] {
            node["caption"] = caption
        }

        for name in Self.basicAttributes {
            guard let value = try session.value(of: token, attribute: name) else { continue }
            if let text = value as? String, text.isEmpty { continue }
            if let list = value as? [Any], list.isEmpty { continue }
            node[name] = value
        }

        if hierarchy,
            let value = try session.value(of: token, attribute: "_AXHierarchyElementsAttribute")
                as? [String: Any]
        {
            node["hierarchy"] = value
        }

        return node
    }
}

enum ScanError: Error, CustomStringConvertible {
    case noFocusEvents

    var description: String {
        """
        No focus events arrive. The screen is off or locked (check with screenshot), \
        Accessibility Inspector is holding the session, or the daemon still has a dead audit target pid.
        """
    }
}
