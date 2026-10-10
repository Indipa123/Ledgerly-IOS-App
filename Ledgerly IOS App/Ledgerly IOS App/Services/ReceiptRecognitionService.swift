import Foundation
import Vision

enum ReceiptRecognitionService {
    static func recognize(_ imageData: Data) async throws -> ReceiptSuggestions {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(data: imageData)
            try handler.perform([request])
            let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
            return ReceiptTextParser.parse(lines)
        }.value
    }
}
