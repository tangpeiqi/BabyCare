import AVFoundation
import Combine
import Foundation
import MWDATCamera
import MWDATCore
import Speech
import SwiftData
import UIKit

struct WearablesDebugEvent: Identifiable {
    let id = UUID()
    let timestamp: Date
    let name: String
    let metadata: [String: String]
    let isButtonLike: Bool
    let isManualMarker: Bool
}

@MainActor
final class WearablesManager: ObservableObject {
    @Published private(set) var registrationStateText: String = "unknown"
    @Published private(set) var cameraPermissionText: String = "Not granted"
    @Published private(set) var connectedDeviceCount: Int = 0
    @Published private(set) var configSummary: String = ""
    @Published private(set) var streamStateText: String = "stopped"
    @Published private(set) var isStreaming: Bool = false
    @Published private(set) var latestFrame: UIImage?
    @Published private(set) var latestPhotoCaptureAt: Date?
    @Published private(set) var lastCallbackHandledAt: Date?
    @Published private(set) var lastError: String?
    @Published private(set) var isBusy: Bool = false
    @Published private(set) var debugEvents: [WearablesDebugEvent] = []
    @Published private(set) var buttonLikeEventDetected: Bool = false
    @Published private(set) var latestSegmentManifestURL: URL?
    @Published private(set) var latestSegmentEndedAt: Date?
    @Published private(set) var latestSegmentFrameCount: Int = 0
    @Published private(set) var voiceCancelEnabled: Bool = false
    @Published private(set) var isVoiceCancelListening: Bool = false

    private var streamSession: StreamSession?
    private var streamStateToken: Any?
    private var videoFrameToken: Any?
    private var photoDataToken: Any?
    private var activityPipeline: ActivityPipeline?
    private var previousStreamStateNormalized: String?
    private var lastAppInitiatedSessionControlAt: Date?
    private var lastVideoFrameLogAt: Date?
    private var activeSegmentID: UUID?
    private var activeSegmentStartedAt: Date?
    private var cancelledSegmentIDs: Set<UUID> = []
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let voiceCommandAudioEngine = AVAudioEngine()
    private var speechRecognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var speechRecognitionTask: SFSpeechRecognitionTask?
    private let debugEventLimit: Int = 60
    private let segmentRecorder = LocalVideoSegmentRecorder()
    private let audioRecorder = AudioSegmentRecorder()
    private let speechSynthesizer = AVSpeechSynthesizer()

    init(autoConfigure: Bool = true) {
        configSummary = readMWDATConfigSummary()
        if autoConfigure {
            configureWearables()
        }
        observeWearablesState()
    }

    func configurePipelineIfNeeded(modelContext: ModelContext) {
        guard activityPipeline == nil else { return }
        let store = SwiftDataActivityStore(modelContext: modelContext)
        let inferenceClient: InferenceClient

        if let geminiClient = GeminiInferenceAppConfig.makeClient() {
            inferenceClient = geminiClient
            recordDebugEvent(
                "inference_client_configured",
                metadata: [
                    "provider": "gemini",
                    "model": geminiClient.modelName
                ]
            )
        } else {
            inferenceClient = MockInferenceClient()
            recordDebugEvent(
                "inference_client_configured",
                metadata: ["provider": "mock", "reason": "missing_gemini_config"]
            )
        }

        activityPipeline = ActivityPipeline(
            inferenceClient: inferenceClient,
            store: store
        )
    }

    func handleIncomingURL(_ url: URL) {
        guard url.scheme == "babycaremeta" else { return }
        guard isWearablesActionURL(url) else { return }
        recordDebugEvent(
            "incoming_url",
            metadata: ["host": url.host ?? "<none>", "path": url.path]
        )

        Task {
            do {
                _ = try await Wearables.shared.handleUrl(url)
                lastCallbackHandledAt = Date()
                lastError = nil
                recordDebugEvent("handle_url_success")
                await refreshCameraPermission()
            } catch let error as WearablesHandleURLError {
                lastError = "Failed to handle wearables callback: \(error.description)"
                recordDebugEvent("handle_url_error", metadata: ["error": error.description])
            } catch let error as RegistrationError {
                lastError = "Failed to handle wearables callback: \(error.description)"
                recordDebugEvent("handle_url_error", metadata: ["error": error.description])
            } catch {
                lastError = formatError("Failed to handle wearables callback", error)
                recordDebugEvent("handle_url_error", metadata: ["error": error.localizedDescription])
            }
        }
    }

    func startRegistration() async {
        guard registrationStateText.lowercased() != "registering" else { return }
        guard !isDeviceRegistered else {
            lastError = nil
            recordDebugEvent("start_registration_skipped", metadata: ["reason": "already_registered"])
            return
        }
        recordDebugEvent("start_registration_requested")

        isBusy = true
        defer { isBusy = false }

        guard canOpenMetaAIApp() else {
            lastError = "Failed to start registration: Meta AI app is not available via fb-viewapp://. Install/update Meta AI app and verify LSApplicationQueriesSchemes."
            return
        }

        do {
            try await Wearables.shared.startRegistration()
            lastError = nil
        } catch {
            lastError = formatError("Failed to start registration", error)
        }
    }

    func startUnregistration() async {
        guard isDeviceRegistered else {
            lastError = nil
            recordDebugEvent("start_unregistration_skipped", metadata: ["reason": "not_registered"])
            return
        }
        recordDebugEvent("start_unregistration_requested")
        isBusy = true
        defer { isBusy = false }

        guard canOpenMetaAIApp() else {
            lastError = "Failed to start unregistration: Meta AI app is not available via fb-viewapp://."
            return
        }

        do {
            try await Wearables.shared.startUnregistration()
            lastError = nil
        } catch {
            lastError = formatError("Failed to start unregistration", error)
        }
    }

    func refreshCameraPermission() async {
        recordDebugEvent("check_camera_permission_requested")
        isBusy = true
        defer { isBusy = false }

        do {
            let status = try await Wearables.shared.checkPermissionStatus(.camera)
            cameraPermissionText = displayText(forCameraPermissionStatus: status)
            lastError = nil
        } catch {
            lastError = formatError("Failed to check camera permission", error)
        }
    }

    func requestCameraPermission() async {
        recordDebugEvent("request_camera_permission_requested")
        isBusy = true
        defer { isBusy = false }

        do {
            let status = try await Wearables.shared.requestPermission(.camera)
            cameraPermissionText = displayText(forCameraPermissionStatus: status)
            lastError = nil
        } catch {
            lastError = formatError("Failed to request camera permission", error)
        }
    }

    func startCameraStream() async {
        guard !hasActiveStreamSession else {
            recordDebugEvent(
                "start_stream_skipped",
                metadata: ["reason": "session_already_active", "state": streamStateText]
            )
            return
        }
        lastAppInitiatedSessionControlAt = Date()
        recordDebugEvent("start_stream_requested")
        isBusy = true
        defer { isBusy = false }

        do {
            let status = try await Wearables.shared.checkPermissionStatus(.camera)
            cameraPermissionText = displayText(forCameraPermissionStatus: status)
            if !isPermissionGranted(status) {
                let requested = try await Wearables.shared.requestPermission(.camera)
                cameraPermissionText = displayText(forCameraPermissionStatus: requested)
                guard isPermissionGranted(requested) else {
                    lastError = "Camera permission not granted. Complete permission flow in Meta AI app and retry."
                    return
                }
            }

            if shouldRecreateSessionForStart() {
                await resetCurrentSessionForRestart()
            }
            let session = try makeOrReuseSession()
            await session.start()
            lastError = nil
        } catch {
            lastError = formatError("Failed to start camera stream", error)
        }
    }

    func stopCameraStream() async {
        lastAppInitiatedSessionControlAt = Date()
        recordDebugEvent("stop_stream_requested")
        isBusy = true
        defer { isBusy = false }

        guard let session = streamSession else { return }
        await session.stop()
        await clearSessionReferences()
    }

    func capturePhoto() {
        guard let session = streamSession, isStreaming else {
            lastError = "Capture requires an active streaming session."
            return
        }

        recordDebugEvent("capture_photo_requested")
        session.capturePhoto(format: .jpeg)
    }

    func markManualButtonPress() {
        recordDebugEvent("manual_button_press_marker", isManualMarker: true)
    }

    func clearDebugEvents() {
        debugEvents.removeAll()
        buttonLikeEventDetected = false
    }

    func setVoiceCancelEnabled(_ enabled: Bool) {
        guard voiceCancelEnabled != enabled else { return }
        voiceCancelEnabled = enabled
        recordDebugEvent(
            "voice_cancel_toggle",
            metadata: ["enabled": enabled ? "true" : "false"]
        )
        reevaluateVoiceCancelListening()
    }

    func cancelCurrentSession() async {
        let cancelledSegmentID = activeSegmentID
        if let cancelledSegmentID {
            cancelledSegmentIDs.insert(cancelledSegmentID)
            activeSegmentID = nil
            activeSegmentStartedAt = nil
            audioRecorder.discardActiveSegment()
            await segmentRecorder.discardActiveSegment()
            recordDebugEvent(
                "segment_cancel_requested",
                metadata: ["segmentId": cancelledSegmentID.uuidString]
            )
        } else {
            recordDebugEvent("segment_cancel_requested", metadata: ["segmentId": "<none>"])
        }

        if streamSession != nil {
            await stopCameraStream()
        }
    }

    var isCameraPermissionGranted: Bool {
        isPermissionGrantedText(cameraPermissionText)
    }

    var isDeviceRegistered: Bool {
        let normalized = registrationStateText
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        if normalized.contains("unregistered") || normalized.contains("notregistered") {
            return false
        }
        if normalized.contains("registered") {
            return true
        }
        // Fallback for SDK state strings that don't literally contain "registered".
        return connectedDeviceCount > 0 || isCameraPermissionGranted
    }

    var hasActiveStreamSession: Bool {
        let normalized = streamStateText
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
        if normalized.contains("stopped") || normalized.contains("stopping") {
            return false
        }
        return normalized.contains("streaming")
            || normalized.contains("paused")
            || normalized.contains("starting")
            || normalized.contains("waitingfordevice")
            || normalized.contains("connecting")
    }

    var hasActiveSegmentCapture: Bool {
        activeSegmentID != nil
    }

    private func observeWearablesState() {
        Task {
            for await state in Wearables.shared.registrationStateStream() {
                registrationStateText = String(describing: state)
                recordDebugEvent(
                    "registration_state",
                    metadata: ["value": registrationStateText]
                )
            }
        }

        Task {
            for await devices in Wearables.shared.devicesStream() {
                connectedDeviceCount = devices.count
                recordDebugEvent(
                    "devices_changed",
                    metadata: ["count": "\(connectedDeviceCount)"]
                )
            }
        }
    }

    private func makeOrReuseSession() throws -> StreamSession {
        if let existing = streamSession {
            return existing
        }

        let selector = AutoDeviceSelector(wearables: Wearables.shared)
        let config = StreamSessionConfig(
            videoCodec: .raw,
            resolution: .low,
            frameRate: 24
        )
        let session = StreamSession(streamSessionConfig: config, deviceSelector: selector)
        bindSessionCallbacks(session)
        streamSession = session
        return session
    }

    private func shouldRecreateSessionForStart() -> Bool {
        guard streamSession != nil else { return false }
        let state = streamStateText.lowercased()
        return state != "streaming" && state != "starting"
    }

    private func resetCurrentSessionForRestart() async {
        guard let session = streamSession else { return }
        await session.stop()
        await clearSessionReferences()
        recordDebugEvent("stream_session_recreated")
    }

    private func clearSessionReferences() async {
        if activeSegmentID != nil {
            recordDebugEvent("segment_abandoned_on_session_reset")
        }
        activeSegmentID = nil
        activeSegmentStartedAt = nil
        audioRecorder.discardActiveSegment()
        await segmentRecorder.discardActiveSegment()
        streamSession = nil
        streamStateToken = nil
        videoFrameToken = nil
        photoDataToken = nil
        previousStreamStateNormalized = nil
        isStreaming = false
        streamStateText = "stopped"
        stopVoiceCancelListening()
    }

    private func bindSessionCallbacks(_ session: StreamSession) {
        streamStateToken = session.statePublisher.listen { [weak self] state in
            guard let self else { return }
            Task { @MainActor in
                let previous = self.previousStreamStateNormalized
                self.streamStateText = String(describing: state)
                let normalized = self.streamStateText.lowercased()
                let isButtonLike = self.isLikelyUserGestureTransition(
                    from: previous,
                    to: normalized
                )
                self.isStreaming = normalized == "streaming"
                self.previousStreamStateNormalized = normalized
                self.recordDebugEvent(
                    "stream_state",
                    metadata: ["from": previous ?? "<none>", "to": normalized],
                    isButtonLike: isButtonLike
                )
                self.handleSegmentTransition(from: previous, to: normalized)
                self.reevaluateVoiceCancelListening()
            }
        }

        videoFrameToken = session.videoFramePublisher.listen { [weak self] frame in
            guard let self, let image = frame.makeUIImage() else { return }
            Task { @MainActor in
                self.latestFrame = image
                let now = Date()
                if let segmentID = self.activeSegmentID {
                    do {
                        try await self.segmentRecorder.appendFrame(
                            image: image,
                            segmentID: segmentID
                        )
                    } catch {
                        self.recordDebugEvent(
                            "segment_frame_write_error",
                            metadata: ["error": error.localizedDescription]
                        )
                    }
                }
                if let lastLogAt = self.lastVideoFrameLogAt, now.timeIntervalSince(lastLogAt) < 1 {
                    return
                }
                self.lastVideoFrameLogAt = now
                self.recordDebugEvent("video_frame")
            }
        }

        photoDataToken = session.photoDataPublisher.listen { [weak self] photoData in
            guard let self else { return }
            Task { @MainActor in
                let capturedAt = Date()
                self.latestPhotoCaptureAt = capturedAt
                self.recordDebugEvent(
                    "photo_data",
                    metadata: ["bytes": "\(photoData.data.count)"]
                )

                guard let pipeline = self.activityPipeline else {
                    self.lastError = "Activity pipeline is not configured."
                    return
                }

                do {
                    _ = try await pipeline.processPhotoCapture(photoData: photoData.data, capturedAt: capturedAt)
                    self.lastError = nil
                    self.recordDebugEvent("photo_pipeline_success")
                } catch {
                    self.lastError = self.formatError("Failed to process captured photo", error)
                    self.recordDebugEvent(
                        "photo_pipeline_error",
                        metadata: ["error": error.localizedDescription]
                    )
                }
            }
        }
    }

    private func isLikelyUserGestureTransition(from: String?, to: String) -> Bool {
        guard from == "streaming", to == "paused" || to == "stopped" else {
            return false
        }
        if let lastControlAt = lastAppInitiatedSessionControlAt {
            let elapsed = Date().timeIntervalSince(lastControlAt)
            if elapsed < 2 {
                return false
            }
        }
        return true
    }

    private func handleSegmentTransition(from previous: String?, to current: String) {
        if previous == "paused", current == "streaming" {
            beginSegment()
            return
        }
        if previous == "streaming", current == "paused" {
            endSegment()
        }
    }

    private func beginSegment() {
        guard activeSegmentID == nil else { return }
        let segmentID = UUID()
        let startedAt = Date()
        activeSegmentID = segmentID
        activeSegmentStartedAt = startedAt
        recordDebugEvent(
            "segment_start_detected",
            metadata: ["segmentId": segmentID.uuidString]
        )

        Task {
            do {
                guard activeSegmentID == segmentID else { return }
                try await segmentRecorder.startSegment(id: segmentID, startedAt: startedAt)
                await startOptionalAudioCapture(for: segmentID)
            } catch {
                if activeSegmentID == segmentID {
                    activeSegmentID = nil
                    activeSegmentStartedAt = nil
                    audioRecorder.discardActiveSegment()
                }
                lastError = formatError("Failed to start segment recording", error)
                recordDebugEvent(
                    "segment_start_error",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }

    private func endSegment() {
        guard let segmentID = activeSegmentID else { return }
        let endedAt = Date()
        let startedAt = activeSegmentStartedAt
        activeSegmentID = nil
        activeSegmentStartedAt = nil
        recordDebugEvent(
            "segment_end_detected",
            metadata: ["segmentId": segmentID.uuidString]
        )

        Task {
            do {
                let audioMetadata = finalizeAudioCapture(for: segmentID)
                guard let persisted = try await segmentRecorder.endSegment(
                    id: segmentID,
                    endedAt: endedAt,
                    audioMetadata: audioMetadata
                ) else {
                    recordDebugEvent(
                        "segment_end_missing",
                        metadata: ["segmentId": segmentID.uuidString]
                    )
                    return
                }
                latestSegmentManifestURL = persisted.manifestURL
                latestSegmentEndedAt = persisted.endedAt
                latestSegmentFrameCount = persisted.frameCount
                let elapsed = startedAt.map { endedAt.timeIntervalSince($0) } ?? 0

                if cancelledSegmentIDs.remove(segmentID) != nil {
                    try? FileManager.default.removeItem(at: persisted.manifestURL.deletingLastPathComponent())
                    recordDebugEvent(
                        "segment_discarded_after_cancel",
                        metadata: ["segmentId": segmentID.uuidString]
                    )
                    return
                }

                recordDebugEvent(
                    "segment_saved",
                    metadata: [
                        "segmentId": persisted.id.uuidString,
                        "frames": "\(persisted.frameCount)",
                        "audioIncluded": audioMetadata.included ? "true" : "false",
                        "audioStatus": audioMetadata.status,
                        "elapsedSec": String(format: "%.2f", elapsed),
                        "manifest": persisted.manifestURL.lastPathComponent
                    ]
                )

                guard let pipeline = activityPipeline else {
                    lastError = "Activity pipeline is not configured."
                    recordDebugEvent("segment_pipeline_skipped", metadata: ["reason": "pipeline_missing"])
                    return
                }
                do {
                    let inference = try await pipeline.processVideoSegment(
                        manifestURL: persisted.manifestURL,
                        capturedAt: persisted.endedAt,
                        metadata: [
                            "source": "mwdat_segment",
                            "segmentId": persisted.id.uuidString,
                            "frameCount": "\(persisted.frameCount)",
                            "durationSec": String(format: "%.2f", elapsed)
                        ]
                    )
                    lastError = nil
                    recordDebugEvent(
                        "segment_pipeline_success",
                        metadata: [
                            "segmentId": persisted.id.uuidString,
                            "captureType": "shortVideo"
                        ]
                    )
                    announceActivityLogged(inference: inference)
                } catch {
                    lastError = formatError("Failed to process ended segment", error)
                    recordDebugEvent(
                        "segment_pipeline_error",
                        metadata: [
                            "segmentId": persisted.id.uuidString,
                            "error": error.localizedDescription
                        ]
                    )
                }
            } catch {
                lastError = formatError("Failed to finalize segment recording", error)
                recordDebugEvent(
                    "segment_end_error",
                    metadata: ["error": error.localizedDescription]
                )
            }
        }
    }

    private func startOptionalAudioCapture(for segmentID: UUID) async {
        guard !voiceCancelEnabled else {
            recordDebugEvent(
                "audio_start_skipped",
                metadata: ["segmentId": segmentID.uuidString, "reason": "voice_cancel_enabled"]
            )
            return
        }

        let iosMicGranted = await requestIOSMicrophonePermissionIfNeeded()
        guard iosMicGranted else {
            recordDebugEvent(
                "audio_start_skipped",
                metadata: ["segmentId": segmentID.uuidString, "reason": "ios_mic_permission_denied"]
            )
            return
        }

        do {
            let route = try audioRecorder.startSegment(segmentID: segmentID)
            recordDebugEvent(
                "audio_start",
                metadata: ["segmentId": segmentID.uuidString, "route": route]
            )
        } catch {
            recordDebugEvent(
                "audio_start_error",
                metadata: ["segmentId": segmentID.uuidString, "error": error.localizedDescription]
            )
        }
    }

    private func finalizeAudioCapture(for segmentID: UUID) -> SegmentAudioMetadata {
        let metadata = audioRecorder.stopSegment(segmentID: segmentID)
        var eventMetadata: [String: String] = [
            "segmentId": segmentID.uuidString,
            "status": metadata.status,
            "included": metadata.included ? "true" : "false"
        ]
        if let durationMillis = metadata.durationMillis {
            eventMetadata["durationMs"] = "\(durationMillis)"
        }
        if let bytes = metadata.bytes {
            eventMetadata["bytes"] = "\(bytes)"
        }
        recordDebugEvent("audio_stop", metadata: eventMetadata)
        return metadata
    }

    private func recordDebugEvent(
        _ name: String,
        metadata: [String: String] = [:],
        isButtonLike: Bool = false,
        isManualMarker: Bool = false
    ) {
        let event = WearablesDebugEvent(
            timestamp: Date(),
            name: name,
            metadata: metadata,
            isButtonLike: isButtonLike,
            isManualMarker: isManualMarker
        )
        debugEvents.insert(event, at: 0)
        if debugEvents.count > debugEventLimit {
            debugEvents.removeLast(debugEvents.count - debugEventLimit)
        }
        if isButtonLike {
            buttonLikeEventDetected = true
        }
    }

    private func isPermissionGranted(_ status: PermissionStatus) -> Bool {
        isPermissionGrantedText(String(describing: status))
    }

    private func requestIOSMicrophonePermissionIfNeeded() async -> Bool {
        if #available(iOS 17.0, *) {
            let permission = AVAudioApplication.shared.recordPermission
            switch permission {
            case .granted:
                return true
            case .denied:
                return false
            case .undetermined:
                return await withCheckedContinuation { continuation in
                    AVAudioApplication.requestRecordPermission(completionHandler: { granted in
                        continuation.resume(returning: granted)
                    })
                }
            @unknown default:
                return false
            }
        } else {
            let session = AVAudioSession.sharedInstance()
            switch session.recordPermission {
            case .granted:
                return true
            case .denied:
                return false
            case .undetermined:
                return await withCheckedContinuation { continuation in
                    session.requestRecordPermission { granted in
                        continuation.resume(returning: granted)
                    }
                }
            @unknown default:
                return false
            }
        }
    }

    private func isPermissionGrantedText(_ text: String) -> Bool {
        text.lowercased() == "granted"
    }

    private func displayText(forCameraPermissionStatus status: Any) -> String {
        let normalized = String(describing: status)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")

        return normalized == "granted" ? "Granted" : "Not granted"
    }

    private func isWearablesActionURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return false
        }
        return components.queryItems?.contains(where: { $0.name == "metaWearablesAction" }) == true
    }

    private func canOpenMetaAIApp() -> Bool {
        guard let url = URL(string: "fb-viewapp://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }

    private func readMWDATConfigSummary() -> String {
        guard
            let config = Bundle.main.object(forInfoDictionaryKey: "MWDAT") as? [String: Any]
        else {
            return "MWDAT missing"
        }

        let scheme = (config["AppLinkURLScheme"] as? String) ?? "<missing>"
        let appId = (config["MetaAppID"] as? String) ?? "<missing>"
        let teamId = (config["TeamID"] as? String) ?? "<missing>"
        let clientTokenRaw = (config["ClientToken"] as? String) ?? "<missing>"
        let tokenState: String
        if clientTokenRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tokenState = "empty"
        } else if clientTokenRaw.contains("$(") {
            tokenState = "unresolved"
        } else {
            tokenState = "set"
        }
        return "scheme=\(scheme), appId=\(appId), teamId=\(teamId), clientToken=\(tokenState)"
    }

    private func formatError(_ prefix: String, _ error: Error) -> String {
        let nsError = error as NSError
        return "\(prefix): \(error.localizedDescription) [\(nsError.domain):\(nsError.code)]"
    }

    private func announceActivityLogged(inference: InferenceResult) {
        let utterance = AVSpeechUtterance(string: spokenLabel(for: inference.label))
        utterance.rate = 0.48
        utterance.pitchMultiplier = 1.0
        utterance.volume = 1.0

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.allowBluetoothHFP, .allowBluetoothA2DP, .mixWithOthers]
            )
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            if speechSynthesizer.isSpeaking {
                speechSynthesizer.stopSpeaking(at: .immediate)
            }
            speechSynthesizer.speak(utterance)

            let outputRoute = audioSession.currentRoute.outputs.first?.portType.rawValue ?? "unknown"
            recordDebugEvent(
                "activity_feedback_spoken",
                metadata: [
                    "label": inference.label.rawValue,
                    "route": outputRoute
                ]
            )
        } catch {
            recordDebugEvent(
                "activity_feedback_error",
                metadata: [
                    "label": inference.label.rawValue,
                    "error": error.localizedDescription
                ]
            )
        }
    }

    private func reevaluateVoiceCancelListening() {
        let shouldListen = voiceCancelEnabled && hasActiveStreamSession
        if shouldListen {
            Task {
                await startVoiceCancelListeningIfNeeded()
            }
        } else {
            stopVoiceCancelListening()
        }
    }

    private func startVoiceCancelListeningIfNeeded() async {
        guard !isVoiceCancelListening else { return }
        guard let speechRecognizer else {
            lastError = "Voice cancel unavailable: speech recognizer is not available."
            return
        }
        guard speechRecognizer.isAvailable else {
            lastError = "Voice cancel unavailable: recognizer is currently unavailable."
            return
        }
        guard await requestSpeechRecognitionPermissionIfNeeded() else {
            lastError = "Voice cancel unavailable: speech recognition permission denied."
            return
        }

        stopVoiceCancelListening()

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(
                .record,
                mode: .measurement,
                options: [.duckOthers, .allowBluetoothHFP]
            )
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            speechRecognitionRequest = request

            let inputNode = voiceCommandAudioEngine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
                self?.speechRecognitionRequest?.append(buffer)
            }

            voiceCommandAudioEngine.prepare()
            try voiceCommandAudioEngine.start()

            speechRecognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                guard let self else { return }
                Task { @MainActor in
                    if let result {
                        self.handleVoiceRecognitionTranscript(result.bestTranscription.formattedString)
                    }
                    if result?.isFinal == true || error != nil {
                        self.stopVoiceCancelListening()
                        self.reevaluateVoiceCancelListening()
                    }
                }
            }

            isVoiceCancelListening = true
            recordDebugEvent("voice_cancel_listening_started")
        } catch {
            stopVoiceCancelListening()
            lastError = formatError("Failed to start voice cancel listening", error)
            recordDebugEvent(
                "voice_cancel_listening_error",
                metadata: ["error": error.localizedDescription]
            )
        }
    }

    private func stopVoiceCancelListening() {
        speechRecognitionTask?.cancel()
        speechRecognitionTask = nil

        speechRecognitionRequest?.endAudio()
        speechRecognitionRequest = nil

        voiceCommandAudioEngine.stop()
        voiceCommandAudioEngine.inputNode.removeTap(onBus: 0)

        if isVoiceCancelListening {
            isVoiceCancelListening = false
            recordDebugEvent("voice_cancel_listening_stopped")
        }
    }

    private func handleVoiceRecognitionTranscript(_ transcript: String) {
        let normalized = transcript.lowercased()
        guard containsCancelSessionPhrase(normalized) else { return }

        recordDebugEvent("voice_cancel_phrase_detected", metadata: ["transcript": normalized])
        Task {
            await cancelCurrentSession()
        }
    }

    private func containsCancelSessionPhrase(_ text: String) -> Bool {
        if text.contains("cancel session") {
            return true
        }
        return text.contains("cancel") && (text.contains("segment") || text.contains("capture"))
    }

    private func requestSpeechRecognitionPermissionIfNeeded() async -> Bool {
        let currentStatus = SFSpeechRecognizer.authorizationStatus()
        switch currentStatus {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status == .authorized)
                }
            }
        @unknown default:
            return false
        }
    }

    private func spokenLabel(for label: ActivityLabel) -> String {
        switch label {
        case .diaperWet:
            return "Activity logged: diaper change, wet."
        case .diaperBowel:
            return "Activity logged: diaper change, bowel movement."
        case .feeding:
            return "Activity logged: feeding."
        case .sleepStart:
            return "Activity logged: baby asleep."
        case .wakeUp:
            return "Activity logged: baby woke up."
        case .other:
            return "Activity logged: other."
        }
    }

    private func configureWearables() {
        do {
            try Wearables.configure()
        } catch {
            lastError = formatError("Failed to configure Wearables SDK", error)
            assertionFailure("Failed to configure Wearables SDK: \(error)")
        }
    }
}
