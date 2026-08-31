import CoreGraphics
import Vision

struct DetectedQRCode: Identifiable, Equatable {
    let id = UUID()
    let value: String
    let boundingBox: CGRect

    var url: URL? {
        guard let url = URL(string: value),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else { return nil }
        return url
    }
}

final class QRCodeDetector {
    func detect(in image: CGImage) async -> [DetectedQRCode] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNDetectBarcodesRequest()
                request.symbologies = [.qr]
                do {
                    try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
                    let values = (request.results ?? []).compactMap { observation -> DetectedQRCode? in
                        guard let payload = observation.payloadStringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !payload.isEmpty else { return nil }
                        return DetectedQRCode(value: payload, boundingBox: observation.boundingBox)
                    }
                    var seen = Set<String>()
                    continuation.resume(returning: values.filter { seen.insert($0.value).inserted })
                } catch {
                    continuation.resume(returning: [])
                }
            }
        }
    }
}
