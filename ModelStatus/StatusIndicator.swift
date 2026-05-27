import AppKit

@MainActor
final class StatusIndicator {
    let statusItem: NSStatusItem

    /// v1.0: brain-silhouette template image extracted from the new app icon.
    /// Loaded from Bundle.main (ModelStatus/Resources/MenuBarIcon.png).
    /// macOS auto-tints (black for light menu bar, white for dark). Falls
    /// back to the 🧠 emoji if the image isn't bundled (e.g. dev builds
    /// before scripts/install-icon.sh ran).
    private static let templateImage: NSImage? = {
        guard let img = NSImage(named: "MenuBarIcon") else { return nil }
        img.isTemplate = true
        return img
    }()

    init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let img = Self.templateImage, let button = statusItem.button {
            // Place the brain glyph image to the LEFT of the colored status
            // dots (the attributedTitle text). Image + title side-by-side.
            button.image = img
            button.imagePosition = .imageLeft
            button.imageHugsTitle = true
        }
        updateStatuses([])
    }

    func updateStatuses(_ statuses: [ServerStatus]) {
        let title = NSMutableAttributedString()
        // Emoji fallback ONLY when the bundled template image isn't found
        // (e.g. dev source-tree builds without ./scripts/install-icon.sh having
        // run). When the image IS present, NSStatusItem.button.image renders
        // it to the left and we skip the prefix to avoid double-rendering.
        if Self.templateImage == nil {
            title.append(NSAttributedString(string: "\u{1F9E0} ", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        }

        let items: [(String, NSColor)] = statuses.isEmpty
            ? ConfigManager.shared.instances.map { _ in ("?", NSColor.systemGray) }
            : statuses.map { iconAndColor(for: $0) }

        for (i, (icon, color)) in items.enumerated() {
            if i > 0 { title.append(NSAttributedString(string: " ")) }
            title.append(NSAttributedString(string: icon, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .bold),
                .foregroundColor: color
            ]))
        }

        statusItem.button?.attributedTitle = title
        statusItem.button?.toolTip = statuses.isEmpty ? "Checking..." :
            statuses.map { "\($0.instance.name): \(statusLabel($0))" }.joined(separator: "\n")
        statusItem.button?.setAccessibilityLabel(accessibilityLabel(for: statuses))
    }

    func setMenu(_ menu: NSMenu) { statusItem.menu = menu }

    private func accessibilityLabel(for statuses: [ServerStatus]) -> String {
        if statuses.isEmpty { return "ModelStatus: checking" }
        return "ModelStatus: " + statuses.map { "\($0.instance.name) \(statusLabel($0))" }.joined(separator: ", ")
    }

    /// Generating dot only shown for Ollama (capability flag reportsGenerating=true).
    /// For other providers we collapse generating → active to avoid lying.
    private func iconAndColor(for s: ServerStatus) -> (String, NSColor) {
        let effective: ServerState = (s.detectedKind == .ollama) ? s.state :
            (s.state == .generating ? .active : s.state)
        switch effective {
        case .generating:  return ("\u{25CF}", .systemBlue)
        case .active:      return ("\u{25CF}", .systemGreen)
        case .idle:        return ("\u{25CB}", .systemYellow)
        case .unreachable: return ("\u{2717}", .systemRed)
        }
    }

    private func statusLabel(_ s: ServerStatus) -> String {
        switch s.state {
        case .generating: return "Generating (\(s.loadedModels.map(\.name).joined(separator: ", ")))"
        case .active:     return "Active (\(s.loadedModels.map(\.name).joined(separator: ", ")))"
        case .idle:       return "Idle (\(s.availableModelCount) available)"
        case .unreachable: return "Unreachable"
        }
    }
}
