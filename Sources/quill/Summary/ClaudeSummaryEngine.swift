import Foundation

/// Calls the Claude API to generate a title, summary, and classify the
/// recording into one of the user's existing note folders.
struct ClaudeSummaryEngine: SummaryEngine {
    enum EngineError: Error, CustomStringConvertible {
        case missingAPIKey
        case requestFailed(Int, String)
        case malformedResponse(String)
        case allRetriesFailed(Int, last: Error)

        var description: String {
            switch self {
            case .missingAPIKey:
                return "no Claude API key — set summary.api_key in ~/.config/quill/config.json or ANTHROPIC_API_KEY env var"
            case .requestFailed(let status, let body):
                return "Claude API returned \(status): \(String(body.prefix(300)))"
            case .malformedResponse(let detail):
                return "unexpected Claude API response: \(detail)"
            case .allRetriesFailed(let attempts, let last):
                return "Claude API failed after \(attempts) attempts: \(last)"
            }
        }
    }

    private let apiKey: String
    private let model: String

    /// Max transcript characters to send. Claude Sonnet handles ~680k chars
    /// but we cap at 100k to keep costs/latency reasonable.
    private static let maxTranscriptChars = 100_000

    /// Max context.md characters per folder.
    private static let maxContextChars = 5_000

    /// HTTP request timeout.
    private static let requestTimeout: TimeInterval = 120

    /// Retry config for transient failures.
    private static let maxRetries = 3
    private static let retryableStatusCodes: Set<Int> = [429, 500, 502, 503, 529]

    init() throws {
        guard let key = Config.summaryAPIKey() else {
            throw EngineError.missingAPIKey
        }
        self.apiKey = key
        self.model = Config.summaryModel()
    }

    func process(
        transcript: String,
        folders: [FolderContext]
    ) async throws -> SummaryResult {
        let truncatedTranscript = String(transcript.prefix(Self.maxTranscriptChars))

        let folderNames = folders.map(\.name)
        let folderDescriptions: String
        if folders.isEmpty {
            folderDescriptions = "No existing folders."
        } else {
            folderDescriptions = folders.map { ctx in
                let about = ctx.about.map { String($0.prefix(Self.maxContextChars)) }
                if let about {
                    return "### \(ctx.name)\n\(about)"
                } else {
                    return "### \(ctx.name)\n(no context.md)"
                }
            }.joined(separator: "\n\n")
        }

        let systemPrompt = """
        You are an assistant that processes meeting transcripts. You will be given a transcript and a list of project/context folders with their descriptions (from context.md files).

        Respond with ONLY valid JSON (no markdown fences, no extra text) in this exact format:
        {
          "title": "short descriptive title for the meeting (under 60 chars)",
          "summary": "markdown summary with key points, decisions, and action items",
          "folder": "exact folder name from the list, or null if none match"
        }

        Rules for the title:
        - Keep it concise and descriptive
        - Include the topic or purpose of the call
        - If you can identify participants, you may include them

        Rules for the summary:
        - Use markdown with headers: ## Key Points, ## Decisions, ## Action Items
        - Be concise but capture all important information
        - Use bullet points
        - Use the project context from the context.md to write a more informed and relevant summary — reference project-specific terminology, goals, and people where appropriate
        - IMPORTANT: The transcript comes from speech-to-text and often misspells names. Cross-reference names in the transcript against the people listed in context.md and use the correct spelling. For example, if context.md lists "Irede Adekunle" and the transcript says "IREDI" or "Irede" or similar, always use "Irede" in the summary.

        Rules for folder classification:
        - Read each folder's context.md description carefully
        - Match the meeting's content (topics discussed, people mentioned, project context) against the folder descriptions
        - Pick the folder that best matches the meeting's context
        - The folder value MUST be one of these exact names or null: \(folderNames.map { "\"\($0)\"" }.joined(separator: ", "))
        - Only pick a folder if you are reasonably confident it matches
        - Return null if no folder is a good match
        """

        let userMessage = """
        ## Transcript
        \(truncatedTranscript)

        ## Project Folders
        \(folderDescriptions)
        """

        let data = try await callClaudeWithRetry(system: systemPrompt, user: userMessage)
        let result = try parse(data)

        // Validate folder name against actual folders.
        if let folder = result.folder, !folderNames.contains(folder) {
            // Claude returned a folder name that doesn't exist — find closest match.
            let match = folderNames.first { $0.lowercased() == folder.lowercased() }
            return SummaryResult(title: result.title, summary: result.summary, folder: match)
        }

        return result
    }

    // MARK: - API

    private func callClaudeWithRetry(system: String, user: String) async throws -> Data {
        var lastError: Error = EngineError.malformedResponse("no attempts made")

        for attempt in 1...Self.maxRetries {
            do {
                return try await callClaude(system: system, user: user)
            } catch let error as EngineError {
                lastError = error
                if case .requestFailed(let status, _) = error,
                   Self.retryableStatusCodes.contains(status) {
                    let delay = Double(attempt) * 2.0
                    FileHandle.standardError.write(Data(
                        "Claude API \(status), retrying in \(Int(delay))s (attempt \(attempt)/\(Self.maxRetries))\n".utf8
                    ))
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw error
            } catch {
                lastError = error
                // Network errors are retryable.
                if attempt < Self.maxRetries {
                    let delay = Double(attempt) * 2.0
                    FileHandle.standardError.write(Data(
                        "Claude API network error, retrying in \(Int(delay))s (attempt \(attempt)/\(Self.maxRetries))\n".utf8
                    ))
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                throw error
            }
        }

        throw EngineError.allRetriesFailed(Self.maxRetries, last: lastError)
    }

    private func callClaude(system: String, user: String) async throws -> Data {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let payload: [String: Any] = [
            "model": model,
            "max_tokens": 4096,
            "system": system,
            "messages": [
                ["role": "user", "content": user]
            ]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        let httpResponse = response as! HTTPURLResponse
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<unreadable>"
            throw EngineError.requestFailed(httpResponse.statusCode, body)
        }
        return data
    }

    // MARK: - Parsing

    private func parse(_ data: Data) throws -> SummaryResult {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]],
            let first = content.first,
            let text = first["text"] as? String
        else {
            throw EngineError.malformedResponse("missing content[0].text")
        }

        return try parseJSON(from: text)
    }

    private func parseJSON(from text: String) throws -> SummaryResult {
        // Strip markdown fences and any leading/trailing noise.
        var cleaned = text
        if let jsonStart = cleaned.firstIndex(of: "{"),
           let jsonEnd = cleaned.lastIndex(of: "}") {
            cleaned = String(cleaned[jsonStart...jsonEnd])
        }

        guard
            let data = cleaned.data(using: .utf8),
            let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let title = result["title"] as? String,
            let summary = result["summary"] as? String
        else {
            throw EngineError.malformedResponse("couldn't parse JSON from: \(String(text.prefix(300)))")
        }

        // Handle folder being NSNull, empty string, or "null" string.
        let folder: String?
        if let f = result["folder"] as? String, !f.isEmpty, f.lowercased() != "null" {
            folder = f
        } else {
            folder = nil
        }

        return SummaryResult(
            title: String(title.prefix(80)),
            summary: summary,
            folder: folder
        )
    }
}
