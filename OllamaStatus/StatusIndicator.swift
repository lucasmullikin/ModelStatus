import AppKit

/// Manages the unified menu bar status indicator for all Ollama instances
final class StatusIndicator {
    let statusItem: NSStatusItem
    private var currentStatuses: [InstanceStatus] = []

    init() {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateDisplay(statuses: [])
    }

    func updateStatuses(_ statuses: [InstanceStatus]) {
        self.currentStatuses = statuses
        updateDisplay(statuses: statuses)
    }

    private func updateDisplay(statuses: [InstanceStatus]) {
        let attributedTitle = NSMutableAttributedString()

        // Llama emoji prefix
        let prefixAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12)
        ]
        attributedTitle.append(NSAttributedString(string: "🦙 ", attributes: prefixAttrs))

        // Status icons for each instance
        if statuses.isEmpty {
            let instances = ConfigManager.shared.instances
            for _ in instances {
                attributedTitle.append(styledIcon("?", color: .systemGray))
            }
        } else {
            for status in statuses {
                let (icon, color) = iconAndColor(for: status.status)
                attributedTitle.append(styledIcon(icon, color: color))
            }
        }

        DispatchQueue.main.async {
            self.statusItem.button?.attributedTitle = attributedTitle
            self.statusItem.button?.toolTip = self.buildTooltip(statuses: statuses)
        }
    }

    private func styledIcon(_ icon: String, color: NSColor) -> NSAttributedString {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color
        ]
        return NSAttributedString(string: icon, attributes: attrs)
    }

    private func iconAndColor(for status: OllamaStatus) -> (String, NSColor) {
        switch status {
        case .active:
            return ("●", .systemGreen)
        case .idle:
            return ("○", .systemYellow)
        case .unreachable:
            return ("✗", .systemRed)
        }
    }

    private func buildTooltip(statuses: [InstanceStatus]) -> String {
        if statuses.isEmpty {
            return "Checking Ollama instances..."
        }

        return statuses.map { status in
            let statusText: String
            switch status.status {
            case .active:
                if let model = status.modelName {
                    statusText = "Model loaded (\(model))"
                } else {
                    statusText = "Model loaded"
                }
            case .idle:
                statusText = "Running (no models)"
            case .unreachable:
                statusText = "Unreachable"
            }
            return "\(status.instance.name): \(statusText)"
        }.joined(separator: "\n")
    }

    func setMenu(_ menu: NSMenu) {
        statusItem.menu = menu
    }
}
