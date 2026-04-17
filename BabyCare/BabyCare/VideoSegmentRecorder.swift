import Foundation
import UIKit

enum LocalVideoSegmentRecorderError: LocalizedError {
    case activeSegmentAlreadyExists

    var errorDescription: String? {
        switch self {
        case .activeSegmentAlreadyExists:
            return "A segment is already active."
        }
    }
}

struct PersistedVideoSegment: Sendable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let manifestURL: URL
    let frameCount: Int
}

struct SegmentAudioMetadata: Sendable {
    let included: Bool
    let status: String
    let note: String
    let localFileName: String?
    let sampleRateHz: Int?
    let channels: Int?
    let durationMillis: Int?
    let bytes: Int?

    static func missing(status: String, note: String) -> SegmentAudioMetadata {
        SegmentAudioMetadata(
            included: false,
            status: status,
            note: note,
            localFileName: nil,
            sampleRateHz: nil,
            channels: nil,
            durationMillis: nil,
            bytes: nil
        )
    }
}

actor LocalVideoSegmentRecorder {
    private struct ActiveSegment {
        let id: UUID
        let startedAt: Date
        let directoryURL: URL
        let framesDirectoryURL: URL
        var nextFrameIndex: Int
        var frameCount: Int
    }

    private struct SegmentManifest: Codable {
        struct AudioDescriptor: Codable {
            let included: Bool
            let status: String
            let note: String
            let localFileName: String?
            let sampleRateHz: Int?
            let channels: Int?
            let durationMillis: Int?
            let bytes: Int?
        }

        let segmentId: UUID
        let captureType: String
        let videoFormat: String
        let startedAt: Date
        let endedAt: Date
        let frameCount: Int
        let framesDirectory: String
        let audio: AudioDescriptor
    }

    private let baseDirectoryURL: URL
    private var activeSegment: ActiveSegment?

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

    func startSegment(id: UUID, startedAt: Date) throws {
        guard activeSegment == nil else {
            throw LocalVideoSegmentRecorderError.activeSegmentAlreadyExists
        }
        try ensureDirectoryExists(at: baseDirectoryURL)

        let segmentDirectoryURL = baseDirectoryURL.appendingPathComponent(id.uuidString, isDirectory: true)
        let framesDirectoryURL = segmentDirectoryURL.appendingPathComponent("frames", isDirectory: true)
        try ensureDirectoryExists(at: segmentDirectoryURL)
        try ensureDirectoryExists(at: framesDirectoryURL)

        activeSegment = ActiveSegment(
            id: id,
            startedAt: startedAt,
            directoryURL: segmentDirectoryURL,
            framesDirectoryURL: framesDirectoryURL,
            nextFrameIndex: 0,
            frameCount: 0
        )
    }

    func appendFrame(image: UIImage, segmentID: UUID) throws {
        guard var segment = activeSegment, segment.id == segmentID else { return }
        guard let jpegData = image.jpegData(compressionQuality: 0.75) else { return }

        let fileName = String(format: "frame_%06d.jpg", segment.nextFrameIndex)
        let fileURL = segment.framesDirectoryURL.appendingPathComponent(fileName)
        try jpegData.write(to: fileURL, options: .atomic)

        segment.nextFrameIndex += 1
        segment.frameCount += 1
        activeSegment = segment
    }

    func endSegment(
        id: UUID,
        endedAt: Date,
        audioMetadata: SegmentAudioMetadata
    ) throws -> PersistedVideoSegment? {
        guard let segment = activeSegment, segment.id == id else { return nil }
        activeSegment = nil

        let manifest = SegmentManifest(
            segmentId: segment.id,
            captureType: "shortVideo",
            videoFormat: "image_sequence_jpeg",
            startedAt: segment.startedAt,
            endedAt: endedAt,
            frameCount: segment.frameCount,
            framesDirectory: "frames",
            audio: .init(
                included: audioMetadata.included,
                status: audioMetadata.status,
                note: audioMetadata.note,
                localFileName: audioMetadata.localFileName,
                sampleRateHz: audioMetadata.sampleRateHz,
                channels: audioMetadata.channels,
                durationMillis: audioMetadata.durationMillis,
                bytes: audioMetadata.bytes
            )
        )
        let manifestURL = segment.directoryURL.appendingPathComponent("segment_manifest.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: manifestURL, options: .atomic)

        return PersistedVideoSegment(
            id: segment.id,
            startedAt: segment.startedAt,
            endedAt: endedAt,
            manifestURL: manifestURL,
            frameCount: segment.frameCount
        )
    }

    func discardActiveSegment() {
        guard let segment = activeSegment else { return }
        activeSegment = nil
        try? FileManager.default.removeItem(at: segment.directoryURL)
    }

    private func ensureDirectoryExists(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
