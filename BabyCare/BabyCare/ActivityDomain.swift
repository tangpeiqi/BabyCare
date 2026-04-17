import Foundation

enum ActivityLabel: String, CaseIterable, Codable, Identifiable {
    case diaperWet
    case diaperBowel
    case feeding
    case sleepStart
    case wakeUp
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .diaperWet: return "Diaper (Wet)"
        case .diaperBowel: return "Diaper (Bowel)"
        case .feeding: return "Feeding"
        case .sleepStart: return "Baby Asleep"
        case .wakeUp: return "Baby Wakes Up"
        case .other: return "Other"
        }
    }
}

enum DiaperChangeValue: String, CaseIterable, Codable, Identifiable {
    case wet
    case bm
    case dry

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wet: return "Wet"
        case .bm: return "BM"
        case .dry: return "Dry"
        }
    }
}

enum CaptureType: String, Codable {
    case photo
    case shortVideo
    case audioSnippet
}

struct CaptureEnvelope: Sendable {
    let id: UUID
    let captureType: CaptureType
    let capturedAt: Date
    let deviceId: String?
    let localMediaURL: URL
    let metadata: [String: String]
}

struct InferenceResult: Sendable {
    let label: ActivityLabel
    let confidence: Double
    let rationaleShort: String
    let modelVersion: String
    let feedingAmountOz: Double?
    let mentionedEventTime: MentionedEventTime?
}

struct MentionedEventTime: Sendable {
    let hour: Int?
    let minute: Int?
    let dayOffset: Int

    init?(hour: Int?, minute: Int?, dayOffset: Int = 0) {
        if let hour, !(0...23).contains(hour) {
            return nil
        }
        if let minute, !(0...59).contains(minute) {
            return nil
        }
        guard (-7...7).contains(dayOffset) else { return nil }
        guard (hour == nil) == (minute == nil) else { return nil }
        guard hour != nil || dayOffset != 0 else { return nil }
        self.hour = hour
        self.minute = minute
        self.dayOffset = dayOffset
    }

    func resolvedDate(relativeTo recordingDate: Date, calendar: Calendar = .current) -> Date? {
        let baseDate = calendar.date(byAdding: .day, value: dayOffset, to: recordingDate) ?? recordingDate
        let baseTime = calendar.dateComponents([.hour, .minute], from: recordingDate)
        var components = calendar.dateComponents([.year, .month, .day], from: baseDate)
        components.hour = hour ?? baseTime.hour
        components.minute = minute ?? baseTime.minute
        components.second = 0

        guard var candidate = calendar.date(from: components) else {
            return nil
        }

        // If only a clock time was mentioned, keep the previous "most recent occurrence"
        // behavior so future-dated same-day times resolve to the prior day.
        if dayOffset == 0, hour != nil, minute != nil, candidate > recordingDate {
            candidate = calendar.date(byAdding: .day, value: -1, to: candidate) ?? candidate
        }

        return candidate
    }
}
