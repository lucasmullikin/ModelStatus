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
        let titleItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        titleItem.attributedTitle = NSAttributedString(
            string: "Ollama Status",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 14), .foregroundColor: NSColor.white]
        )
        menu.addItem(titleItem)

        menu.addItem(NSMenuItem.separator())

        // Instance statuses
        if currentStatuses.isEmpty {
            let instances = ConfigManager.shared.instances
            for instance in instances {
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.attributedTitle = styledStatusLine(icon: "?", color: .systemGray, name: instance.name, status: "Checking...", modelName: nil, cpuPercent: nil, memoryMB: nil, lastActive: nil, clientIP: nil)
                menu.addItem(item)
            }
        } else {
            for status in currentStatuses {
                let (icon, color, statusText) = menuInfo(for: status)
                let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
                item.attributedTitle = styledStatusLine(icon: icon, color: color, name: status.instance.name, status: statusText, modelName: status.modelName, cpuPercent: status.cpuPercent, memoryMB: status.memoryMB, lastActive: status.lastActive, clientIP: status.clientIP)
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())

        // Legend
        let legendHeader = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        legendHeader.attributedTitle = NSAttributedString(
            string: "Legend:",
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.white]
        )
        menu.addItem(legendHeader)

        menu.addItem(styledLegendItem(icon: "●", color: .systemGreen, text: "Model loaded in memory"))
        menu.addItem(styledLegendItem(icon: "○", color: .systemYellow, text: "Running (no models)"))
        menu.addItem(styledLegendItem(icon: "✗", color: .systemRed, text: "Not running"))

        menu.addItem(NSMenuItem.separator())

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
            return ("●", .systemGreen, "Model loaded")
        case .idle:
            return ("○", .systemYellow, "Running (no models)")
        case .unreachable:
            return ("✗", .systemRed, "Not reachable")
        }
    }

    private func styledStatusLine(icon: String, color: NSColor, name: String, status: String, modelName: String?, cpuPercent: Double?, memoryMB: Int?, lastActive: Date?, clientIP: String?) -> NSAttributedString {
        let result = NSMutableAttributedString()

        // Colored icon
        result.append(NSAttributedString(
            string: "\(icon) ",
            attributes: [.foregroundColor: color, .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)]
        ))

        // Instance name (bold white)
        result.append(NSAttributedString(
            string: name,
            attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: NSColor.white]
        ))

        // Status in the icon color for emphasis
        result.append(NSAttributedString(
            string: "  \(status)",
            attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: color]
        ))

        // Model name with CPU% and memory
        if let model = modelName {
            result.append(NSAttributedString(
                string: "\n     📦 ",
                attributes: [.font: NSFont.systemFont(ofSize: 13)]
            ))
            result.append(NSAttributedString(
                string: model,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold), .foregroundColor: NSColor.white]
            ))
        }

        // Resource usage line (CPU + Memory)
        if cpuPercent != nil || memoryMB != nil {
            var resourceParts: [String] = []

            if let cpu = cpuPercent {
                let cpuIcon = cpu > 50 ? "⚡" : "💤"
                resourceParts.append(String(format: "\(cpuIcon) %.0f%%", cpu))
            }

            if let mem = memoryMB {
                let memStr = mem >= 1024 ? String(format: "%.1fGB", Double(mem) / 1024.0) : "\(mem)MB"
                resourceParts.append("💾 \(memStr)")
            }

            if !resourceParts.isEmpty {
                let resourceLine = resourceParts.joined(separator: "  ")
                let cpuColor: NSColor = (cpuPercent ?? 0) > 50 ? .systemOrange : .white
                result.append(NSAttributedString(
                    string: "\n     \(resourceLine)",
                    attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: cpuColor]
                ))
            }
        }

        // Client info - who's calling this Ollama
        if let client = clientIP {
            result.append(NSAttributedString(
                string: "\n     📡 ",
                attributes: [.font: NSFont.systemFont(ofSize: 12)]
            ))
            result.append(NSAttributedString(
                string: client,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.systemCyan]
            ))
        }

        // Last active time - just show elapsed
        if let lastActive = lastActive {
            let elapsed = Date().timeIntervalSince(lastActive)
            let agoStr: String
            if elapsed < 60 {
                agoStr = "\(Int(elapsed))s ago"
            } else if elapsed < 3600 {
                agoStr = "\(Int(elapsed / 60))m \(Int(elapsed.truncatingRemainder(dividingBy: 60)))s ago"
            } else {
                agoStr = "\(Int(elapsed / 3600))h ago"
            }

            result.append(NSAttributedString(
                string: "\n     🕐 ",
                attributes: [.font: NSFont.systemFont(ofSize: 12)]
            ))
            result.append(NSAttributedString(
                string: agoStr,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.white]
            ))
        }

        return result
    }

    private func styledLegendItem(icon: String, color: NSColor, text: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")

        let result = NSMutableAttributedString()
        result.append(NSAttributedString(
            string: "  \(icon) ",
            attributes: [.foregroundColor: color, .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)]
        ))
        result.append(NSAttributedString(
            string: text,
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.white]
        ))

        item.attributedTitle = result
        return item
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
