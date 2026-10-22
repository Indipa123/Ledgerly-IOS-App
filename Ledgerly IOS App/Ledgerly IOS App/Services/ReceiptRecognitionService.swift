import Foundation
import Vision

enum ReceiptRecognitionService {
    static func recognize(_ imagePages: [Data]) async throws -> ReceiptSuggestions {
        try await Task.detached(priority: .userInitiated) {
            var lines: [String] = []
            for imageData in imagePages {
                try Task.checkCancellation()
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                try VNImageRequestHandler(data: imageData).perform([request])
                if !lines.isEmpty { lines.append("--- Receipt page ---") }
                lines += (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            }
            return ReceiptTextParser.parse(lines)
        }.value
    }
}
