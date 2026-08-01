import AppKit
import CoreAudio
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
    private let silenceTimeout: TimeInterval

    /// Bundle ID fragments and display-friendly tags for known meeting apps.
    private static let knownApps: [(bundleFragment: String, nameFragment: String)] = [
        ("us.zoom.xos", "zoom"),
        ("com.google.Chrome", "meet"),       // Google Meet runs in browser
        ("com.apple.Safari", "meet"),
        ("company.thebrowser.Browser", "meet"), // Arc
        ("com.microsoft.teams", "teams"),
        ("com.tinyspeck.slackmacgap", "slack"),
        ("com.apple.FaceTime", "facetime"),
        ("com.hnc.Discord", "discord"),
        ("com.cisco.webexmeetingsapp", "webex"),
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
        // Don't prompt again for this same call session — reset when the call
        // actually ends (silence timeout).
        prompted = true
        approved = false
    }

    private func resetState() {
        activeApp = nil
        approved = false
        prompted = false
        silentSince = nil
    }

    private func poll(configuredApps: Set<String>) {
        let running = NSWorkspace.shared.runningApplications
        let audioProducers = Self.audioProducingPIDs()

        // Find a running meeting app that is also producing audio.
        var detected: String? = nil
        for app in running {
            guard app.activationPolicy == .regular || app.activationPolicy == .accessory else {
                continue
            }
            let bundleID = app.bundleIdentifier?.lowercased() ?? ""
            let name = app.localizedName?.lowercased() ?? ""

            for known in Self.knownApps {
                let tag = known.nameFragment
                guard configuredApps.contains(tag) else { continue }
                if bundleID.contains(known.bundleFragment.lowercased()) || name.contains(tag) {
                    if audioProducers.contains(app.processIdentifier) {
                        detected = tag
                        break
                    }
                }
            }
            if detected != nil { break }
        }

        if let detected {
            silentSince = nil
            if activeApp == nil {
                activeApp = detected
                prompted = false
                approved = false
                FileHandle.standardError.write(Data(
                    "call detected: \(detected) — prompting user\n".utf8
                ))
                onCallDetected?(detected)
                prompted = true
            }
        } else if activeApp != nil {
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

    /// PIDs currently producing audio, queried via the CoreAudio HAL.
    private static func audioProducingPIDs() -> Set<pid_t> {
        var pids = Set<pid_t>()

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        )
        guard status == noErr, size > 0 else { return pids }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &objectIDs
        )
        guard status == noErr else { return pids }

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
            if runningStatus == noErr, isRunning != 0 {
                pids.insert(pid)
            }
        }

        return pids
    }
}
