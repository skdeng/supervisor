import Foundation
import ImageIO
import Vision

enum ScreenshotTextRecognitionError: LocalizedError {
    case unsupportedImage
    case imageTooLarge
    case noText

    var errorDescription: String? {
        switch self {
        case .unsupportedImage:
            return "This file could not be read for text recognition."
        case .imageTooLarge:
            return "This file is too large to analyze safely."
        case .noText:
            return "No readable text was found."
        }
    }
}

/// Runs Vision OCR away from the main actor. Only the resulting `String` crosses the task
/// boundary; Image I/O and Vision objects stay confined to the detached worker.
enum ScreenshotTextRecognizer {
    private static let maximumPixelCount: Int64 = 120_000_000

    static func recognizeText(at url: URL) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                    as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber
            else {
                throw ScreenshotTextRecognitionError.unsupportedImage
            }

            let pixelCount = width.int64Value.multipliedReportingOverflow(by: height.int64Value)
            guard !pixelCount.overflow,
                  pixelCount.partialValue > 0,
                  pixelCount.partialValue <= maximumPixelCount
            else {
                throw ScreenshotTextRecognitionError.imageTooLarge
            }

            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(url: url, options: [:])
            try handler.perform([request])

            let text = (request.results ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                throw ScreenshotTextRecognitionError.noText
            }
            return text
        }.value
    }
}
