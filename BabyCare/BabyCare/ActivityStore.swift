import Foundation
import SwiftData

protocol ActivityStore {
    func saveEvent(from capture: CaptureEnvelope, inference: InferenceResult) throws
}

@MainActor
final class SwiftDataActivityStore: ActivityStore {
    private let modelContext: ModelContext
    private let confidenceThreshold: Double

    init(modelContext: ModelContext, confidenceThreshold: Double = 0.75) {
        self.modelContext = modelContext
        self.confidenceThreshold = confidenceThreshold
    }

    func saveEvent(from capture: CaptureEnvelope, inference: InferenceResult) throws {
        let frameCount = capture.metadata["frameCount"].flatMap(Int.init)
        let eventTimestamp = inference.mentionedEventTime?.resolvedDate(relativeTo: capture.capturedAt)
            ?? capture.capturedAt
        let event = ActivityEventRecord(
            label: inference.label,
            timestamp: eventTimestamp,
            sourceCaptureId: capture.id,
            confidence: inference.confidence,
            needsReview: inference.confidence < confidenceThreshold,
            rationaleShort: inference.rationaleShort,
            modelVersion: inference.modelVersion,
            frameCount: frameCount,
            inferredFeedingAmountOz: inference.feedingAmountOz,
            diaperChangeValue: {
                switch inference.label {
                case .diaperWet:
                    return .wet
                case .diaperBowel:
                    return .bm
                default:
                    return nil
                }
            }()
        )
        modelContext.insert(event)
        try modelContext.save()
    }
}
