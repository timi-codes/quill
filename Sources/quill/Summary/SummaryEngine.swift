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

/// Context about a project folder: its name and the contents of its about.md.
struct FolderContext: Sendable {
    let name: String
    let about: String?
}

/// An engine that takes a transcript and produces a title + summary + folder
/// classification.
protocol SummaryEngine: Sendable {
    func process(
        transcript: String,
        folders: [FolderContext]
    ) async throws -> SummaryResult
}
