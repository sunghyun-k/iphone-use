import CoreGraphics
import Foundation

// Image input to the model arrived with the macOS 27 SDK (Swift 6.4); an older Xcode builds without it, and
// FoundationModels is weak-linked, so the binary still starts on macOS 14.
#if canImport(FoundationModels) && compiler(>=6.4)
    import FoundationModels
#endif

/// Names the `[icon]` lines (shapes no SF Symbol template matched) by asking the Mac's on-device model
/// about a crop of each one (`ui --icons`).
///
/// Asked one icon at a time: given the whole screen, the model invented controls and missed most icons,
/// while a crop of a single icon got a usable name in about half a second (PITFALLS #57).
enum IconNamer {
    /// Beyond this many, the rest stay `[icon]`: each costs about half a second.
    static let limit = 16

    /// Why naming can't run here, or nil when it can.
    static var unavailableReason: String? {
        #if canImport(FoundationModels) && compiler(>=6.4)
            if #available(macOS 27.0, *) {
                switch SystemLanguageModel.default.availability {
                case .available: return nil
                case .unavailable(let reason): return "the on-device model isn't available (\(reason))"
                }
            }
            return "naming icons needs macOS 27 or later (image input to the on-device model)"
        #else
            return "this build has no image input to FoundationModels (built with an Xcode older than 27)"
        #endif
    }

    /// A name for each rect in `rects` (device pixels on `image`); nil where the model gave none.
    static func names(for rects: [CGRect], in image: CGImage, pointScale: Int) -> [String?] {
        #if canImport(FoundationModels) && compiler(>=6.4)
            if #available(macOS 27.0, *) {
                let crops = rects.map { crop($0, from: image, pointScale: pointScale) }
                let box = ResultBox(count: crops.count)
                let done = DispatchSemaphore(value: 0)
                let input = CropList(crops: crops)
                Task.detached {
                    for (index, crop) in input.crops.enumerated() {
                        guard let crop else { continue }
                        box.set(index, await name(of: crop))
                    }
                    done.signal()
                }
                done.wait()
                return box.values
            }
        #endif
        return rects.map { _ in nil }
    }

    /// A square around the icon with some margin, at least 40 pt: the model needs a little context, and a
    /// tight crop of a thin glyph reads as "line".
    private static func crop(_ rect: CGRect, from image: CGImage, pointScale: Int) -> CGImage? {
        let side = max(max(rect.width, rect.height) * 1.6, 40 * CGFloat(pointScale))
        let square = CGRect(x: rect.midX - side / 2, y: rect.midY - side / 2, width: side, height: side)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        return square.isEmpty ? nil : image.cropping(to: square)
    }

    #if canImport(FoundationModels) && compiler(>=6.4)
        @available(macOS 27.0, *)
        @Generable
        struct IconName {
            @Guide(
                description: """
                    What the icon depicts, 1-3 lowercase English words, e.g. 'house', 'paper plane', \
                    'magnifying glass', 'play button', 'heart', 'plus', 'profile picture'
                    """)
            var name: String
        }

        @available(macOS 27.0, *)
        private static func name(of crop: CGImage) async -> String? {
            // A fresh session per icon: a shared one carries the earlier answers along and starts
            // repeating them.
            let session = LanguageModelSession(
                instructions: "You name the icon shown in a small image cut from an iPhone or iPad screen.")
            let reply: LanguageModelSession.Response<IconName>
            do {
                reply = try await session.respond(generating: IconName.self) {
                    "What does this icon depict?"
                    Attachment<ImageAttachmentContent>(crop)
                }
            } catch {
                return nil
            }
            let name = reply.content.name.lowercased()
                .filter { $0.isLetter || $0 == " " || $0 == "-" }
                .trimmingCharacters(in: .whitespaces)
            return name.isEmpty || name.count > 30 ? nil : name
        }
    #endif

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String?]
        init(count: Int) { stored = Array(repeating: nil, count: count) }
        func set(_ index: Int, _ value: String?) { lock.withLock { stored[index] = value } }
        var values: [String?] { lock.withLock { stored } }
    }

    private struct CropList: @unchecked Sendable {
        let crops: [CGImage?]
    }
}
