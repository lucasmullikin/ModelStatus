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
    /// Capability + available-models caches share the same generation-guarded
    /// invariants: never spawn duplicate fetches, drop stale results when the
    /// configuration changes mid-flight. Extracted into a generic
    /// `GenerationGuardedCache` so future menu lookups don't re-implement the
    /// pattern by hand.
    private let capabilitiesCache = GenerationGuardedCache<UUID, ProviderCapabilities>()
    private let availableModelsCache = GenerationGuardedCache<UUID, [String]>()
    /// Single-fire latch around the `.terminateLater` reply. AppKit will
    /// call `applicationShouldTerminate` again for any quit event raised
    /// while a previous reply is pending; without this we'd start a second
    /// stop-polling race and emit two replies. Audit-round-D7.
    private var isTerminating = false
    /// Serializes config-change-driven monitor restarts. If the user toggles
    /// Settings repeatedly while a stopPolling is still awaiting, we cancel
    /// the in-flight restart before starting a new one — otherwise two
    /// startMonitoring calls can race and we get duplicate polling loops.
    /// Audit-round-D9.
    private var restartMonitoringTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusIndicator = StatusIndicator()
        UNUserNotificationCenter.current().delegate = self
        // Only request notification permission lazily — when we actually attempt to post
        // a notification (reachability OR update available). macOS only shows the prompt
        // once per app, so this avoids surprising users who never enable notifications.
        NotificationCenter.default.addObserver(
            self, selector: #selector(showWelcome),
            name: .settingsRequestedWelcome, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(openSettings),
            name: .welcomeWindowRequestedSettings, object: nil
        )
        rebuildMenu()
        startMonitoring()

        // Background update check 5s after launch (lets polling settle first)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await UpdateChecker.check(force: false)
        }

        if !WelcomeWindowController.hasShownBefore {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.showWelcome()
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Single-fire: if AppKit re-invokes us during the .terminateLater
        // window (it does for quit-from-dock / quit-from-menu pile-ups), the
        // second call returns `.terminateNow` so AppKit doesn't queue another
        // pending-reply contract. Audit-round-D24: the previous `.terminateLater`
        // return left a second reply contract that nobody ever fulfilled.
        if isTerminating { return .terminateNow }
        isTerminating = true
        // Detach the NotificationCenter observers up-front rather than waiting for
        // applicationWillTerminate. If shutdown stalls (or never reaches Will), the
        // observers were already cleaned during the user's actual quit intent.
        NotificationCenter.default.removeObserver(self)
        let m = monitor
        Task {
            // Race the actor's stopPolling against a hard deadline so a stuck poll
            // can't strand the app in "quitting" forever. The reply itself is
            // latched to once — whichever path wins fires it; the other no-ops.
            await Self.raceToFinish(timeoutSeconds: 1.5) { await m.stopPolling() }
            await MainActor.run {
                NSApp.reply(toApplicationShouldTerminate: true)
            }
        }
        return .terminateLater
    }

    /// Hard timeout race. Resumes as soon as `work` finishes OR `timeoutSeconds`
    /// elapses — whichever wins. Audit-round-D2: the work task is now stored
    /// so the timeout path can call `.cancel()` on it; the actor's
    /// `stopPolling` is cancellation-aware enough that this stops the wedged
    /// poll rather than leaking the Task for the process's remaining lifetime.
    private static func raceToFinish(timeoutSeconds: TimeInterval,
                                     work: @Sendable @escaping () async -> Void) async {
        // Audit-round-D23: clamp to a sane minimum so a zero/negative input
        // can't fire the timeout closure immediately and bypass the work.
        let clampedTimeout = max(timeoutSeconds, 0.1)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            final class Latch: @unchecked Sendable { var fired = false }
            let latch = Latch()
            let lock = DispatchQueue(label: "modelstatus.race.latch")
            @Sendable func resumeOnce() {
                let go = lock.sync { () -> Bool in
                    if latch.fired { return false }
                    latch.fired = true
                    return true
                }
                if go { cont.resume() }
            }
            let workTask = Task.detached(priority: .userInitiated) {
                await work()
                resumeOnce()
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + clampedTimeout) {
                workTask.cancel()
                resumeOnce()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Idempotent — applicationShouldTerminate runs first, but this catches the
        // edge case where Will fires without Should (e.g. system logout w/o quit).
        NotificationCenter.default.removeObserver(self)
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
        menu.delegate = self
        populateMenu(menu)
        statusIndicator.setMenu(menu)
    }

    /// Mutates the passed menu in place so AppKit's currently-displayed menu reflects updates.
    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()

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

        // Diagnostics submenu — log viewer + export bundle. Tucked away because most
        // users will never need these; the support flow asks for them when something
        // breaks. Keeps the top-level menu uncluttered.
        let diagItem = NSMenuItem(title: "Diagnostics", action: nil, keyEquivalent: "")
        let diagMenu = NSMenu()
        let showLog = NSMenuItem(title: "Show Log Viewer…", action: #selector(showLogViewer), keyEquivalent: "")
        showLog.target = self
        diagMenu.addItem(showLog)
        let exportBundle = NSMenuItem(title: "Export Diagnostic Bundle…", action: #selector(exportDiagnosticBundle), keyEquivalent: "")
        exportBundle.target = self
        diagMenu.addItem(exportBundle)
        diagItem.submenu = diagMenu
        menu.addItem(diagItem)

        // Update section — either a single "Check for Updates…" or a submenu if a
        // cached update is pending action.
        if let pending = UpdateChecker.cachedAvailableUpdate() {
            let updateItem = NSMenuItem(title: "Update available — \(pending.tag)", action: nil, keyEquivalent: "")
            let updateMenu = NSMenu()

            let view = NSMenuItem(title: "View release on GitHub…", action: #selector(viewLatestRelease), keyEquivalent: "")
            view.target = self
            view.representedObject = pending.htmlURL
            updateMenu.addItem(view)

            if UpdateChecker.isHomebrewInstalled() && !UpdateChecker.isAppStoreInstalled() {
                let copyCmd = NSMenuItem(title: "Copy `brew upgrade --cask modelstatus`", action: #selector(copyBrewUpgradeCmd), keyEquivalent: "")
                copyCmd.target = self
                updateMenu.addItem(copyCmd)
            }

            updateMenu.addItem(.separator())

            let snooze = NSMenuItem(title: "Remind me in a week", action: #selector(snoozeUpdate), keyEquivalent: "")
            snooze.target = self
            updateMenu.addItem(snooze)

            let dismiss = NSMenuItem(title: "Dismiss this update", action: #selector(dismissUpdate), keyEquivalent: "")
            dismiss.target = self
            updateMenu.addItem(dismiss)

            updateItem.submenu = updateMenu
            menu.addItem(updateItem)
        }

        let updateCheck = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        updateCheck.target = self
        menu.addItem(updateCheck)

        let settings = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        menu.addItem(NSMenuItem(title: "Quit ModelStatus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    // NSMenuDelegate — AppKit calls this on main right before display.
    // Populate the *passed* menu synchronously so the open menu reflects current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        populateMenu(menu)
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

        // Audit-round-3: until the real capabilities arrive from the provider,
        // assume NO optional capabilities. This prevents the menu from showing
        // load/eject buttons for providers (MLX, OpenAI-generic) that don't
        // support them during the brief window before the lookup completes.
        let caps = capabilitiesCache.value(for: status.instance.id) ?? []

        // Loaded models — eject only if provider supports it
        if !status.loadedModels.isEmpty {
            for m in status.loadedModels {
                let action: Selector? = caps.contains(.eject) ? #selector(ejectModel(_:)) : nil
                let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
                item.target = self
                if caps.contains(.eject) {
                    item.representedObject = EjectInfo(modelName: m.name, instance: status.instance)
                    item.toolTip = "Loaded model. Click to eject — frees VRAM by sending keep_alive: 0 (Ollama) or /api/v0/models/unload (LM Studio)."
                } else {
                    item.toolTip = "Loaded model. Eject is not supported by this provider — restart the server to unload."
                }
                let t = NSMutableAttributedString()
                t.append(muted("     \u{23CF} "))
                t.append(mono(m.name, size: 12, weight: .semibold, color: .labelColor))
                if m.vramBytes > 0 { t.append(muted("  \(Formatters.bytes(m.vramBytes))")) }
                item.attributedTitle = t
                menu.addItem(item)
            }
        } else if status.state == .idle {
            menu.addItem(mutedItem(
                "     \u{1F4E6} no models loaded",
                tip: "Server is reachable but has no models loaded in memory. Use \"N models available\" below to preload one."
            ))
        }

        // VRAM total (only if provider reports VRAM and there's more than one model)
        if status.vramTotal > 0 && caps.contains(.reportsVRAM) && status.loadedModels.count > 1 {
            menu.addItem(mutedItem(
                "     \u{1F4BE} Total VRAM: \(Formatters.bytes(status.vramTotal))",
                tip: "Sum of VRAM used by all loaded models on this server. From the server's /api/ps response."
            ))
        }

        // CPU + Memory (local only)
        var parts: [String] = []
        if let cpu = status.cpuPercent { parts.append(String(format: "%@ %.0f%%", cpu > 50 ? "\u{26A1}" : "\u{1F4A4}", cpu)) }
        if let mem = status.memoryMB { parts.append("\u{1F4BE} \(mem >= 1024 ? String(format: "%.1fGB", Double(mem)/1024) : "\(mem)MB")") }
        if !parts.isEmpty {
            menu.addItem(mutedItem(
                "     \(parts.joined(separator: "  "))",
                tip: "CPU % and resident memory of the local server process, sampled from `ps -eo`. ⚡ appears when CPU > 50%. Only available for local instances."
            ))
        }

        if let c = status.clientProcess {
            menu.addItem(mutedItem(
                "     \u{1F4E1} \(c)",
                tip: "Process currently connected to this local server (from `lsof -i :PORT`). Tells you who is hitting your model right now — e.g. \"python\", \"curl\", \"Claude\"."
            ))
        }
        if let t = status.lastActive {
            menu.addItem(mutedItem(
                "     \u{1F550} \(Formatters.elapsed(since: t))",
                tip: "Time since this server last had a model load or inference activity. Resets on each poll where the server reports Active or Generating."
            ))
        }
        if let lat = status.latencyMs {
            menu.addItem(mutedItem(
                "     \u{1F4CA} \(lat)ms",
                tip: "Round-trip latency of the most recent status poll. Sudden spikes can hint at the server being busy."
            ))
        }

        // Available models + Load submenu (only if provider supports loading)
        if status.availableModelCount > 0 {
            let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            item.attributedTitle = muted("     \u{1F4CB} \(status.availableModelCount) models available")
            item.toolTip = caps.contains(.loadModel)
                ? "Models pulled/downloaded on this server. Expand the submenu to preload one into memory."
                : "Models pulled/downloaded on this server. Preload-from-menu is not supported by this provider."
            if caps.contains(.loadModel) {
                let submenu = NSMenu()
                submenu.addItem(NSMenuItem(title: "Load model into memory…", action: nil, keyEquivalent: ""))
                submenu.addItem(.separator())
                // Tri-state: nil = not fetched, [] = fetched empty, [..] = results.
                if let names = availableModelsCache.value(for: status.instance.id) {
                    if names.isEmpty {
                        let empty = NSMenuItem(title: "No models available", action: nil, keyEquivalent: "")
                        empty.isEnabled = false
                        submenu.addItem(empty)
                    } else {
                        for name in names {
                            let mi = NSMenuItem(title: name, action: #selector(loadModel(_:)), keyEquivalent: "")
                            mi.target = self
                            mi.representedObject = LoadInfo(modelName: name, instance: status.instance)
                            submenu.addItem(mi)
                        }
                    }
                } else {
                    let loading = NSMenuItem(title: "Fetching list…", action: nil, keyEquivalent: "")
                    loading.isEnabled = false
                    submenu.addItem(loading)
                    if let token = availableModelsCache.beginFetch(status.instance.id) {
                        let inst = status.instance
                        let m = monitor
                        Task { @MainActor [weak self] in
                            let names = await m.availableModels(for: inst)
                            guard let self else { return }
                            if self.availableModelsCache.apply(names, for: inst.id, capturedToken: token) {
                                self.rebuildMenu()
                            }
                        }
                    }
                }
                item.submenu = submenu
            }
            menu.addItem(item)
        }

        // Cache capabilities for next rebuild if we haven't yet — the
        // generation-guarded cache enforces single-flight and stale-drop
        // semantics.
        if capabilitiesCache.value(for: status.instance.id) == nil,
           let token = capabilitiesCache.beginFetch(status.instance.id) {
            let inst = status.instance
            let m = monitor
            Task { @MainActor [weak self] in
                let caps = await m.capabilities(for: inst)
                guard let self else { return }
                if self.capabilitiesCache.apply(caps, for: inst.id, capturedToken: token) {
                    self.rebuildMenu()    // refresh once the real caps land
                }
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
                // Audit-round-D9: serialize the stop-then-restart sequence
                // through a single tracked task. Rapid Settings toggles would
                // otherwise queue overlapping restart tasks, leading to two
                // concurrent polling loops or a stop-then-start that runs
                // against an intermediate config snapshot.
                self.restartMonitoringTask?.cancel()
                let m = self.monitor
                self.restartMonitoringTask = Task { @MainActor [weak self] in
                    await m.stopPolling()
                    guard let self, !Task.isCancelled, !self.isTerminating else { return }
                    self.currentStatuses = []
                    self.statusIndicator.updateStatuses([])
                    // reset() bumps the generation + clears cache + in-flight
                    // for each cache, so any async lookup captured against the
                    // old generation will drop its result on return.
                    self.capabilitiesCache.reset()
                    self.availableModelsCache.reset()
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

    @objc private func checkForUpdates() {
        Task { @MainActor in
            await UpdateChecker.check(force: true)
            self.rebuildMenu()  // surface "Update available" submenu if one was just discovered
        }
    }

    @objc private func viewLatestRelease(_ sender: NSMenuItem) {
        guard let urlString = sender.representedObject as? String,
              let url = URL(string: urlString),
              Self.isSafeOpenURL(url) else { return }
        NSWorkspace.shared.open(url)
    }

    /// Allowlist BOTH scheme and host for any URL we hand to `NSWorkspace.shared.open`.
    /// HTTPS only + an EXACT-host allowlist. Audit-round-D7 hardening: the
    /// previous version accepted any subdomain of an allowed parent ("evil.github.com"
    /// would have passed), which broadens the trust boundary beyond intent.
    nonisolated static func isSafeOpenURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else { return false }
        guard let host = url.host?.lowercased() else { return false }
        let allowedExact: Set<String> = [
            "github.com",
            "www.github.com",
            "api.github.com",
            "objects.githubusercontent.com",   // GH Releases asset CDN
            "apps.apple.com",
            "itunes.apple.com",
            "support.apple.com"
        ]
        return allowedExact.contains(host)
    }

    @objc private func copyBrewUpgradeCmd() {
        UpdateChecker.copyBrewUpgradeCommand()
    }

    @objc private func snoozeUpdate() {
        UpdateChecker.snoozeCachedUpdate()
        rebuildMenu()
    }

    @objc private func dismissUpdate() {
        UpdateChecker.dismissCachedUpdate()
        rebuildMenu()
    }

    @objc private func showLogViewer() {
        LogViewerWindowController.shared.showWindow()
    }

    @objc private func exportDiagnosticBundle() {
        // Audit-round-D46: a menu-bar-only app may have NO real windows when
        // the user triggers this. Anchoring a sheet to an invisible
        // `NSWindow()` produces an off-screen modal that can be unfocusable
        // or never visible. Prefer a real, visible window; otherwise present
        // the save panel WITHOUT a host window (modeless) so it always
        // appears on screen.
        NSApp.activate(ignoringOtherApps: true)
        let realHost: NSWindow? = settingsController?.window?.isVisible == true
            ? settingsController?.window
            : (welcomeController?.window?.isVisible == true ? welcomeController?.window : nil)
        Task { @MainActor in
            if let host = realHost {
                await DiagnosticBundle.exportInteractive(from: host)
            } else {
                await DiagnosticBundle.exportInteractive(from: nil)
            }
        }
    }

    /// Manual permission request, used from Settings when the user enables
    /// notifyOnStateChange. notifyReachability re-queries settings every
    /// time so we don't need to cache here — fire-and-forget is fine.
    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Await authorization BEFORE adding the notification request. The pre-v0.2-audit
    /// version fired both calls synchronously, dropping the very first notification
    /// while macOS was still presenting the permission prompt.
    ///
    /// Audit-round-D7: cache the authorization decision so a reachability
    /// flap doesn't fire `requestAuthorization` on every event. Only call
    /// `requestAuthorization` when status is `.notDetermined` — once denied
    /// or granted, we don't re-prompt.
    private func notifyReachability(instance: Instance, reachable: Bool) {
        guard ConfigManager.shared.notifyOnStateChange else { return }
        Task { @MainActor in
            let center = UNUserNotificationCenter.current()
            // Audit-round-D9: always re-query notificationSettings() so a user
            // who changes Notifications permission in System Settings while
            // the app is running gets the current state. requestAuthorization
            // is still only called when status is `.notDetermined`, so we
            // never re-prompt. No need to cache — the re-query is cheap.
            let settings = await center.notificationSettings()
            let status: UNAuthorizationStatus
            if settings.authorizationStatus == .notDetermined {
                let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
                status = granted ? .authorized : .denied
            } else {
                status = settings.authorizationStatus
            }
            guard status == .authorized || status == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "ModelStatus"
            content.body = reachable
                ? "\(instance.name) is reachable"
                : "\(instance.name) became unreachable"
            content.sound = .default
            let req = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil
            )
            try? await center.add(req)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    // Tap on the "Update available" notification → open the release page.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if let urlString = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: urlString),
           AppDelegate.isSafeOpenURL(url) {
            Task { @MainActor in NSWorkspace.shared.open(url) }
        }
        completionHandler()
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

    private func mutedItem(_ text: String, tip: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        item.attributedTitle = muted(text)
        if let tip { item.toolTip = tip }
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
