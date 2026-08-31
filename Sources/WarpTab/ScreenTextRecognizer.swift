import CoreGraphics
import Vision

struct ScreenTextRecognition {
    let text: String
    let fragmentCount: Int
}

enum ScreenTextRecognizerError: Error {
    case recognitionFailed
}

final class ScreenTextRecognizer {
    func recognize(in image: CGImage) async throws -> ScreenTextRecognition {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                request.minimumTextHeight = 0.008
                do {
                    try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
                    let observations = request.results ?? []
                    let ordered = Self.readingOrder(observations)
                    let lines = ordered.compactMap { $0.topCandidates(1).first?.string }
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    continuation.resume(returning: ScreenTextRecognition(
                        text: lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
                        fragmentCount: lines.count
                    ))
                } catch {
                    continuation.resume(throwing: ScreenTextRecognizerError.recognitionFailed)
                }
            }
        }
    }

    private static func readingOrder(_ observations: [VNRecognizedTextObservation]) -> [VNRecognizedTextObservation] {
        let topToBottom = observations.sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        var rows: [[VNRecognizedTextObservation]] = []
        for observation in topToBottom {
            if let index = rows.firstIndex(where: { row in
                guard let anchor = row.first else { return false }
                let tolerance = max(anchor.boundingBox.height, observation.boundingBox.height) * 0.55
                return abs(anchor.boundingBox.midY - observation.boundingBox.midY) <= tolerance
            }) {
                rows[index].append(observation)
            } else {
                rows.append([observation])
            }
        }
        return rows.flatMap { $0.sorted { $0.boundingBox.minX < $1.boundingBox.minX } }
    }
}
