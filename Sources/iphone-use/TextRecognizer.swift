import CoreGraphics
import Foundation
import Vision

/// Detects the on-screen keyboard in a screenshot. Runs on the Mac's Vision, so the device isn't touched.
///
/// We used to find tap targets by on-screen text (`find`, `tap "text"`). OCR accuracy varies by language
/// and it often pressed the wrong place, so that was removed; targets are now given by accessibility list
/// refs (`ui`). The only remaining use is **whether the keyboard is up**. Keyboard keys are accessibility
/// elements too, but they're at the very end of the focus order and we'd have to walk all the way there,
/// so checking for single-character lines clustered near the bottom of the screen is cheaper. Never used
/// to pick targets.
enum TextRecognizer {
    struct Line: Sendable {
        let text: String
        /// Screenshot pixel coordinates (origin top-left).
        let frame: CGRect
    }

    /// All text lines on the screen.
    ///
    /// Reading the Korean keyboard layout needs `accurate` level (`fast` only reads Latin script).
    /// About 0.3–0.6 s for one 1290×2796 image on Apple Silicon.
    static func lines(in image: CGImage, languages: [String] = ["ko-KR", "en-US"]) throws -> [Line] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])

        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        return (request.results ?? []).compactMap { observation -> Line? in
            guard let best = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            // Vision's normalized coordinates (origin bottom-left) -> pixel coordinates (origin top-left).
            return Line(
                text: best.string,
                frame: CGRect(
                    x: box.minX * width, y: (1 - box.maxY) * height,
                    width: box.width * width, height: box.height * height))
        }
    }

    /// The top edge (pixel y) of the on-screen keyboard if it's up, otherwise nil.
    ///
    /// OCR picks up keyboard keys as single-character lines like "Q", "W" or a single Hangul jamo, several per row. The first
    /// row with more than four single-character lines side by side is taken as the top key row, and we move
    /// up further by the suggestion bar / toolbar allowance (14% of screen height). Once, with the keyboard up,
    /// a `scroll` in the middle of the screen landed its swipe on the keys and typed "G" into a search field.
    static func keyboardTop(in lines: [Line], height: CGFloat) -> CGFloat? {
        let keys = lines.filter {
            $0.text.trimmingCharacters(in: .whitespaces).count == 1 && $0.frame.midY > height * 0.35
        }
        guard keys.count >= 10 else { return nil }
        let sorted = keys.sorted { $0.frame.midY < $1.frame.midY }
        for key in sorted {
            let row = sorted.filter { abs($0.frame.midY - key.frame.midY) < height * 0.015 }
            if row.count >= 4 { return max(height * 0.2, key.frame.minY - height * 0.14) }
        }
        return nil
    }

    /// Is the on-screen keyboard up? Looser than `keyboardTop` — layouts with only three keys per row,
    /// like the number pad, still count as a keyboard if more than ten single-character lines cluster near
    /// the bottom of the screen.
    static func keyboardVisible(in lines: [Line], height: CGFloat) -> Bool {
        if keyboardTop(in: lines, height: height) != nil { return true }
        let keys = lines.filter {
            $0.text.trimmingCharacters(in: .whitespaces).count == 1 && $0.frame.midY > height * 0.45
        }
        return keys.count >= 10
    }
}
