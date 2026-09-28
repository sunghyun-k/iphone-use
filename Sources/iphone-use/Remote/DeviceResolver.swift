import Foundation

/// Resolves the `--udid` value to a real UDID. Accepts a UDID as-is or a device name ("Home iPad").
///
/// When omitted, it uses the device **only if exactly one is reachable right now**. It used to just
/// take the first device remotepairingd reported, but that list includes devices that aren't connected
/// (paired once before), so with two or more devices it was luck which one got driven. Asking once
/// beats tapping on someone else's device.
enum DeviceResolver {
    struct Candidate {
        let udid: String
        let name: String
    }

    enum Failure: Error, CustomStringConvertible {
        case none
        case ambiguous([Candidate])
        case unknown(String, [Candidate])

        var description: String {
            switch self {
            case .none:
                return "No device connection. Check the USB connection or same Wi-Fi, trust pairing, and that the device is unlocked."
            case .ambiguous(let list):
                return "More than one device. Pass a UDID or device name to --udid:\n" + Self.format(list)
            case .unknown(let wanted, let list):
                return "No device named \"\(wanted)\". Devices with a connection now:\n" + Self.format(list)
            }
        }

        private static func format(_ list: [Candidate]) -> String {
            list.map { "  \($0.name)  \($0.udid)" }.joined(separator: "\n")
        }
    }

    /// In the daemon, gathering the list per request (0.4 s) would defeat the point, so remember it briefly.
    /// Remember too long and a second device plugged in later goes unseen while we keep believing "only one", so keep it short.
    nonisolated(unsafe) private static var cache: [String: (udid: String, at: Date)] = [:]
    private static let cacheLifetime: TimeInterval = 30

    static func udid(for wanted: String?) throws -> String {
        // Don't ask if it looks like a UDID (gathering the list takes about 0.4 s).
        if let wanted, looksLikeUDID(wanted) { return wanted }
        let key = wanted ?? ""
        if let hit = cache[key], Date().timeIntervalSince(hit.at) < cacheLifetime { return hit.udid }

        let current = RemotePairingTunnel.devices().compactMap { info -> Candidate? in
            guard let udid = info["udid"] as? String else { return nil }
            return Candidate(udid: udid, name: info["name"] as? String ?? "?")
        }
        let resolved: String
        if let wanted {
            let matches = current.filter { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
            guard matches.count == 1 else {
                throw matches.isEmpty ? Failure.unknown(wanted, current) : Failure.ambiguous(matches)
            }
            resolved = matches[0].udid
        } else {
            guard !current.isEmpty else { throw Failure.none }
            guard current.count == 1 else { throw Failure.ambiguous(current) }
            resolved = current[0].udid
        }
        cache[key] = (resolved, Date())
        return resolved
    }

    private static func looksLikeUDID(_ text: String) -> Bool {
        text.count >= 24 && text.allSatisfy { $0.isHexDigit || $0 == "-" }
    }
}
