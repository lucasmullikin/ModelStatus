import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusIndicator: StatusIndicator!
    private let monitor = OllamaMonitor()
    private var settingsController: SettingsWindowController?
    private var currentStatuses: [InstanceStatus] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusIndicator = StatusIndicator()
        rebuildMenu()
        startMonitoring()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task {
            await monitor.stopPolling()
        }
    }

    private func startMonitoring() {
        Task {
            await monitor.startPolling { [weak self] statuses in
                self?.currentStatuses = statuses
                DispatchQueue.main.async {
                    self?.statusIndicator.updateStatuses(statuses)
                    self?.rebuildMenu()
                }
            }
        }
    }

    private func restartMonitoring() {
        Task {
            await monitor.stopPolling()
            currentStatuses = []
            statusIndicator.updateStatuses([])
            await monitor.startPolling { [weak self] statuses in
                self?.currentStatuses = statuses
                DispatchQueue.main.async {
                    self?.statusIndicator.updateStatuses(statuses)
                    self?.rebuildMenu()
                }
            }
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // Title
        let titleItem = NSMenuItem(title: "Ollama Status", action: nil, keyEquivalent: "")
        titleItem.attributedTitle = NSAttributedString(
            string: "Ollama Status",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
        )
        menu.addItem(titleItem)

        menu.addItem(NSMenuItem.separator())

        // Instance statuses
        let showURLs = ConfigManager.shared.showURLs
        if currentStatuses.isEmpty {
            let instances = ConfigManager.shared.instances
            for instance in instances {
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.attributedTitle = styledStatusLine(icon: "?", color: .systemGray, name: instance.name, status: "Checking...", url: showURLs ? instance.url : nil)
                menu.addItem(item)
            }
        } else {
            for status in currentStatuses {
                let (icon, color, statusText) = menuInfo(for: status)
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.attributedTitle = styledStatusLine(icon: icon, color: color, name: status.instance.name, status: statusText, url: showURLs ? status.instance.url : nil)
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // Legend
        let legendHeader = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        legendHeader.attributedTitle = NSAttributedString(
            string: "Legend:",
            attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]
        )
        menu.addItem(legendHeader)

        menu.addItem(styledLegendItem(icon: "●", color: .systemGreen, text: "Model loaded in memory"))
        menu.addItem(styledLegendItem(icon: "○", color: .systemYellow, text: "Running (no models)"))
        menu.addItem(styledLegendItem(icon: "✗", color: .systemRed, text: "Not running"))

        menu.addItem(NSMenuItem.separator())

        // Show URLs toggle
        let showURLsItem = NSMenuItem(title: "Show IP Addresses", action: #selector(toggleShowURLs), keyEquivalent: "")
        showURLsItem.target = self
        showURLsItem.state = ConfigManager.shared.showURLs ? .on : .off
        menu.addItem(showURLsItem)

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Quit
        let quitItem = NSMenuItem(title: "Quit OllamaStatus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusIndicator.setMenu(menu)
    }

    private func menuInfo(for status: InstanceStatus) -> (String, NSColor, String) {
        switch status.status {
        case .active:
            if let model = status.modelName {
                return ("●", .systemGreen, "Model loaded (\(model))")
            }
            return ("●", .systemGreen, "Model loaded")
        case .idle:
            return ("○", .systemYellow, "Running (no models)")
        case .unreachable:
            return ("✗", .systemRed, "Not reachable")
        }
    }

    private func styledStatusLine(icon: String, color: NSColor, name: String, status: String, url: String?) -> NSAttributedString {
        let result = NSMutableAttributedString()

        // Colored icon
        result.append(NSAttributedString(
            string: "\(icon) ",
            attributes: [.foregroundColor: color, .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .medium)]
        ))

        // Instance name (bold)
        result.append(NSAttributedString(
            string: name,
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]
        ))

        // Spacing + status
        result.append(NSAttributedString(
            string: "      \(status)",
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]
        ))

        // URL on new line if enabled
        if let url = url {
            // Extract just host:port from URL
            let displayURL = URL(string: url).map { "\($0.host ?? "")\($0.port.map { ":\($0)" } ?? "")" } ?? url
            result.append(NSAttributedString(
                string: "\n     \(displayURL)",
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]
            ))
        }

        return result
    }

    private func styledLegendItem(icon: String, color: NSColor, text: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: "  \(icon) ",
            attributes: [.foregroundColor: color, .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)]
        ))
        result.append(NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        ))

        item.attributedTitle = result
        return item
    }

    @objc private func toggleShowURLs() {
        ConfigManager.shared.showURLs.toggle()
        rebuildMenu()
    }

    @objc private func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController()
            settingsController?.onConfigChanged = { [weak self] in
                self?.restartMonitoring()
            }
        }
        settingsController?.showWindow()
    }
}

// Explicit main entry point for SPM
@main
struct OllamaStatusApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
