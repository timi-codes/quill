import FluidAudio
import Foundation

/// Runs offline speaker diarization on an audio file using FluidAudio's
/// Pyannote + WeSpeaker VBx pipeline. Returns timed speaker segments that
/// can be matched against transcript segments to assign speaker labels.
final class SpeakerDiarizer: Sendable {
    private nonisolated(unsafe) var manager: OfflineDiarizerManager?

    func prepare() async throws {
        guard manager == nil else { return }
        let mgr = OfflineDiarizerManager()
        try await mgr.prepareModels()
        manager = mgr
    }

    /// Diarize an audio file and return speaker segments.
    func diarize(_ audio: URL) async throws -> [SpeakerSegment] {
        guard let manager else {
            throw DiarizeError.notPrepared
        }
        let result = try await manager.process(audio)
        return result.segments.map { seg in
            SpeakerSegment(
                speaker: seg.speakerId,
                startMs: Int(seg.startTimeSeconds * 1000),
                endMs: Int(seg.endTimeSeconds * 1000)
            )
        }
    }

    func release() {
        manager = nil
    }

    enum DiarizeError: Error, CustomStringConvertible {
        case notPrepared
        var description: String { "diarizer used before prepare()" }
    }
}

/// A timed span attributed to a speaker ID (e.g. "S1", "S2").
struct SpeakerSegment: Sendable {
    let speaker: String
    let startMs: Int
    let endMs: Int
}

/// Given transcript segments and diarization segments, assign speaker labels
/// to each transcript segment based on time overlap.
enum SpeakerAssigner {
    /// Assign diarized speaker labels to transcript segments. Each transcript
    /// segment gets the speaker ID that has the most overlap with it.
    /// `trackLabel` is the fallback ("me" or "them") when no diarization
    /// segment overlaps.
    static func assign(
        transcriptSegments: [(start: Double, end: Double, text: String)],
        diarization: [SpeakerSegment],
        trackLabel: String,
        offsetMs: Int
    ) -> [(speaker: String, startMs: Int, endMs: Int, text: String)] {
        guard !diarization.isEmpty else {
            // No diarization data — fall back to track label.
            return transcriptSegments.map { seg in
                (
                    speaker: trackLabel,
                    startMs: Int((seg.start + Double(offsetMs) / 1000) * 1000),
                    endMs: Int((seg.end + Double(offsetMs) / 1000) * 1000),
                    text: seg.text
                )
            }
        }

        // Build a lookup: for each transcript segment, find the diarization
        // segment with the greatest overlap and use its speaker ID.
        return transcriptSegments.map { seg in
            let segStartMs = Int((seg.start + Double(offsetMs) / 1000) * 1000)
            let segEndMs = Int((seg.end + Double(offsetMs) / 1000) * 1000)

            var bestSpeaker = trackLabel
            var bestOverlap = 0

            for diar in diarization {
                let overlapStart = max(segStartMs, diar.startMs + offsetMs)
                let overlapEnd = min(segEndMs, diar.endMs + offsetMs)
                let overlap = max(0, overlapEnd - overlapStart)
                if overlap > bestOverlap {
                    bestOverlap = overlap
                    bestSpeaker = diar.speaker
                }
            }

            return (speaker: bestSpeaker, startMs: segStartMs, endMs: segEndMs, text: seg.text)
        }
    }

    /// After diarization, map generic speaker IDs ("S1", "S2") to friendlier
    /// labels. The mic track's dominant speaker becomes "me", others become
    /// "Speaker 2", "Speaker 3", etc. For the system track, the dominant
    /// speaker becomes "them".
    static func relabel(
        segments: [SpeakerSegment],
        trackLabel: String
    ) -> [String: String] {
        // Count total duration per speaker to find the dominant one.
        var durations: [String: Int] = [:]
        for seg in segments {
            durations[seg.speaker, default: 0] += seg.endMs - seg.startMs
        }

        let sorted = durations.sorted { $0.value > $1.value }
        var mapping: [String: String] = [:]
        for (i, entry) in sorted.enumerated() {
            if i == 0 {
                mapping[entry.key] = trackLabel
            } else {
                mapping[entry.key] = "Speaker \(i + 1)"
            }
        }
        return mapping
    }
}
