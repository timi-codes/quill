import AppKit
import CoreAudio
import Darwin
import Foundation

/// Monitors running applications to detect when a meeting/call app is actively
/// producing audio. When a call is detected, fires `onCallDetected` with the
/// app name so the UI can prompt the user for confirmation. When the call app
/// goes silent for the configured timeout, fires `onCallEnded`.
@MainActor
final class CallMonitor {
    /// Fired when a call is first detected — the UI should prompt for approval.
    var onCallDetected: ((_ app: String) -> Void)?
    /// Fired when the call app goes silent / quits past the silence timeout.
    var onCallEnded: (() -> Void)?

    private var timer: Timer?
    /// The app tag we're currently tracking (nil = no active call).
    private(set) var activeApp: String?
    /// Whether the user approved recording for the current call.
    private(set) var approved = false
    private var prompted = false
    private var silentSince: Date?
    /// When we first saw a potential call — we wait for sustained audio
    /// before prompting to filter out notification dings.
    private var audioDetectedSince: Date?
    private var pendingApp: String?
    private let silenceTimeout: TimeInterval

    /// Seconds of continuous audio before we consider it a real call.
    private static let audioConfirmationDelay: TimeInterval = 15

    /// Process path fragments and display-friendly tags for known meeting apps.
    /// We match against the executable path of audio-producing processes.
    private static let knownApps: [(pathFragment: String, tag: String)] = [
        ("zoom.us", "zoom"),
        ("Microsoft Teams", "teams"),
        ("Slack", "slack"),
        ("FaceTime", "facetime"),
        ("Discord", "discord"),
        ("Webex", "webex"),
    ]

    /// Path fragments for browser processes — when any browser helper is
    /// producing audio and "meet" is configured, we prompt for recording.
    private static let browserPathFragments: [String] = [
        "google chrome",
        "safari",
        "thebrowser",
        "brave browser",
        "microsoft edge",
        "firefox",
    ]

    init() {
        self.silenceTimeout = TimeInterval(Config.autoRecordSilenceTimeout())
    }

    func start() {
        guard Config.autoRecordEnabled(), timer == nil else { return }
        let configuredApps = Set(Config.autoRecordApps().map { $0.lowercased() })

        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.poll(configuredApps: configuredApps)
            }
        }
        FileHandle.standardError.write(Data(
            "call monitor active · watching for: \(configuredApps.sorted().joined(separator: ", "))\n".utf8
        ))
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        resetState()
    }

    /// Called by the AppController when the user approves recording.
    func userApproved() {
        approved = true
    }

    /// Called by the AppController when the user dismisses the prompt.
    func userDismissed() {
        prompted = true
        approved = false
    }

    private func resetState() {
        activeApp = nil
        approved = false
        prompted = false
        silentSince = nil
        pendingApp = nil
        audioDetectedSince = nil
    }

    private func poll(configuredApps: Set<String>) {
        // Get process paths for every PID currently producing audio.
        let audioProcessPaths = Self.audioProducingProcessPaths()

        // Match audio-producing process paths against known meeting apps.
        var detected: String? = nil
        for path in audioProcessPaths {
            let lower = path.lowercased()

            // Check native meeting apps by path.
            for known in Self.knownApps {
                guard configuredApps.contains(known.tag) else { continue }
                if lower.contains(known.pathFragment.lowercased()) {
                    detected = known.tag
                    break
                }
            }
            if detected != nil { break }

            // Check browsers — if any browser helper is producing audio and
            // "meet" is configured, treat it as a potential call.
            if configuredApps.contains("meet") {
                for browser in Self.browserPathFragments {
                    if lower.contains(browser) {
                        detected = "meet"
                        break
                    }
                }
            }
            if detected != nil { break }
        }

        if let detected {
            silentSince = nil
            if activeApp == nil && !prompted {
                if pendingApp == detected, let since = audioDetectedSince {
                    // Audio has been sustained — check if long enough.
                    if Date().timeIntervalSince(since) >= Self.audioConfirmationDelay {
                        activeApp = detected
                        pendingApp = nil
                        audioDetectedSince = nil
                        FileHandle.standardError.write(Data(
                            "call confirmed: \(detected) — prompting user\n".utf8
                        ))
                        onCallDetected?(detected)
                        prompted = true
                    }
                } else {
                    // First detection — start the confirmation timer.
                    pendingApp = detected
                    audioDetectedSince = Date()
                }
            }
        } else {
            // Audio stopped — reset pending detection (was just a ding).
            if pendingApp != nil {
                pendingApp = nil
                audioDetectedSince = nil
            }
            if activeApp != nil {
                if silentSince == nil {
                    silentSince = Date()
                }
                if let silentSince, Date().timeIntervalSince(silentSince) >= silenceTimeout {
                    FileHandle.standardError.write(Data(
                        "call ended: \(activeApp!) silent for \(Int(silenceTimeout))s\n".utf8
                    ))
                    let wasApproved = approved
                    resetState()
                    if wasApproved {
                        onCallEnded?()
                    }
                }
            }
        }
    }

    /// Returns the executable paths of all processes currently producing audio.
    /// We resolve PIDs to paths so we can match against app names regardless
    /// of whether the process is a main app or a helper/renderer subprocess.
    private static func audioProducingProcessPaths() -> [String] {
        var paths: [String] = []

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        )
        guard status == noErr, size > 0 else { return paths }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objectIDs
        )
        guard status == noErr else { return paths }

        for objectID in objectIDs {
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            let pidStatus = AudioObjectGetPropertyData(
                objectID, &pidAddress, 0, nil, &pidSize, &pid
            )
            guard pidStatus == noErr, pid > 0 else { continue }

            // Check if this process is actively producing audio.
            var isRunning: UInt32 = 0
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunning,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            let runningStatus = AudioObjectGetPropertyData(
                objectID, &runningAddress, 0, nil, &runningSize, &isRunning
            )
            guard runningStatus == noErr, isRunning != 0 else { continue }

            // Resolve PID to executable path.
            var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
            let pathLen = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
            if pathLen > 0 {
                pathBuffer[Int(pathLen)] = 0
                let path = pathBuffer.withUnsafeBufferPointer { buf in
                    String(cString: buf.baseAddress!)
                }
                paths.append(path)
            }
        }

        return paths
    }
}
