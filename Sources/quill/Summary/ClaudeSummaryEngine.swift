import Foundation

/// Calls the Claude API to generate a title, summary, and classify the
/// recording into one of the user's existing note folders.
struct ClaudeSummaryEngine: SummaryEngine {
    enum EngineError: Error, CustomStringConvertible {
        case missingAPIKey
        case requestFailed(Int, String)
        case malformedResponse(String)

        var description: String {
            switch self {
            case .missingAPIKey:
                return "no Claude API key — set summary.api_key in ~/.config/quill/config.json or ANTHROPIC_API_KEY env var"
            case .requestFailed(let status, let body):
                return "Claude API returned \(status): \(body)"
            case .malformedResponse(let detail):
                return "unexpected Claude API response: \(detail)"
            }
        }
    }

    private let apiKey: String
    private let model: String

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
        let folderDescriptions: String
        if folders.isEmpty {
            folderDescriptions = "No existing folders."
        } else {
            folderDescriptions = folders.map { ctx in
                if let about = ctx.about {
                    return "### \(ctx.name)\n\(about)"
                } else {
                    return "### \(ctx.name)\n(no description)"
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

        Rules for folder classification:
        - Read each folder's context.md description carefully
        - Match the meeting's content (topics discussed, people mentioned, project context) against the folder descriptions
        - Pick the folder that best matches the meeting's context
        - Only pick a folder if you are reasonably confident it matches
        - Return null if no folder is a good match
        """

        let userMessage = """
        ## Transcript
        \(transcript)

        ## Project Folders
        \(folderDescriptions)
        """

        let body = try await callClaude(system: systemPrompt, user: userMessage)
        return try parse(body)
    }

    private func callClaude(system: String, user: String) async throws -> Data {
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("application/json", forHTTPHeaderField: "content-type")

        let payload: [String: Any] = [
            "model": model,
            "max_tokens": 2048,
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

    private func parse(_ data: Data) throws -> SummaryResult {
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = json["content"] as? [[String: Any]],
            let first = content.first,
            let text = first["text"] as? String
        else {
            throw EngineError.malformedResponse("missing content[0].text")
        }

        // Claude may wrap JSON in markdown fences — strip them.
        let cleaned = text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard
            let resultData = cleaned.data(using: .utf8),
            let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any],
            let title = result["title"] as? String,
            let summary = result["summary"] as? String
        else {
            throw EngineError.malformedResponse("couldn't parse JSON from: \(text.prefix(200))")
        }

        let folder = result["folder"] as? String
        return SummaryResult(title: title, summary: summary, folder: folder)
    }
}
