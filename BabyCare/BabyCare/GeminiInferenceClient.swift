import Foundation

enum GeminiInferenceError: LocalizedError {
    case unsupportedCaptureType(CaptureType)
    case invalidManifest
    case noModelResponse
    case invalidModelJSON
    case invalidRequestURL
    case httpError(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedCaptureType(let captureType):
            return "Unsupported capture type for Gemini inference: \(captureType.rawValue)"
        case .invalidManifest:
            return "Segment manifest is invalid or unreadable."
        case .noModelResponse:
            return "Gemini response did not contain a usable candidate."
        case .invalidModelJSON:
            return "Gemini returned malformed JSON output."
        case .invalidRequestURL:
            return "Failed to build Gemini request URL."
        case .httpError(let statusCode, let body):
            return "Gemini request failed with HTTP \(statusCode): \(body)"
        }
    }
}

struct GeminiClientConfiguration: Sendable {
    let apiKey: String
    let model: String
    let apiBaseURL: String
    let maxFramesPerSegment: Int
    let maxInlineBytesPerPart: Int

    init(
        apiKey: String,
        model: String = "gemini-2.0-flash",
        apiBaseURL: String = "https://generativelanguage.googleapis.com/v1beta",
        maxFramesPerSegment: Int = 8,
        maxInlineBytesPerPart: Int = 1_500_000
    ) {
        self.apiKey = apiKey
        self.model = model
        self.apiBaseURL = apiBaseURL
        self.maxFramesPerSegment = maxFramesPerSegment
        self.maxInlineBytesPerPart = maxInlineBytesPerPart
    }
}

struct GeminiInferenceAppConfig {
    static func makeClient(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GeminiInferenceClient? {
        let envKey = environment["GEMINI_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let plistKey = (bundle.object(forInfoDictionaryKey: "GEMINI_API_KEY") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = envKey?.isEmpty == false ? envKey : plistKey

        guard let apiKey, !apiKey.isEmpty else {
            return nil
        }

        let envModel = environment["GEMINI_MODEL"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let plistModel = (bundle.object(forInfoDictionaryKey: "GEMINI_MODEL") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let model: String
        if let envModel, !envModel.isEmpty {
            model = envModel
        } else if let plistModel, !plistModel.isEmpty {
            model = plistModel
        } else {
            model = "gemini-2.0-flash"
        }

        return GeminiInferenceClient(
            configuration: .init(
                apiKey: apiKey,
                model: model
            )
        )
    }
}

final class GeminiInferenceClient: InferenceClient {
    private let configuration: GeminiClientConfiguration
    private let session: URLSession
    let modelName: String

    init(
        configuration: GeminiClientConfiguration,
        session: URLSession = .shared
    ) {
        self.configuration = configuration
        self.session = session
        self.modelName = configuration.model
    }

    func infer(from capture: CaptureEnvelope) async throws -> InferenceResult {
        let parts = try buildParts(from: capture)
        let output = try await generate(parts: parts)
        return output.toInferenceResult(fallbackModelVersion: configuration.model)
    }

    private func buildParts(from capture: CaptureEnvelope) throws -> [GeminiPart] {
        var parts: [GeminiPart] = [
            .text(promptText(for: capture))
        ]

        switch capture.captureType {
        case .photo:
            let photoData = try Data(contentsOf: capture.localMediaURL)
            parts.append(.inlineData(mimeType: "image/jpeg", data: photoData))
        case .shortVideo:
            parts.append(contentsOf: try buildSegmentParts(manifestURL: capture.localMediaURL))
        case .audioSnippet:
            let audioData = try Data(contentsOf: capture.localMediaURL)
            parts.append(.inlineData(mimeType: "audio/wav", data: audioData))
        }

        return parts
    }

    private func buildSegmentParts(manifestURL: URL) throws -> [GeminiPart] {
        let manifestData = try Data(contentsOf: manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(GeminiSegmentManifest.self, from: manifestData)
        let segmentDirectory = manifestURL.deletingLastPathComponent()

        var parts: [GeminiPart] = []
        parts.append(
            .text(
                "Segment context: frameCount=\(manifest.frameCount), " +
                "startedAt=\(manifest.startedAt.ISO8601Format()), endedAt=\(manifest.endedAt.ISO8601Format())."
            )
        )

        let framesDirectory = segmentDirectory.appendingPathComponent(manifest.framesDirectory, isDirectory: true)
        let frameURLs = try loadFrameURLs(from: framesDirectory)
        let sampledFrames = sampleEvenly(frameURLs, maxCount: configuration.maxFramesPerSegment)
        for frameURL in sampledFrames {
            let frameData = try Data(contentsOf: frameURL)
            if frameData.count <= configuration.maxInlineBytesPerPart {
                parts.append(.inlineData(mimeType: "image/jpeg", data: frameData))
            }
        }

        if manifest.audio.included,
           manifest.audio.status == "recorded",
           let fileName = manifest.audio.localFileName {
            let audioURL = segmentDirectory.appendingPathComponent(fileName)
            if FileManager.default.fileExists(atPath: audioURL.path) {
                let audioData = try Data(contentsOf: audioURL)
                if audioData.count <= configuration.maxInlineBytesPerPart {
                    parts.append(.inlineData(mimeType: "audio/wav", data: audioData))
                }
            }
        }

        if parts.count <= 1 {
            throw GeminiInferenceError.invalidManifest
        }

        return parts
    }

    private func loadFrameURLs(from directoryURL: URL) throws -> [URL] {
        let frameURLs = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension.lowercased() == "jpg" || $0.pathExtension.lowercased() == "jpeg" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return frameURLs
    }

    private func sampleEvenly(_ urls: [URL], maxCount: Int) -> [URL] {
        guard urls.count > maxCount, maxCount > 1 else {
            return urls
        }

        let lastIndex = urls.count - 1
        return (0..<maxCount).map { position in
            let normalized = Double(position) / Double(maxCount - 1)
            let index = Int((normalized * Double(lastIndex)).rounded())
            return urls[min(max(index, 0), lastIndex)]
        }
    }

    private func promptText(for capture: CaptureEnvelope) -> String {
        """
        You classify baby-care media into one activity label.
        Allowed labels: diaperWet, diaperBowel, feeding, sleepStart, wakeUp, other.
        If label is feeding and amount in ounces is inferable, provide feedingAmountOz as a number with one decimal.
        If spoken audio explicitly mentions what time the activity happened, provide mentionedEventTime24h in HH:mm 24-hour format.
        If spoken audio explicitly mentions a relative date reference for when the activity happened, provide mentionedEventDayOffset as an integer:
        -1 for yesterday, 0 for today, 1 for tomorrow.
        Only provide mentionedEventDayOffset when the date reference is explicit in the audio or transcription. Do not infer or guess it from context.
        Only provide mentionedEventTime24h when the time is explicitly stated in the audio or transcription. Do not infer or guess it from context.
        Use only evidence in the media.
        Return JSON only following the schema.
        Capture metadata: type=\(capture.captureType.rawValue), capturedAt=\(capture.capturedAt.ISO8601Format()).
        """
    }

    private func generate(parts: [GeminiPart]) async throws -> GeminiModelOutput {
        let path = "\(configuration.apiBaseURL)/models/\(configuration.model):generateContent"
        guard var components = URLComponents(string: path) else {
            throw GeminiInferenceError.invalidRequestURL
        }
        components.queryItems = [
            .init(name: "key", value: configuration.apiKey)
        ]
        guard let url = components.url else {
            throw GeminiInferenceError.invalidRequestURL
        }

        let requestPayload = GeminiGenerateContentRequest(
            contents: [
                .init(role: "user", parts: parts)
            ],
            generationConfig: .init(
                responseMimeType: "application/json",
                responseSchema: .activityClassifierSchema
            )
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(requestPayload)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiInferenceError.noModelResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8>"
            throw GeminiInferenceError.httpError(
                statusCode: http.statusCode,
                body: String(body.prefix(500))
            )
        }

        let geminiResponse = try JSONDecoder().decode(GeminiGenerateContentResponse.self, from: data)
        guard
            let rawText = geminiResponse.candidates?
                .first?
                .content
                .parts
                .first(where: { ($0.text?.isEmpty == false) })?
                .text
        else {
            throw GeminiInferenceError.noModelResponse
        }

        let normalizedText = sanitizeModelJSON(rawText)
        guard let outputData = normalizedText.data(using: .utf8) else {
            throw GeminiInferenceError.invalidModelJSON
        }
        do {
            return try JSONDecoder().decode(GeminiModelOutput.self, from: outputData)
        } catch {
            throw GeminiInferenceError.invalidModelJSON
        }
    }

    private func sanitizeModelJSON(_ rawText: String) -> String {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```"), let firstBrace = trimmed.firstIndex(of: "{"), let lastBrace = trimmed.lastIndex(of: "}") {
            return String(trimmed[firstBrace...lastBrace])
        }
        return trimmed
    }
}

private struct GeminiSegmentManifest: Decodable {
    struct AudioDescriptor: Decodable {
        let included: Bool
        let status: String
        let localFileName: String?
    }

    let startedAt: Date
    let endedAt: Date
    let frameCount: Int
    let framesDirectory: String
    let audio: AudioDescriptor
}

private struct GeminiGenerateContentRequest: Encodable {
    struct Content: Encodable {
        let role: String
        let parts: [GeminiPart]
    }

    struct GenerationConfig: Encodable {
        let responseMimeType: String
        let responseSchema: GeminiResponseSchema
    }

    let contents: [Content]
    let generationConfig: GenerationConfig
}

private struct GeminiPart: Encodable {
    struct InlineData: Encodable {
        let mimeType: String
        let data: String

        enum CodingKeys: String, CodingKey {
            case mimeType = "mime_type"
            case data
        }
    }

    let text: String?
    let inlineData: InlineData?

    enum CodingKeys: String, CodingKey {
        case text
        case inlineData = "inline_data"
    }

    static func text(_ text: String) -> GeminiPart {
        GeminiPart(text: text, inlineData: nil)
    }

    static func inlineData(mimeType: String, data: Data) -> GeminiPart {
        GeminiPart(text: nil, inlineData: .init(mimeType: mimeType, data: data.base64EncodedString()))
    }
}

private struct GeminiResponseSchema: Encodable {
    struct Property: Encodable {
        let type: String
        let enumValues: [String]?
        let minimum: Double?
        let maximum: Double?
        let maxLength: Int?

        enum CodingKeys: String, CodingKey {
            case type
            case enumValues = "enum"
            case minimum
            case maximum
            case maxLength
        }
    }

    let type: String
    let properties: [String: Property]
    let required: [String]

    static let activityClassifierSchema = GeminiResponseSchema(
        type: "OBJECT",
        properties: [
            "label": .init(
                type: "STRING",
                enumValues: ActivityLabel.allCases.map(\.rawValue),
                minimum: nil,
                maximum: nil,
                maxLength: nil
            ),
            "confidence": .init(
                type: "NUMBER",
                enumValues: nil,
                minimum: 0,
                maximum: 1,
                maxLength: nil
            ),
            "rationaleShort": .init(
                type: "STRING",
                enumValues: nil,
                minimum: nil,
                maximum: nil,
                maxLength: 160
            ),
            "modelVersion": .init(
                type: "STRING",
                enumValues: nil,
                minimum: nil,
                maximum: nil,
                maxLength: 80
            ),
            "feedingAmountOz": .init(
                type: "NUMBER",
                enumValues: nil,
                minimum: 0,
                maximum: 24,
                maxLength: nil
            ),
            "mentionedEventTime24h": .init(
                type: "STRING",
                enumValues: nil,
                minimum: nil,
                maximum: nil,
                maxLength: 5
            ),
            "mentionedEventDayOffset": .init(
                type: "NUMBER",
                enumValues: nil,
                minimum: -7,
                maximum: 7,
                maxLength: nil
            )
        ],
        required: ["label", "confidence", "rationaleShort"]
    )
}

private struct GeminiGenerateContentResponse: Decodable {
    struct Candidate: Decodable {
        struct Content: Decodable {
            struct Part: Decodable {
                let text: String?
            }

            let parts: [Part]
        }

        let content: Content
    }

    let candidates: [Candidate]?
}

private struct GeminiModelOutput: Decodable {
    let label: String
    let confidence: Double
    let rationaleShort: String
    let modelVersion: String?
    let feedingAmountOz: Double?
    let mentionedEventTime24h: String?
    let mentionedEventDayOffset: Double?

    func toInferenceResult(fallbackModelVersion: String) -> InferenceResult {
        let mappedLabel = ActivityLabel(rawValue: label) ?? normalizeLabel(label)
        return InferenceResult(
            label: mappedLabel,
            confidence: min(max(confidence, 0), 1),
            rationaleShort: rationaleShort,
            modelVersion: {
                if let modelVersion, !modelVersion.isEmpty {
                    return modelVersion
                }
                return fallbackModelVersion
            }(),
            feedingAmountOz: normalizedFeedingAmountOz(for: mappedLabel),
            mentionedEventTime: normalizedMentionedEventTime()
        )
    }

    private func normalizedFeedingAmountOz(for label: ActivityLabel) -> Double? {
        guard label == .feeding, let feedingAmountOz else { return nil }
        let clamped = min(max(feedingAmountOz, 0), 24)
        return (clamped * 10).rounded() / 10
    }

    private func normalizedMentionedEventTime() -> MentionedEventTime? {
        let normalizedDayOffset = normalizedMentionedEventDayOffset()

        if let mentionedEventTime24h {
            let trimmed = mentionedEventTime24h.trimmingCharacters(in: .whitespacesAndNewlines)
            let components = trimmed.split(separator: ":", omittingEmptySubsequences: false)
            guard
                components.count == 2,
                let hour = Int(components[0]),
                let minute = Int(components[1])
            else {
                return MentionedEventTime(hour: nil, minute: nil, dayOffset: normalizedDayOffset)
            }
            return MentionedEventTime(hour: hour, minute: minute, dayOffset: normalizedDayOffset)
        }

        return MentionedEventTime(hour: nil, minute: nil, dayOffset: normalizedDayOffset)
    }

    private func normalizedMentionedEventDayOffset() -> Int {
        guard let mentionedEventDayOffset else { return 0 }
        return min(7, max(-7, Int(mentionedEventDayOffset.rounded())))
    }

    private func normalizeLabel(_ rawValue: String) -> ActivityLabel {
        let normalized = rawValue.lowercased().replacingOccurrences(of: "_", with: "")
        switch normalized {
        case "diaperwet":
            return .diaperWet
        case "diaperbowel":
            return .diaperBowel
        case "feeding":
            return .feeding
        case "sleepstart", "babyasleep":
            return .sleepStart
        case "wakeup", "babywakesup":
            return .wakeUp
        default:
            return .other
        }
    }
}
