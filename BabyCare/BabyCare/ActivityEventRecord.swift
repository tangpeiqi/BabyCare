import Foundation
import SwiftData

@Model
final class ActivityEventRecord {
    var id: UUID
    var labelRawValue: String
    var timestamp: Date
    var sourceCaptureId: UUID
    var confidence: Double
    var needsReview: Bool
    var isUserCorrected: Bool
    var isDeleted: Bool
    var rationaleShort: String
    var modelVersion: String
    var frameCount: Int?
    var feedingAmountOz: Double?
    var inferredFeedingAmountOz: Double?
    var diaperChangeValueRawValue: String?

    init(
        id: UUID = UUID(),
        label: ActivityLabel,
        timestamp: Date,
        sourceCaptureId: UUID,
        confidence: Double,
        needsReview: Bool,
        isUserCorrected: Bool = false,
        isDeleted: Bool = false,
        rationaleShort: String,
        modelVersion: String,
        frameCount: Int? = nil,
        feedingAmountOz: Double? = nil,
        inferredFeedingAmountOz: Double? = nil,
        diaperChangeValue: DiaperChangeValue? = nil
    ) {
        self.id = id
        self.labelRawValue = label.rawValue
        self.timestamp = timestamp
        self.sourceCaptureId = sourceCaptureId
        self.confidence = confidence
        self.needsReview = needsReview
        self.isUserCorrected = isUserCorrected
        self.isDeleted = isDeleted
        self.rationaleShort = rationaleShort
        self.modelVersion = modelVersion
        self.frameCount = frameCount
        self.feedingAmountOz = feedingAmountOz
        self.inferredFeedingAmountOz = inferredFeedingAmountOz
        self.diaperChangeValueRawValue = diaperChangeValue?.rawValue
    }

    var label: ActivityLabel {
        get { ActivityLabel(rawValue: labelRawValue) ?? .other }
        set { labelRawValue = newValue.rawValue }
    }

    var diaperChangeValue: DiaperChangeValue? {
        get { diaperChangeValueRawValue.flatMap(DiaperChangeValue.init(rawValue:)) }
        set { diaperChangeValueRawValue = newValue?.rawValue }
    }
}
