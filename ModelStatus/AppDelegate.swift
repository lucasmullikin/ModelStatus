import AppKit
import UserNotifications

struct EjectInfo {
    let modelName: String
    let instance: Instance
}

struct LoadInfo {
    let modelName: String
    let instance: Instance
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSMenuDelegate {
    private var statusIndicator: StatusIndicator!
    private let monitor = Monitor()
    private var settingsController: SettingsWindowController?
    private var welcomeController: WelcomeWindowController?
    private var currentStatuses: [ServerStatus] = []
    private var availableModelsByInstance: [UUID: [String]] = [:]
    private var capabilitiesByInstance: [UUID: ProviderCapabilities] = [:]

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusIndicator = StatusIndicator()
        UNUserNotificationCenter.current().delegate = self
        if ConfigManager.shared.notifyOnStateChange {
            requestNotificationPermission()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(showWelcome),
            name: .settingsRequestedWelcome, object: nil
        )
        rebuildMenu()
        startMonitoring()

        if !WelcomeWindowController.hasShownBefore {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showWelcome()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        let m = monitor
        Task { await m.stopPolling() }
    }

    private func startMonitoring() {
        let m = monitor
        Task {
            await m.startPolling(
                onStatusChange: { statuses in
                    Task { @MainActor in
                        guard let d = NSApp.delegate as? AppDelegate else { return }
                        d.currentStatuses = statuses
                        d.statusIndicator.updateStatuses(statuses)
                        d.rebuildMenu()
                    }
                },
                onReachabilityChange: { instance, reachable in
                    Task { @MainActor in
                        (NSApp.delegate as? AppDelegate)?.notifyReachability(instance: instance, reachable: reachable)
                    }
                }
            )
        }
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        menu.addItem(styledItem("Model Status", font: .boldSystemFont(ofSize: 14)))
        menu.addItem(.separator())

        if currentStatuses.isEmpty {
            for inst in ConfigManager.shared.instances {
                menu.addItem(headerItem(icon: "?", color: .systemGray, name: inst.name, text: "Checking..."))
            }
        } else {
            let compact = ConfigManager.shared.compactMode
            for (i, s) in currentStatuses.enumerated() {
                if i > 0 { menu.addItem(.separator()) }
                if compact {
                    addInstanceCompact(to: menu, status: s)
                } else {
                    addInstance(to: menu, status: s)
                }
            }
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(title: "Toggle Local Ollama…", action: #selector(toggleOllama), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        Task { @MainActor in
            let running = await Monitor.isLocalOllamaRunning()
            toggle.title = running ? "Stop Local Ollama" : "Start Local Ollama"
        }

        menu.addItem(.separator())

        let quickStart = NSMenuItem(title: "Show Quick Start…", action: #selector(showWelcome), keyEquivalent: "")
        quickStart.target = self
        menu.addItem(quickStart)

        let settings = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(NSMenuItem(title: "Quit ModelStatus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        menu.delegate = self
        statusIndicator.setMenu(menu)
    }

    // NSMenuDelegate — rebuild from latest currentStatuses right before showing so
    // the menu never displays stale state. Cheap: no network calls, just NSMenuItem rebuild.
    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        Task { @MainActor in
            self.rebuildMenu()
        }
    }

    private func addInstanceCompact(to menu: NSMenu, status: ServerStatus) {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let line = Formatters.compactLine(status: status)
        item.attributedTitle = NSAttributedString(
            string: line,
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
        )
        menu.addItem(item)
    }

    private func addInstance(to menu: NSMenu, status: ServerStatus) {
        let (icon, color, text) = statusInfo(status)
        menu.addItem(headerItem(icon: icon, color: color, name: status.instance.name, text: text))

        let caps = capabilitiesByInstance[status.instance.id] ?? ProviderCapabilities.openAI

        // Loaded models — eject only if provider supports it
        if !status.loadedModels.isEmpty {
            for m in status.loadedModels {
                let action: Selector? = caps.canEject ? #selector(ejectModel(_:)) : nil
                let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
                item.target = self
                if caps.canEject {
                    item.representedObject = EjectInfo(modelName: m.name, instance: status.instance)
                    item.toolTip = "Click to eject"
                }
                let t = NSMutableAttributedString()
                t.append(muted("     \u{23CF} "))
                t.append(mono(m.name, size: 12, weight: .semibold, color: .labelColor))
                if m.vramBytes > 0 { t.append(muted("  \(Formatters.bytes(m.vramBytes))")) }
                item.attributedTitle = t
                menu.addItem(item)
            }
        } else if status.state == .idle {
            menu.addItem(mutedItem("     \u{1F4E6} no models loaded"))
        }

        // VRAM total (only if provider reports VRAM and there's more than one model)
        if status.vramTotal > 0 && caps.reportsVRAM && status.loadedModels.count > 1 {
            menu.addItem(mutedItem("     \u{1F4BE} Total VRAM: \(Formatters.bytes(status.vramTotal))"))
        }

        // CPU + Memory (local only)
        var parts: [String] = []
        if let cpu = status.cpuPercent { parts.append(String(format: "%@ %.0f%%", cpu > 50 ? "\u{26A1}" : "\u{1F4A4}", cpu)) }
        if let mem = status.memoryMB { parts.append("\u{1F4BE} \(mem >= 1024 ? String(format: "%.1fGB", Double(mem)/1024) : "\(mem)MB")") }
        if !parts.isEmpty { menu.addItem(mutedItem("     \(parts.joined(separator: "  "))")) }

        if let c = status.clientIP { menu.addItem(mutedItem("     \u{1F4E1} \(c)")) }
        if let t = status.lastActive { menu.addItem(mutedItem("     \u{1F550} \(Formatters.elapsed(since: t))")) }
        if let lat = status.latencyMs { menu.addItem(mutedItem("     \u{1F4CA} \(lat)ms")) }

        // Available models + Load submenu (only if provider supports loading)
        if status.availableModelCount > 0 {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.attributedTitle = muted("     \u{1F4CB} \(status.availableModelCount) models available")
            if caps.canLoadModel {
                let submenu = NSMenu()
                submenu.addItem(NSMenuItem(title: "Load model into memory…", action: nil, keyEquivalent: ""))
                submenu.addItem(.separator())
                let cached = availableModelsByInstance[status.instance.id] ?? []
                if cached.isEmpty {
                    let loading = NSMenuItem(title: "Fetching list…", action: nil, keyEquivalent: "")
                    loading.isEnabled = false
                    submenu.addItem(loading)
                    let inst = status.instance
                    let m = monitor
                    Task { @MainActor [weak self] in
                        let names = await m.availableModels(for: inst)
                        let caps = await m.capabilities(for: inst)
                        self?.availableModelsByInstance[inst.id] = names
                        self?.capabilitiesByInstance[inst.id] = caps
                        self?.rebuildMenu()
                    }
                } else {
                    for name in cached {
                        let mi = NSMenuItem(title: name, action: #selector(loadModel(_:)), keyEquivalent: "")
                        mi.target = self
                        mi.representedObject = LoadInfo(modelName: name, instance: status.instance)
                        submenu.addItem(mi)
                    }
                }
                item.submenu = submenu
            }
            menu.addItem(item)
        }

        // Cache capabilities for next rebuild if we haven't yet
        if capabilitiesByInstance[status.instance.id] == nil {
            let inst = status.instance
            let m = monitor
            Task { @MainActor [weak self] in
                let caps = await m.capabilities(for: inst)
                self?.capabilitiesByInstance[inst.id] = caps
            }
        }
    }

    @objc private func ejectModel(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? EjectInfo else { return }
        let m = monitor
        Task { @MainActor in
            await m.ejectModel(name: info.modelName, on: info.instance)
        }
    }

    @objc private func loadModel(_ sender: NSMenuItem) {
        guard let info = sender.representedObject as? LoadInfo else { return }
        let m = monitor
        Task { @MainActor in
            await m.loadModel(name: info.modelName, on: info.instance)
        }
    }

    @objc private func toggleOllama() {
        Task { @MainActor in
            let running = await Monitor.isLocalOllamaRunning()
            await Monitor.toggleLocalOllama(start: !running)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self.rebuildMenu()
        }
    }

    @objc private func openSettings() {
        if settingsController == nil {
            settingsController = SettingsWindowController()
            settingsController?.onConfigChanged = { [weak self] in
                guard let self else { return }
                let m = self.monitor
                Task { @MainActor in
                    await m.stopPolling()
                    self.currentStatuses = []
                    self.statusIndicator.updateStatuses([])
                    self.availableModelsByInstance = [:]
                    self.capabilitiesByInstance = [:]
                    self.startMonitoring()
                    if ConfigManager.shared.notifyOnStateChange {
                        self.requestNotificationPermission()
                    }
                }
            }
        }
        settingsController?.showWindow()
    }

    @objc private func showWelcome() {
        if welcomeController == nil { welcomeController = WelcomeWindowController() }
        welcomeController?.showWindow()
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notifyReachability(instance: Instance, reachable: Bool) {
        guard ConfigManager.shared.notifyOnStateChange else { return }
        let content = UNMutableNotificationContent()
        content.title = "ModelStatus"
        content.body = reachable ? "\(instance.name) is reachable" : "\(instance.name) became unreachable"
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    private func statusInfo(_ s: ServerStatus) -> (String, NSColor, String) {
        let effective: ServerState = (s.detectedKind == .ollama) ? s.state :
            (s.state == .generating ? .active : s.state)
        switch effective {
        case .generating: return ("\u{25CF}", .systemBlue, "Generating\u{2026}")
        case .active:     return ("\u{25CF}", .systemGreen, "Active")
        case .idle:       return ("\u{25CB}", .systemYellow, "Idle")
        case .unreachable: return ("\u{2717}", .systemRed, "Unreachable")
        }
    }

    private func headerItem(icon: String, color: NSColor, name: String, text: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        let t = NSMutableAttributedString()
        t.append(mono(icon + " ", size: 14, weight: .bold, color: color))
        t.append(NSAttributedString(string: name, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: NSColor.labelColor]))
        t.append(NSAttributedString(string: "  " + text, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium), .foregroundColor: color]))
        item.attributedTitle = t
        return item
    }

    private func styledItem(_ text: String, font: NSFont) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        return item
    }

    private func mutedItem(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = muted(text)
        return item
    }

    private func mono(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.monospacedSystemFont(ofSize: size, weight: weight), .foregroundColor: color])
    }

    private func muted(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
    }
}

@main
struct ModelStatusApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
