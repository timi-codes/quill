import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let toggleItem: NSMenuItem
    private let idleImage: NSImage?
    private let recordingImage: NSImage?

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onRestart: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        let menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: "Start recording",
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        menu.addItem(toggleItem)

        let openFolder = NSMenuItem(
            title: "Open recordings folder",
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
        )
        menu.addItem(openFolder)

        menu.addItem(.separator())

        let restart = NSMenuItem(
            title: "Restart quill",
            action: #selector(restartClicked),
            keyEquivalent: "q"
        )
        menu.addItem(restart)

        idleImage = Self.featherImage(color: nil)
        recordingImage = Self.featherImage(color: .systemRed)

        for item in [toggleItem, openFolder, restart] {
            item.target = self
        }

        statusItem.menu = menu

        if let button = statusItem.button {
            button.image = idleImage
            button.imagePosition = .imageLeft
        }
    }

    /// Reflect recording state in the icon and menu bar text. While recording,
    /// the feather turns red and the elapsed time is shown directly in the menu
    /// bar (always visible without clicking). Call once a second while recording.
    func update(recording: Bool, elapsed: String?) {
        stateLabel.title = recording ? "● recording · \(elapsed ?? "0:00")" : "idle"
        toggleItem.title = recording ? "Stop recording" : "Start recording"

        if let button = statusItem.button {
            button.image = recording ? recordingImage : idleImage
            if recording {
                let attrs: [NSAttributedString.Key: Any] = [
                    .foregroundColor: NSColor.systemRed,
                    .font: NSFont.monospacedDigitSystemFont(
                        ofSize: NSFont.systemFontSize(for: .small),
                        weight: .medium
                    ),
                ]
                button.attributedTitle = NSAttributedString(
                    string: " \(elapsed ?? "0:00")",
                    attributes: attrs
                )
            } else {
                button.title = ""
            }
        }
    }

    /// Show transcription progress/failure as a second status line in the
    /// menu; nil hides it. Independent of recording state — a new recording
    /// can run while the last one transcribes.
    func updateTranscription(_ text: String?) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
    }

    // Inlined Lucide feather SVG. Keeping it in source means the executable
    // has no separate resource bundle to install alongside it — true
    // single-binary.
    private static func featherSVG(color: String) -> String {
        """
        <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
        viewBox="0 0 24 24" fill="none" stroke="\(color)" stroke-width="1.5" \
        stroke-linecap="round" stroke-linejoin="round">\
        <path d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>\
        <path d="M16 8 2 22"/>\
        <path d="M17.5 15H9"/>\
        </svg>
        """
    }

    private static func featherImage(color: NSColor?) -> NSImage? {
        if color != nil {
            // Non-template red image for recording state.
            guard let data = featherSVG(color: "#FF3B30").data(using: .utf8),
                  let image = NSImage(data: data)
            else { return nil }
            image.isTemplate = false
            image.size = NSSize(width: 16, height: 16)
            return image
        } else {
            // Template image for idle state — adapts to light/dark menu bar.
            guard let data = featherSVG(color: "currentColor").data(using: .utf8),
                  let image = NSImage(data: data)
            else { return nil }
            image.isTemplate = true
            image.size = NSSize(width: 16, height: 16)
            return image
        }
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func restartClicked() { onRestart?() }
}
