import AppKit
import Foundation
import Vision

enum TextRecognizerError: Error {
    case imageLoadFailed(URL)
    case visionFailed(String)
}

/// Apple Vision wrapper. Reads a PNG (or any CGImage-compatible file) and
/// returns line-level observations. Stays a thin shim over `VNRecognizeTextRequest`
/// so the post-processor stays the only place that knows about line-break
/// semantics.
struct TextRecognizer {

    let recognitionLevel: VNRequestTextRecognitionLevel
    let usesLanguageCorrection: Bool
    let recognitionLanguages: [String]    // empty = auto
    let autoDetectLanguage: Bool

    init(recognitionLevel: VNRequestTextRecognitionLevel = .accurate,
         usesLanguageCorrection: Bool = true,
         recognitionLanguages: [String] = [],
         autoDetectLanguage: Bool = false) {
        self.recognitionLevel = recognitionLevel
        self.usesLanguageCorrection = usesLanguageCorrection
        self.recognitionLanguages = recognitionLanguages
        self.autoDetectLanguage = autoDetectLanguage
    }

    /// Reads the image, runs Vision off-MainActor, returns observations.
    func recognize(_ imageURL: URL) async throws -> [LineObservation] {
        let cgImage = try Self.loadCGImage(from: imageURL)
        return try await Task.detached(priority: .userInitiated) {
            try Self.runRequest(
                on: cgImage,
                level: self.recognitionLevel,
                useCorrection: self.usesLanguageCorrection,
                languages: self.recognitionLanguages,
                autoDetect: self.autoDetectLanguage
            )
        }.value
    }

    // MARK: - Private

    private static func loadCGImage(from url: URL) throws -> CGImage {
        guard let data = try? Data(contentsOf: url),
              let rep = NSBitmapImageRep(data: data),
              let cg = rep.cgImage else {
            throw TextRecognizerError.imageLoadFailed(url)
        }
        return cg
    }

    private static func runRequest(on image: CGImage,
                                    level: VNRequestTextRecognitionLevel,
                                    useCorrection: Bool,
                                    languages: [String],
                                    autoDetect: Bool) throws -> [LineObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = useCorrection
        if autoDetect {
            // Empty array tells Vision to auto-detect.
            request.recognitionLanguages = []
            if #available(macOS 13.0, *) {
                request.automaticallyDetectsLanguage = true
            }
        } else if !languages.isEmpty {
            request.recognitionLanguages = languages
            if #available(macOS 13.0, *) {
                request.automaticallyDetectsLanguage = false
            }
        }

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw TextRecognizerError.visionFailed(error.localizedDescription)
        }

        let results = (request.results ?? [])
        return results.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            return LineObservation(
                text: candidate.string,
                confidence: candidate.confidence,
                boundingBox: obs.boundingBox
            )
        }
    }
}
