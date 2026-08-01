import Foundation

/// Result of AI processing a transcript: a human-readable title, a markdown
/// summary, and the subfolder name the session should be filed under.
struct SummaryResult: Sendable {
    let title: String
    let summary: String
    /// Best-matching subfolder name from the notes directory, or nil if no
    /// match was confident enough.
    let folder: String?
}

/// An engine that takes a transcript and produces a title + summary + folder
/// classification.
protocol SummaryEngine: Sendable {
    func process(
        transcript: String,
        existingFolders: [String]
    ) async throws -> SummaryResult
}
