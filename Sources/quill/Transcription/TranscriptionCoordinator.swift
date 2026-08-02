import Foundation

/// Post-recording pipeline: a serial queue of session folders to transcribe.
/// mic.caf → "me", system.caf → "them"; each track's segments are shifted by
/// its start offset, merged by timestamp, and written as transcript.json
/// (canonical) plus transcript.md (readable). The filesystem is the queue —
/// `resumePending()` rescans at launch, so a crash or quit mid-transcription
/// just retries on next run. Failures append to the session's transcribe.log
/// and never block later jobs.
actor TranscriptionCoordinator {
    enum Status: Sendable {
        case idle
        case transcribing(session: String, queued: Int)
        case failed(session: String)
    }

    private var queue: [URL] = []
    private var draining = false
    private var engine: TranscriptionEngine?
    private var diarizer: SpeakerDiarizer?
    private var summaryEngine: SummaryEngine?
    private var lastFailure: String?
    private var statusHandler: (@Sendable (Status) -> Void)?

    func setStatusHandler(_ handler: @escaping @Sendable (Status) -> Void) {
        statusHandler = handler
    }

    /// Queue a finished session. With transcription disabled in config, the
    /// on_stop hook still fires — it just gets an untranscribed folder.
    func enqueue(_ sessionDir: URL) {
        guard Config.transcriptionEnabled() else {
            runHook(for: sessionDir)
            return
        }
        queue.append(sessionDir)
        drainIfIdle()
    }

    /// Scan the recordings root for sessions that finished (meta.json exists)
    /// but were never transcribed. Folder names sort chronologically, so
    /// oldest-first is a name sort.
    func resumePending(root: URL) {
        guard Config.transcriptionEnabled() else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return }

        let fm = FileManager.default
        let pending = entries
            .filter {
                fm.fileExists(atPath: $0.appendingPathComponent("meta.json").path)
                    && !fm.fileExists(atPath: $0.appendingPathComponent("transcript.json").path)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for dir in pending where !queue.contains(dir) {
            queue.append(dir)
        }
        if !pending.isEmpty {
            FileHandle.standardError.write(Data(
                "resuming \(pending.count) untranscribed session(s)\n".utf8
            ))
        }
        drainIfIdle()
    }

    // MARK: -

    private func drainIfIdle() {
        guard !draining, !queue.isEmpty else { return }
        draining = true
        lastFailure = nil
        Task { await drain() }
    }

    private func drain() async {
        while !queue.isEmpty {
            let dir = queue.removeFirst()
            publish(.transcribing(session: dir.lastPathComponent, queued: queue.count))
            do {
                try await transcribe(dir)
                notifyUser(title: "quill — transcript ready", body: dir.lastPathComponent)

                // Post-transcription: summarize, classify, and route files.
                await summarizeAndRoute(dir)

                runHook(for: dir)
            } catch {
                log(dir, "transcription failed: \(error)")
                lastFailure = dir.lastPathComponent
                notifyUser(
                    title: "quill — transcription failed",
                    body: "\(dir.lastPathComponent) — see transcribe.log"
                )
            }
        }
        await engine?.release()
        engine = nil
        diarizer?.release()
        diarizer = nil
        publish(lastFailure.map { .failed(session: $0) } ?? .idle)
        draining = false
        // An enqueue that landed between the loop exiting and the release
        // finishing would otherwise sit until the next enqueue.
        drainIfIdle()
    }

    private func transcribe(_ dir: URL) async throws {
        let meta = try SessionMeta.read(from: dir)
        let engine = try await preparedEngine()

        var merged: [Transcript.Segment] = []
        for track in meta.tracks {
            let audio = dir.appendingPathComponent(track.file)
            guard FileManager.default.fileExists(atPath: audio.path) else {
                log(dir, "skipping missing track \(track.file)")
                continue
            }
            log(dir, "transcribing \(track.file) (\(engine.name))")
            let segments: [TranscriptSegment]
            do {
                segments = try await engine.transcribe(audio)
            } catch {
                log(dir, "skipping \(track.file): \(error)")
                continue
            }

            // Run speaker diarization on this track to identify individual
            // speakers within it (e.g. when the other person's voice bleeds
            // into the mic track).
            let diarSegments = await diarizeTrack(audio, dir: dir, trackFile: track.file)
            let labelMap = SpeakerAssigner.relabel(
                segments: diarSegments,
                trackLabel: track.speaker
            )

            let assigned = SpeakerAssigner.assign(
                transcriptSegments: segments.map { ($0.start, $0.end, $0.text) },
                diarization: diarSegments,
                trackLabel: track.speaker,
                offsetMs: track.offsetMs
            )

            merged += assigned.map { seg in
                let speaker = labelMap[seg.speaker] ?? seg.speaker
                return Transcript.Segment(
                    speaker: speaker,
                    start_ms: seg.startMs,
                    end_ms: seg.endMs,
                    text: seg.text
                )
            }
        }
        merged.sort { $0.start_ms < $1.start_ms }

        let transcript = Transcript(
            engine: engine.name,
            model: engine.model,
            created_at: ISO8601DateFormatter().string(from: Date()),
            segments: merged
        )
        try transcript.write(to: dir)
        log(dir, "done — \(merged.count) segments")
    }

    /// Best-effort diarization — returns empty on failure so transcription
    /// still works with the original me/them labels.
    private func diarizeTrack(_ audio: URL, dir: URL, trackFile: String) async -> [SpeakerSegment] {
        do {
            let diar = try await preparedDiarizer()
            log(dir, "diarizing \(trackFile)")
            let segments = try await diar.diarize(audio)
            let speakerCount = Set(segments.map(\.speaker)).count
            log(dir, "diarization found \(speakerCount) speaker(s) in \(trackFile)")
            return segments
        } catch {
            log(dir, "diarization skipped for \(trackFile): \(error)")
            return []
        }
    }

    private func preparedDiarizer() async throws -> SpeakerDiarizer {
        if let diarizer { return diarizer }
        let diar = SpeakerDiarizer()
        try await diar.prepare()
        diarizer = diar
        return diar
    }

    private func preparedEngine() async throws -> TranscriptionEngine {
        if let engine { return engine }
        let configured = Config.transcriptionEngine()
        if configured != "parakeet" {
            FileHandle.standardError.write(Data(
                "warning: unknown transcription engine \"\(configured)\" — using parakeet\n".utf8
            ))
        }
        let engine = ParakeetEngine()
        try await engine.prepare()
        self.engine = engine
        return engine
    }

    /// Fires the configured on_stop shell command with the session directory
    /// as its sole argument, after the transcript exists (or immediately after
    /// recording when transcription is disabled).
    private func runHook(for dir: URL) {
        guard let cmd = Config.onStop() else { return }
        let task = Process()
        task.launchPath = "/bin/sh"
        task.arguments = ["-c", "\(cmd) \"$0\"", dir.path]
        do {
            try task.run()
        } catch {
            log(dir, "on_stop hook failed to launch: \(error)")
        }
    }

    private func log(_ dir: URL, _ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = dir.appendingPathComponent("transcribe.log")
        if let handle = FileHandle(forWritingAtPath: url.path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }

    // MARK: - Summary & routing

    /// After transcription, use Claude to generate a title + summary, then
    /// route transcript.md and summary.md into the appropriate notes subfolder.
    private func summarizeAndRoute(_ dir: URL) async {
        guard Config.summaryEnabled() else { return }

        // Read the transcript we just wrote.
        let transcriptURL = dir.appendingPathComponent("transcript.md")
        guard let transcriptData = try? Data(contentsOf: transcriptURL),
              let transcript = String(data: transcriptData, encoding: .utf8),
              !transcript.isEmpty
        else {
            log(dir, "summary skipped — no transcript.md")
            return
        }

        // Discover existing folders and read their context.md for context.
        let folderContexts = loadFolderContexts()

        // Run AI.
        let result: SummaryResult
        do {
            let engine = try prepareSummaryEngine()
            result = try await engine.process(
                transcript: transcript,
                folders: folderContexts
            )
            log(dir, "summary generated — title: \(result.title), folder: \(result.folder ?? "none")")
        } catch {
            log(dir, "summary failed: \(error)")
            notifyUser(title: "quill — summary failed", body: "\(error)")
            return
        }

        // Write summary.md into the session directory.
        let summaryContent = "# \(result.title)\n\n\(result.summary)\n"
        try? Data(summaryContent.utf8).write(
            to: dir.appendingPathComponent("summary.md"),
            options: .atomic
        )

        // Update meta.json with the title.
        updateMetaTitle(dir: dir, title: result.title)

        // Route files to notes directory if configured.
        guard let notesRoot = Config.notesDir() else { return }
        let projectFolder: URL
        if let folder = result.folder {
            projectFolder = notesRoot.appendingPathComponent(folder, isDirectory: true)
        } else {
            projectFolder = notesRoot.appendingPathComponent("Uncategorized", isDirectory: true)
        }

        // Always route into a Meetings subfolder.
        let meetingsFolder = projectFolder.appendingPathComponent("Meetings", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: meetingsFolder, withIntermediateDirectories: true)

        // File name: "2026.08.01 — Sprint Planning"
        let datePrefix = dir.lastPathComponent.prefix(10) // yyyy.MM.dd
        let safeName = "\(datePrefix) — \(sanitize(result.title))"

        // Copy transcript and summary as separate files.
        let destTranscript = meetingsFolder.appendingPathComponent("\(safeName) — Transcript.md")
        let destSummary = meetingsFolder.appendingPathComponent("\(safeName) — Summary.md")

        try? fm.copyItem(at: transcriptURL, to: destTranscript)
        try? Data(summaryContent.utf8).write(to: destSummary, options: .atomic)

        log(dir, "routed to \(meetingsFolder.path)")
        notifyUser(
            title: "quill — \(result.title)",
            body: "Filed to \(result.folder ?? "Uncategorized")/Meetings"
        )
    }

    private func prepareSummaryEngine() throws -> SummaryEngine {
        if let engine = summaryEngine { return engine }
        let engine = try ClaudeSummaryEngine()
        summaryEngine = engine
        return engine
    }

    /// Load folder names and their context.md contents from the notes directory.
    private func loadFolderContexts() -> [FolderContext] {
        guard let notesRoot = Config.notesDir() else { return [] }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: notesRoot,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return entries.compactMap { url in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }
            let name = url.lastPathComponent
            guard !name.hasPrefix(".") else { return nil }

            // Read context.md if it exists.
            let aboutURL = url.appendingPathComponent("context.md")
            let about = try? String(contentsOf: aboutURL, encoding: .utf8)

            return FolderContext(name: name, about: about)
        }.sorted { $0.name < $1.name }
    }

    private func updateMetaTitle(dir: URL, title: String) {
        let metaURL = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: metaURL),
            var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        json["title"] = title
        if let updated = try? JSONSerialization.data(
            withJSONObject: json,
            options: [.prettyPrinted, .sortedKeys]
        ) {
            try? updated.write(to: metaURL, options: .atomic)
        }
    }

    /// Strip characters that are problematic in filenames.
    private func sanitize(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:*?\"<>|")
        return name.components(separatedBy: illegal).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
    }

    private func publish(_ status: Status) {
        statusHandler?(status)
    }
}

/// The slice of meta.json the coordinator needs: which files exist, who they
/// represent, and how far each track started after the earliest one.
private struct SessionMeta {
    struct Track {
        let file: String
        let speaker: String
        let offsetMs: Int
    }

    let tracks: [Track]

    enum MetaError: Error, CustomStringConvertible {
        case unreadable(URL)

        var description: String {
            switch self {
            case .unreadable(let url): return "can't parse \(url.path)"
            }
        }
    }

    static func read(from dir: URL) throws -> SessionMeta {
        let url = dir.appendingPathComponent("meta.json")
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let files = json["files"] as? [String: String]
        else { throw MetaError.unreadable(url) }

        // Sessions recorded before offsets were captured default to 0 —
        // tracks start within tens of milliseconds of each other anyway.
        let offsets = json["start_offset_ms"] as? [String: Int] ?? [:]
        var tracks: [Track] = []
        if let mic = files["mic"] {
            tracks.append(Track(file: mic, speaker: "me", offsetMs: offsets["mic"] ?? 0))
        }
        if let system = files["system"] {
            tracks.append(Track(file: system, speaker: "them", offsetMs: offsets["system"] ?? 0))
        }
        return SessionMeta(tracks: tracks)
    }
}

/// Canonical transcript. Property names are the JSON schema — this struct
/// exists to be serialized.
private struct Transcript: Codable {
    struct Segment: Codable {
        let speaker: String
        let start_ms: Int
        let end_ms: Int
        let text: String
    }

    let engine: String
    let model: String
    let created_at: String
    let segments: [Segment]

    /// Write transcript.json and render transcript.md. Both writes are atomic
    /// (temp file + rename), so a partially written transcript never exists on
    /// disk — resumePending treats presence of transcript.json as "done".
    func write(to dir: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self)
            .write(to: dir.appendingPathComponent("transcript.json"), options: .atomic)
        try Data(rendered(title: dir.lastPathComponent).utf8)
            .write(to: dir.appendingPathComponent("transcript.md"), options: .atomic)
    }

    private func rendered(title: String) -> String {
        var lines = ["# \(title)", "", "engine: \(engine) (\(model))", ""]
        for seg in segments {
            lines.append("**[\(Self.clock(seg.start_ms))] \(seg.speaker):** \(seg.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }
}
