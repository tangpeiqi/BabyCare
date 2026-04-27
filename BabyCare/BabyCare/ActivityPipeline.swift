import Foundation

@MainActor
final class ActivityPipeline {
    private enum SegmentInferenceMode: String {
        case transcriptOnly = "transcript_only"
        case imageOnly = "image_only"
    }

    private let inferenceClient: InferenceClient
    private let store: ActivityStore
    private let maxInferenceAttempts: Int
    private let requestGate: InferenceRequestGate
    private let transcriptHeuristicClassifier = LocalTranscriptHeuristicClassifier()

    init(
        inferenceClient: InferenceClient,
        store: ActivityStore,
        maxInferenceAttempts: Int = 2,
        requestGate: InferenceRequestGate = InferenceRequestGate()
    ) {
        self.inferenceClient = inferenceClient
        self.store = store
        self.maxInferenceAttempts = max(1, maxInferenceAttempts)
        self.requestGate = requestGate
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
        if let heuristicInference = try localTranscriptHeuristicInference(from: capture) {
            try store.saveEvent(from: capture, inference: heuristicInference)
            return heuristicInference
        }

        let transcript = try loadSegmentTranscript(from: manifestURL)
        let heuristicSnapshot = transcriptHeuristicClassifier.inspect(transcript: transcript)

        let inference: InferenceResult
        if heuristicSnapshot.transcriptMeaningful {
            let transcriptCapture = capture.withMetadataValue(
                SegmentInferenceMode.transcriptOnly.rawValue,
                forKey: "inferenceMode"
            )
            let transcriptInference = try await inferWithRetry(
                from: transcriptCapture,
                useSuccessCooldown: false
            )
            if transcriptInference.label != .other {
                await requestGate.noteSuccessfulInference()
                inference = transcriptInference
            } else {
                let imageCapture = capture.withMetadataValue(
                    SegmentInferenceMode.imageOnly.rawValue,
                    forKey: "inferenceMode"
                )
                inference = try await inferWithRetry(from: imageCapture)
            }
        } else {
            let imageCapture = capture.withMetadataValue(
                SegmentInferenceMode.imageOnly.rawValue,
                forKey: "inferenceMode"
            )
            inference = try await inferWithRetry(from: imageCapture)
        }

        try store.saveEvent(from: capture, inference: inference)
        return inference
    }

    func requestGateSnapshot() async -> InferenceRequestGateSnapshot {
        await requestGate.snapshot()
    }

    func localTranscriptHeuristicSnapshot(
        manifestURL: URL,
        recordingDate: Date
    ) throws -> LocalTranscriptHeuristicSnapshot {
        let transcript = try loadSegmentTranscript(from: manifestURL)
        return transcriptHeuristicClassifier.inspect(
            transcript: transcript,
            recordingDate: recordingDate
        )
    }

    private func persistCaptureData(_ data: Data, ext: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PoLCaptures", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fileURL = dir.appendingPathComponent("\(UUID().uuidString).\(ext)")
        try data.write(to: fileURL, options: .atomic)
        return fileURL
    }

    private func inferWithRetry(
        from capture: CaptureEnvelope,
        useSuccessCooldown: Bool = true
    ) async throws -> InferenceResult {
        try await requestGate.waitForTurn()

        do {
            let inference = try await performInferenceWithRetry(from: capture)
            if useSuccessCooldown {
                await requestGate.markSuccess()
            }
            await requestGate.finish(useSuccessCooldown: useSuccessCooldown)
            return inference
        } catch {
            await requestGate.finish(cooldownSeconds: cooldownSeconds(after: error))
            throw error
        }
    }

    private func performInferenceWithRetry(from capture: CaptureEnvelope) async throws -> InferenceResult {
        var attempt = 1
        var lastError: Error?

        while attempt <= maxInferenceAttempts {
            do {
                return try await inferenceClient.infer(from: capture)
            } catch {
                lastError = error
                if attempt == maxInferenceAttempts || !shouldRetry(error) {
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

    private func shouldRetry(_ error: Error) -> Bool {
        if let geminiError = error as? GeminiInferenceError {
            return geminiError.isRetryableHTTPError
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
    }

    private func cooldownSeconds(after error: Error) -> TimeInterval? {
        guard let geminiError = error as? GeminiInferenceError, geminiError.isRateLimitError else {
            return nil
        }
        return max(geminiError.retryAfterSeconds ?? 60, 60)
    }

    private func localTranscriptHeuristicInference(from capture: CaptureEnvelope) throws -> InferenceResult? {
        guard capture.captureType == .shortVideo else { return nil }
        guard let transcript = try loadSegmentTranscript(from: capture.localMediaURL) else { return nil }
        return transcriptHeuristicClassifier.classify(
            transcript: transcript,
            recordingDate: capture.capturedAt
        )
    }

    private func loadSegmentTranscript(from manifestURL: URL) throws -> String? {
        let manifestData = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(SegmentTranscriptManifest.self, from: manifestData)
        let transcript = manifest.audio.transcript?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let transcript, !transcript.isEmpty else {
            return nil
        }
        return transcript
    }
}

private extension CaptureEnvelope {
    func withMetadataValue(_ value: String, forKey key: String) -> CaptureEnvelope {
        var updatedMetadata = metadata
        updatedMetadata[key] = value
        return CaptureEnvelope(
            id: id,
            captureType: captureType,
            capturedAt: capturedAt,
            deviceId: deviceId,
            localMediaURL: localMediaURL,
            metadata: updatedMetadata
        )
    }
}

private struct SegmentTranscriptManifest: Decodable {
    struct AudioDescriptor: Decodable {
        let transcript: String?
    }

    let audio: AudioDescriptor
}

private struct LocalTranscriptHeuristicClassifier {
    private let fillerWords: Set<String> = [
        "a", "ah", "an", "and", "baby", "care", "for", "hey", "hmm", "i", "just",
        "like", "mm", "mmm", "now", "oh", "okay", "please", "so", "the", "uh",
        "uhh", "um", "umm", "well", "yeah", "yep"
    ]

    private let meaningfulKeywords: Set<String> = [
        "awake", "asleep", "ate", "bottle", "bowel", "diaper", "dirty", "fed",
        "feeding", "fell", "milk", "ounce", "ounces", "oz", "poop", "pooped",
        "sleep", "slept", "wake", "woke", "wet"
    ]

    func inspect(
        transcript rawTranscript: String?,
        recordingDate: Date? = nil
    ) -> LocalTranscriptHeuristicSnapshot {
        guard let rawTranscript else {
            return .init(
                transcriptPresent: false,
                transcriptMeaningful: false,
                matchedLabels: [],
                selectedLabel: nil,
                feedingAmountOz: nil,
                mentionedEventTime: nil,
                timeExpressionDetected: false,
                timeExpressionResolved: false
            )
        }

        let normalized = normalize(rawTranscript)
        let meaningful = isMeaningful(normalized)
        let feedingAmountOz = extractFeedingAmountOz(from: normalized)
        let timeExpressionDetected = containsTimeExpression(in: normalized)
        let mentionedEventTime = recordingDate.flatMap {
            parseMentionedEventTime(in: normalized, relativeTo: $0)
        }
        let matchedLabels = Array(matchedLabels(in: normalized, feedingAmountOz: feedingAmountOz))
            .sorted { $0.rawValue < $1.rawValue }
        let selectedLabel = matchedLabels.count == 1 && meaningful ? matchedLabels.first : nil

        return .init(
            transcriptPresent: true,
            transcriptMeaningful: meaningful,
            matchedLabels: matchedLabels,
            selectedLabel: selectedLabel,
            feedingAmountOz: feedingAmountOz,
            mentionedEventTime: mentionedEventTime,
            timeExpressionDetected: timeExpressionDetected,
            timeExpressionResolved: mentionedEventTime != nil
        )
    }

    func classify(transcript: String, recordingDate: Date) -> InferenceResult? {
        let snapshot = inspect(transcript: transcript, recordingDate: recordingDate)
        guard snapshot.transcriptMeaningful,
              let label = snapshot.selectedLabel
        else {
            return nil
        }

        // If we noticed time language but could not confidently resolve it locally,
        // defer to the transcript-only Gemini path instead of saving with "now".
        if snapshot.timeExpressionDetected, !snapshot.timeExpressionResolved {
            return nil
        }

        return InferenceResult(
            label: label,
            confidence: 0.99,
            rationaleShort: snapshot.mentionedEventTime == nil
                ? "Local transcript heuristic matched explicit activity phrase."
                : "Local transcript heuristic matched explicit activity phrase and resolved mentioned time.",
            modelVersion: "local-transcript-heuristic-v2",
            feedingAmountOz: label == .feeding ? snapshot.feedingAmountOz : nil,
            mentionedEventTime: snapshot.mentionedEventTime
        )
    }

    private func normalize(_ transcript: String) -> String {
        transcript
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9\\s:\\.]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func isMeaningful(_ transcript: String) -> Bool {
        let tokens = transcript
            .split(separator: " ")
            .map(String.init)
            .filter { !fillerWords.contains($0) }
        guard tokens.count >= 2 else {
            return false
        }

        return tokens.contains(where: { meaningfulKeywords.contains($0) || $0.rangeOfCharacter(from: .decimalDigits) != nil })
    }

    private func matchedLabels(in transcript: String, feedingAmountOz: Double?) -> Set<ActivityLabel> {
        var labels: Set<ActivityLabel> = []

        if containsAnyPhrase(in: transcript, phrases: [
            "wet diaper", "diaper was wet", "diaper is wet", "really wet", "super wet"
        ]) {
            labels.insert(.diaperWet)
        }

        if containsAnyPhrase(in: transcript, phrases: [
            "poop", "pooped", "poopy diaper", "bowel movement", "dirty diaper", "bm diaper"
        ]) {
            labels.insert(.diaperBowel)
        }

        if feedingAmountOz != nil || containsAnyPhrase(in: transcript, phrases: [
            "fed", "feeding", "bottle", "drank milk", "finished bottle"
        ]) {
            labels.insert(.feeding)
        }

        if containsAnyPhrase(in: transcript, phrases: [
            "fell asleep", "went to sleep", "is asleep", "baby asleep", "asleep now"
        ]) {
            labels.insert(.sleepStart)
        }

        if containsAnyPhrase(in: transcript, phrases: [
            "woke up", "wake up", "is awake", "baby awake", "awake now"
        ]) {
            labels.insert(.wakeUp)
        }

        return labels
    }

    private func containsAnyPhrase(in transcript: String, phrases: [String]) -> Bool {
        phrases.contains { transcript.contains($0) }
    }

    private func extractFeedingAmountOz(from transcript: String) -> Double? {
        let patterns = [
            #"(\d+(?:\.\d+)?)\s*(?:oz|ounce|ounces)\b"#,
            #"(\d+(?:\.\d+)?)\s*(?:o z)\b"#
        ]

        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                continue
            }
            let range = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
            guard let match = regex.firstMatch(in: transcript, options: [], range: range),
                  match.numberOfRanges > 1,
                  let amountRange = Range(match.range(at: 1), in: transcript)
            else {
                continue
            }
            return Double(transcript[amountRange])
        }

        return nil
    }

    private func containsTimeExpression(in transcript: String) -> Bool {
        if containsAnyPhrase(in: transcript, phrases: [
            "ago", "today", "yesterday", "last night", "tonight",
            "this morning", "this afternoon", "this evening", "just now"
        ]) {
            return true
        }

        let patterns = [
            #"\b\d{1,2}:\d{2}\s*(?:a\.?m\.?|p\.?m\.?)\b"#,
            #"\b\d{1,2}\s*(?:a\.?m\.?|p\.?m\.?)\b"#
        ]

        return patterns.contains { pattern in
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                return false
            }
            let range = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
            return regex.firstMatch(in: transcript, options: [], range: range) != nil
        }
    }

    private func parseMentionedEventTime(
        in transcript: String,
        relativeTo recordingDate: Date,
        calendar: Calendar = .current
    ) -> MentionedEventTime? {
        if let relativeMatch = parseRelativeMentionedEventTime(
            in: transcript,
            relativeTo: recordingDate,
            calendar: calendar
        ) {
            return relativeMatch
        }

        return parseExplicitClockMentionedEventTime(
            in: transcript,
            relativeTo: recordingDate,
            calendar: calendar
        )
    }

    private func parseRelativeMentionedEventTime(
        in transcript: String,
        relativeTo recordingDate: Date,
        calendar: Calendar
    ) -> MentionedEventTime? {
        if containsAnyPhrase(in: transcript, phrases: ["just now"]) {
            return dateRelativeTime(
                recordingDate,
                adjustedBy: DateComponents(second: 0),
                calendar: calendar
            )
        }

        if containsAnyPhrase(in: transcript, phrases: ["half an hour ago", "half hour ago"]) {
            return dateRelativeTime(
                recordingDate,
                adjustedBy: DateComponents(minute: -30),
                calendar: calendar
            )
        }

        if let minutesAgo = firstIntegerMatch(
            in: transcript,
            patterns: [#"(\d+)\s*(?:minute|minutes|min|mins)\s+ago\b"#]
        ) {
            return dateRelativeTime(
                recordingDate,
                adjustedBy: DateComponents(minute: -minutesAgo),
                calendar: calendar
            )
        }

        if containsAnyPhrase(in: transcript, phrases: ["an hour ago", "a hour ago", "one hour ago"]) {
            return dateRelativeTime(
                recordingDate,
                adjustedBy: DateComponents(hour: -1),
                calendar: calendar
            )
        }

        if let hoursAgo = firstIntegerMatch(
            in: transcript,
            patterns: [#"(\d+)\s*(?:hour|hours|hr|hrs)\s+ago\b"#]
        ) {
            return dateRelativeTime(
                recordingDate,
                adjustedBy: DateComponents(hour: -hoursAgo),
                calendar: calendar
            )
        }

        return nil
    }

    private func parseExplicitClockMentionedEventTime(
        in transcript: String,
        relativeTo recordingDate: Date,
        calendar: Calendar
    ) -> MentionedEventTime? {
        let dayOffset = explicitDayOffset(in: transcript)

        if let components = firstClockComponents(
            in: transcript,
            patterns: [
                #"\b(\d{1,2}):(\d{2})\s*(a\.?m\.?|p\.?m\.?)\b"#,
                #"\b(\d{1,2})\s*(a\.?m\.?|p\.?m\.?)\b"#
            ]
        ) {
            return MentionedEventTime(
                hour: components.hour,
                minute: components.minute,
                dayOffset: dayOffset
            )
        }

        // If time language is present but we cannot confidently parse the clock,
        // let Gemini handle it via the transcript-only path.
        if containsAnyPhrase(in: transcript, phrases: [
            "today", "yesterday", "last night", "tonight",
            "this morning", "this afternoon", "this evening"
        ]) {
            return nil
        }

        return nil
    }

    private func explicitDayOffset(in transcript: String) -> Int {
        if containsAnyPhrase(in: transcript, phrases: ["yesterday", "last night"]) {
            return -1
        }
        return 0
    }

    private func dateRelativeTime(
        _ recordingDate: Date,
        adjustedBy components: DateComponents,
        calendar: Calendar
    ) -> MentionedEventTime? {
        guard let resolvedDate = calendar.date(byAdding: components, to: recordingDate) else {
            return nil
        }

        let recordingStart = calendar.startOfDay(for: recordingDate)
        let resolvedStart = calendar.startOfDay(for: resolvedDate)
        let dayOffset = calendar.dateComponents([.day], from: recordingStart, to: resolvedStart).day ?? 0
        let time = calendar.dateComponents([.hour, .minute], from: resolvedDate)

        return MentionedEventTime(
            hour: time.hour,
            minute: time.minute,
            dayOffset: dayOffset
        )
    }

    private func firstIntegerMatch(in transcript: String, patterns: [String]) -> Int? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                continue
            }
            let range = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
            guard let match = regex.firstMatch(in: transcript, options: [], range: range),
                  match.numberOfRanges > 1,
                  let valueRange = Range(match.range(at: 1), in: transcript),
                  let value = Int(transcript[valueRange])
            else {
                continue
            }
            return value
        }
        return nil
    }

    private func firstClockComponents(
        in transcript: String,
        patterns: [String]
    ) -> (hour: Int, minute: Int)? {
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
                continue
            }
            let range = NSRange(transcript.startIndex..<transcript.endIndex, in: transcript)
            guard let match = regex.firstMatch(in: transcript, options: [], range: range) else {
                continue
            }

            if match.numberOfRanges == 4,
               let hourRange = Range(match.range(at: 1), in: transcript),
               let minuteRange = Range(match.range(at: 2), in: transcript),
               let meridiemRange = Range(match.range(at: 3), in: transcript),
               let hour12 = Int(transcript[hourRange]),
               let minute = Int(transcript[minuteRange]),
               let hour24 = to24Hour(hour12: hour12, meridiem: String(transcript[meridiemRange]))
            {
                return (hour24, minute)
            }

            if match.numberOfRanges == 3,
               let hourRange = Range(match.range(at: 1), in: transcript),
               let meridiemRange = Range(match.range(at: 2), in: transcript),
               let hour12 = Int(transcript[hourRange]),
               let hour24 = to24Hour(hour12: hour12, meridiem: String(transcript[meridiemRange]))
            {
                return (hour24, 0)
            }
        }
        return nil
    }

    private func to24Hour(hour12: Int, meridiem: String) -> Int? {
        guard (1...12).contains(hour12) else { return nil }
        let normalizedMeridiem = meridiem.replacingOccurrences(of: ".", with: "")
        switch normalizedMeridiem {
        case "am":
            return hour12 == 12 ? 0 : hour12
        case "pm":
            return hour12 == 12 ? 12 : hour12 + 12
        default:
            return nil
        }
    }
}

struct LocalTranscriptHeuristicSnapshot: Sendable {
    let transcriptPresent: Bool
    let transcriptMeaningful: Bool
    let matchedLabels: [ActivityLabel]
    let selectedLabel: ActivityLabel?
    let feedingAmountOz: Double?
    let mentionedEventTime: MentionedEventTime?
    let timeExpressionDetected: Bool
    let timeExpressionResolved: Bool
}

struct InferenceRequestGateSnapshot: Sendable {
    let isRunning: Bool
    let nextAvailableAt: Date
    let lastSuccessAt: Date?

    func secondsUntilNextAvailable(referenceDate: Date = Date()) -> TimeInterval {
        max(0, nextAvailableAt.timeIntervalSince(referenceDate))
    }

    func secondsSinceLastSuccess(referenceDate: Date = Date()) -> TimeInterval? {
        lastSuccessAt.map { max(0, referenceDate.timeIntervalSince($0)) }
    }
}

actor InferenceRequestGate {
    private let minSpacingSeconds: TimeInterval
    private let successCooldownSeconds: TimeInterval
    private var isRunning: Bool = false
    private var nextAvailableAt: Date = .distantPast
    private var lastSuccessAt: Date?

    init(
        minSpacingSeconds: TimeInterval = 1.5,
        successCooldownSeconds: TimeInterval = 30
    ) {
        self.minSpacingSeconds = minSpacingSeconds
        self.successCooldownSeconds = successCooldownSeconds
    }

    func waitForTurn() async throws {
        while true {
            let now = Date()
            if !isRunning, now >= nextAvailableAt {
                isRunning = true
                return
            }

            let waitSeconds: TimeInterval
            if isRunning {
                waitSeconds = 0.25
            } else {
                waitSeconds = max(0.25, nextAvailableAt.timeIntervalSince(now))
            }
            try await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
        }
    }

    func markSuccess(at date: Date = Date()) {
        lastSuccessAt = date
    }

    func finish(
        cooldownSeconds: TimeInterval? = nil,
        useSuccessCooldown: Bool = true
    ) {
        isRunning = false
        let now = Date()
        let baseSpacing = max(minSpacingSeconds, cooldownSeconds ?? 0)
        var nextDate = now.addingTimeInterval(baseSpacing)
        if useSuccessCooldown, cooldownSeconds == nil, let lastSuccessAt {
            nextDate = max(nextDate, lastSuccessAt.addingTimeInterval(successCooldownSeconds))
        }
        nextAvailableAt = nextDate
    }

    func noteSuccessfulInference(at date: Date = Date()) {
        lastSuccessAt = date
        nextAvailableAt = max(nextAvailableAt, date.addingTimeInterval(successCooldownSeconds))
    }

    func snapshot() -> InferenceRequestGateSnapshot {
        InferenceRequestGateSnapshot(
            isRunning: isRunning,
            nextAvailableAt: nextAvailableAt,
            lastSuccessAt: lastSuccessAt
        )
    }
}
