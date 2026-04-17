import Foundation

@MainActor
final class ActivityPipeline {
    private let inferenceClient: InferenceClient
    private let store: ActivityStore
    private let maxInferenceAttempts: Int

    init(
        inferenceClient: InferenceClient,
        store: ActivityStore,
        maxInferenceAttempts: Int = 3
    ) {
        self.inferenceClient = inferenceClient
        self.store = store
        self.maxInferenceAttempts = max(1, maxInferenceAttempts)
    }

    func processPhotoCapture(photoData: Data, capturedAt: Date) async throws -> InferenceResult {
        let fileURL = try persistCaptureData(photoData, ext: "jpg")
        let capture = CaptureEnvelope(
            id: UUID(),
            captureType: .photo,
            capturedAt: capturedAt,
            deviceId: nil,
            localMediaURL: fileURL,
            metadata: ["source": "mwdat_photo"]
        )
        let inference = try await inferWithRetry(from: capture)
        try store.saveEvent(from: capture, inference: inference)
        return inference
    }

    func processVideoSegment(
        manifestURL: URL,
        capturedAt: Date,
        metadata: [String: String]
    ) async throws -> InferenceResult {
        let capture = CaptureEnvelope(
            id: UUID(),
            captureType: .shortVideo,
            capturedAt: capturedAt,
            deviceId: nil,
            localMediaURL: manifestURL,
            metadata: metadata
        )
        let inference = try await inferWithRetry(from: capture)
        try store.saveEvent(from: capture, inference: inference)
        return inference
    }

    private func persistCaptureData(_ data: Data, ext: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoLCaptures", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func inferWithRetry(from capture: CaptureEnvelope) async throws -> InferenceResult {
        var attempt = 1
        var lastError: Error?

        while attempt <= maxInferenceAttempts {
            do {
                return try await inferenceClient.infer(from: capture)
            } catch {
                lastError = error
                if attempt == maxInferenceAttempts {
                    break
                }

                let backoffNanoseconds = UInt64(pow(2.0, Double(attempt - 1)) * 500_000_000)
                try await Task.sleep(nanoseconds: backoffNanoseconds)
                attempt += 1
            }
        }

        throw lastError ?? NSError(
            domain: "ActivityPipeline",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Inference failed after retries."]
        )
    }
}
