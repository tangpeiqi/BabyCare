import AVFoundation
import Foundation

@MainActor
final class AudioSegmentRecorder {
    private enum AudioThreshold {
        static let emptyWaveHeaderBytes = 44
        static let minimumMeaningfulPayloadBytes = 3_200
    }

    private let baseDirectoryURL: URL
    private var activeSegmentID: UUID?
    private var activeAudioURL: URL?
    private var recorder: AVAudioRecorder?

    init(baseDirectoryURL: URL? = nil) {
        if let baseDirectoryURL {
            self.baseDirectoryURL = baseDirectoryURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.baseDirectoryURL = appSupport
                .appendingPathComponent("PoLSegments", isDirectory: true)
        }
    }

    func startSegment(segmentID: UUID) throws -> String {
        guard activeSegmentID == nil else {
            throw NSError(domain: "AudioSegmentRecorder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "An audio segment is already active."
            ])
        }

        let segmentDirectoryURL = baseDirectoryURL.appendingPathComponent(segmentID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: segmentDirectoryURL, withIntermediateDirectories: true)
        let audioURL = segmentDirectoryURL.appendingPathComponent("audio.wav")

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 8000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(
            .playAndRecord,
            mode: .default,
            options: [.allowBluetoothHFP, .mixWithOthers]
        )
        try audioSession.setActive(true, options: .notifyOthersOnDeactivation)

        let recorder = try AVAudioRecorder(url: audioURL, settings: settings)
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw NSError(domain: "AudioSegmentRecorder", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to start audio recording."
            ])
        }

        activeSegmentID = segmentID
        activeAudioURL = audioURL
        self.recorder = recorder

        let route = audioSession.currentRoute.inputs.first?.portType.rawValue ?? "unknown"
        return route
    }

    func stopSegment(segmentID: UUID) -> SegmentAudioMetadata {
        guard activeSegmentID == segmentID else {
            return .missing(status: "not_recording", note: "Audio recording was not active for this segment.")
        }
        guard let recorder, let audioURL = activeAudioURL else {
            activeSegmentID = nil
            activeAudioURL = nil
            self.recorder = nil
            return .missing(status: "not_recording", note: "Audio recorder was not initialized.")
        }

        let currentTimeSeconds = recorder.currentTime
        recorder.stop()
        let route = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portType.rawValue ?? "unknown"
        let durationMsFromRecorder = Int((currentTimeSeconds * 1000.0).rounded())

        activeSegmentID = nil
        activeAudioURL = nil
        self.recorder = nil

        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: audioURL.path)
        let bytes = (fileAttributes?[.size] as? NSNumber)?.intValue ?? 0
        let payloadBytes = max(0, bytes - AudioThreshold.emptyWaveHeaderBytes)
        let estimatedDurationMsFromBytes = Int(
            (Double(payloadBytes) / Double(8_000 * 1 * 2) * 1000.0).rounded()
        )
        let normalizedDurationMs = max(durationMsFromRecorder, estimatedDurationMsFromBytes)

        if bytes <= AudioThreshold.emptyWaveHeaderBytes || payloadBytes < AudioThreshold.minimumMeaningfulPayloadBytes {
            try? FileManager.default.removeItem(at: audioURL)
            return .missing(
                status: "empty_audio",
                note: "Audio file contained too little recorded payload. route=\(route)",
                durationMillis: normalizedDurationMs,
                bytes: bytes,
                sampleRateHz: 8_000,
                channels: 1
            )
        }

        return SegmentAudioMetadata(
            included: true,
            status: "recorded",
            note: "Audio captured successfully. route=\(route)",
            localFileName: "audio.wav",
            localFileURL: audioURL,
            sampleRateHz: 8000,
            channels: 1,
            durationMillis: normalizedDurationMs,
            bytes: bytes,
            transcript: nil
        )
    }

    func discardActiveSegment() {
        recorder?.stop()
        if let audioURL = activeAudioURL {
            try? FileManager.default.removeItem(at: audioURL)
        }
        activeSegmentID = nil
        activeAudioURL = nil
        recorder = nil
    }
}
