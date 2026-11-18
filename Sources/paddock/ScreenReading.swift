import CoreGraphics
import Foundation
import PaddockCore
import Vision

/// Reading the guest's screen on the host, for the steps paddock clicks through itself:
/// Setup Assistant with `build --accept-macos-license`, and macOS Recovery for `grant`.
extension HeadlessVM {
    /// The lines of text Vision recognizes on the guest's screen now, and the screen's size.
    func readScreen() async throws -> (lines: [ScreenText], size: CGSize) {
        let image = try await screenshot()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        let width = CGFloat(image.width), height = CGFloat(image.height)
        let lines = (request.results ?? []).compactMap { observation -> ScreenText? in
            guard let string = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox  // normalized, from the bottom left
            return ScreenText(string, CGRect(
                x: box.minX * width, y: (1 - box.maxY) * height, width: box.width * width, height: box.height * height))
        }
        return (lines, CGSize(width: width, height: height))
    }

    /// Saves what the guest's screen shows to `$TMPDIR/<file>.png`, when a step fails, and says where.
    func saveScreen(as file: String) async {
        guard let image = try? await screenshot() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(file).png")
        if (try? FrameImage.writePNG(image, to: url)) != nil {
            print("  the guest's screen when it failed: \(url.path)")
        }
    }
}
