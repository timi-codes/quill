import Foundation

/// Optional user config at ~/.config/quill/config.json:
///
///     {
///       "recordings_dir": "~/Recordings",
///       "transcription": { "enabled": true, "engine": "parakeet" },
///       "mic_voice_processing": true,
///       "on_stop": "my-hook"
///     }
///
/// Resolution order for the recordings root: --out flag > config file >
/// ~/Recordings. `on_stop` is a shell command spawned with the session
/// directory as its argument — after the transcript is written, or right
/// after recording when transcription is disabled.
enum Config {
    static let path = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/quill/config.json")

    static let defaultRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Recordings", isDirectory: true)

    /// The configured recordings root, or nil if no config file / no key.
    static func recordingsDir() -> URL? {
        guard let dir = load()?["recordings_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Shell command to spawn after each session's transcript is written (or
    /// after recording, if transcription is disabled), or nil.
    static func onStop() -> String? {
        guard let cmd = load()?["on_stop"] as? String, !cmd.isEmpty else { return nil }
        return cmd
    }

    /// Whether finished recordings are transcribed automatically. Default on.
    static func transcriptionEnabled() -> Bool {
        transcription()?["enabled"] as? Bool ?? true
    }

    /// Configured engine name. Only "parakeet" ships today; the coordinator
    /// warns and falls back for anything else.
    static func transcriptionEngine() -> String {
        transcription()?["engine"] as? String ?? "parakeet"
    }

    private static func transcription() -> [String: Any]? {
        load()?["transcription"] as? [String: Any]
    }

    // MARK: - Summary

    /// Whether summaries are generated after transcription. Default off (needs
    /// an API key to do anything).
    static func summaryEnabled() -> Bool {
        summary()?["enabled"] as? Bool ?? false
    }

    /// Claude API key for summary generation. Falls back to ANTHROPIC_API_KEY
    /// environment variable.
    static func summaryAPIKey() -> String? {
        if let key = summary()?["api_key"] as? String, !key.isEmpty { return key }
        if let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !env.isEmpty { return env }
        return nil
    }

    /// Claude model to use for summaries. Defaults to claude-sonnet-4-6.
    static func summaryModel() -> String {
        summary()?["model"] as? String ?? "claude-sonnet-4-6"
    }

    private static func summary() -> [String: Any]? {
        load()?["summary"] as? [String: Any]
    }

    // MARK: - Notes directory

    /// Directory containing subfolders for projects/companies. Transcripts and
    /// summaries are routed here after AI classification.
    static func notesDir() -> URL? {
        guard let dir = load()?["notes_dir"] as? String, !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
    }

    // MARK: - Auto-record

    static func autoRecordEnabled() -> Bool {
        autoRecord()?["enabled"] as? Bool ?? false
    }

    /// Apps to watch for active calls. Default set covers the major players.
    static func autoRecordApps() -> [String] {
        autoRecord()?["apps"] as? [String]
            ?? ["zoom", "meet", "teams", "slack", "facetime", "discord", "webex"]
    }

    /// Seconds of silence before auto-stopping. Default 30.
    static func autoRecordSilenceTimeout() -> Int {
        autoRecord()?["silence_timeout_s"] as? Int ?? 30
    }

    private static func autoRecord() -> [String: Any]? {
        load()?["auto_record"] as? [String: Any]
    }

    // MARK: - Mic

    /// Apple voice processing (acoustic echo cancellation) on the mic, so
    /// speaker playback doesn't bleed into the mic track and get transcribed
    /// as "me". Default off — the live voice unit ducks all other playback,
    /// and on headphones there's no echo to cancel anyway. Set true when
    /// recording meetings through the speakers.
    static func micVoiceProcessing() -> Bool {
        load()?["mic_voice_processing"] as? Bool ?? false
    }

    /// Parse the config file. A malformed config is reported on stderr rather
    /// than silently ignored — recordings landing in an unexpected place is
    /// worse than a warning.
    private static func load() -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard
            let data = try? Data(contentsOf: path),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            FileHandle.standardError.write(Data(
                "warning: \(path.path) is not valid JSON — ignoring config\n".utf8
            ))
            return nil
        }
        return json
    }

    /// Resolve the recordings root from an optional CLI override.
    static func resolveRoot(cliOverride: String?) -> URL {
        if let cliOverride {
            return URL(
                fileURLWithPath: (cliOverride as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }
        return recordingsDir() ?? defaultRoot
    }
}
