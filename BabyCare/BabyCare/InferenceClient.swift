import Foundation

protocol InferenceClient {
    func infer(from capture: CaptureEnvelope) async throws -> InferenceResult
}

struct MockInferenceClient: InferenceClient {
    private let confidenceThreshold: Double

    init(confidenceThreshold: Double = 0.75) {
        self.confidenceThreshold = confidenceThreshold
    }

    func infer(from capture: CaptureEnvelope) async throws -> InferenceResult {
        let data = try Data(contentsOf: capture.localMediaURL)
        let bucket = data.count % ActivityLabel.allCases.count
        let label = ActivityLabel.allCases[bucket]

        let normalized = Double((data.count % 40) + 55) / 100.0
        let confidence = min(max(normalized, 0.0), 1.0)
        let rationale = confidence < confidenceThreshold
            ? "Low confidence heuristic classification."
            : "Mock classification from media-size heuristic."

        return InferenceResult(
            label: label,
            confidence: confidence,
            rationaleShort: rationale,
            modelVersion: "mock-v1",
            feedingAmountOz: nil,
            mentionedEventTime: nil
        )
    }
}
