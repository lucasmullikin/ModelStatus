import AppKit

@MainActor
final class WelcomeWindowController: NSWindowController {
    private static let hasShownKey = "ModelStatus.hasShownWelcome.v3"

    static var hasShownBefore: Bool {
        get { UserDefaults.standard.bool(forKey: hasShownKey) }
        set { UserDefaults.standard.set(newValue, forKey: hasShownKey) }
    }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 600),
            styleMask: [.titled, .closable],
            backing: .buffered, defer: false
        )
        window.title = "Welcome to ModelStatus"
        window.center()
        window.isMovableByWindowBackground = true
        super.init(window: window)
        setupUI()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func showWindow() {
        Self.hasShownBefore = true
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(welcomeBody())

        scrollView.documentView = textView

        let githubButton = NSButton(title: "GitHub", target: self, action: #selector(openGitHub))
        githubButton.bezelStyle = .rounded
        githubButton.translatesAutoresizingMaskIntoConstraints = false

        let settingsButton = NSButton(title: "Open Settings…", target: self, action: #selector(openSettings))
        settingsButton.bezelStyle = .rounded
        settingsButton.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = NSButton(title: "Get Started", target: self, action: #selector(closeWindow))
        closeButton.bezelStyle = .rounded
        closeButton.keyEquivalent = "\r"
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(scrollView)
        contentView.addSubview(githubButton)
        contentView.addSubview(settingsButton)
        contentView.addSubview(closeButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            scrollView.bottomAnchor.constraint(equalTo: closeButton.topAnchor, constant: -16),

            githubButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24),
            githubButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),

            settingsButton.leadingAnchor.constraint(equalTo: githubButton.trailingAnchor, constant: 8),
            settingsButton.centerYAnchor.constraint(equalTo: githubButton.centerYAnchor),

            closeButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            closeButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -20),
            closeButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 110)
        ])
    }

    private func welcomeBody() -> NSAttributedString {
        let out = NSMutableAttributedString()
        appendTitle(to: out, "🧠 ModelStatus")
        appendSub(to: out, "A menu bar monitor for local model servers — Ollama, LM Studio, vLLM, llama.cpp, MLX, and anything else that speaks OpenAI-compatible HTTP.\n\n")

        appendHeading(to: out, "Reading the menu bar")
        appendBody(to: out, "The 🧠 icon shows one colored dot per configured server. Click to open the menu.\n")
        appendLegend(to: out)
        appendBody(to: out, "\nA blue ‘Generating’ dot appears only for Ollama (which exposes inference state). Other providers show Active/Idle/Unreachable — when you see a blue dot, it's real.\n\n")

        appendHeading(to: out, "Adding servers")
        appendBullets(to: out, [
            "Settings → Add. Kind = Auto means the app probes the URL and picks Ollama / LM Studio / vLLM / OpenAI-compatible.",
            "Or Settings → Discover… to scan your local /24 and Tailscale peers automatically.",
            "Remote servers behind a tunnel: set an Authorization header via Settings → Edit Auth (stored in Keychain, never in JSON).",
        ])

        appendHeading(to: out, "What you can do from the menu")
        appendBullets(to: out, [
            "Click a loaded model to eject it (Ollama: keep_alive: 0; LM Studio: /api/v0/models/unload).",
            "“N models available” → submenu lets you preload a model (Ollama + LM Studio only — generic OpenAI-compat servers don’t expose load).",
            "Start/Stop Local Ollama — works with brew services and the official Ollama.app install.",
            "Show Quick Start opens this window again whenever you want.",
        ])

        appendHeading(to: out, "Settings")
        appendBullets(to: out, [
            "Poll interval — 2s / 5s / 10s / 30s / 1m / 3m. Default is 5s.",
            "Compact menu — one-line per server (great when you have 4+ instances).",
            "Reachability notifications — macOS notification when a server drops or recovers.",
            "Provider kind — double-click the Kind column to override Auto with a specific provider.",
        ])

        appendHeading(to: out, "Data & privacy")
        appendBullets(to: out, [
            "Config: ~/Library/Preferences/com.lucrativepictures.ModelStatus.json (mode 0600).",
            "Auth tokens: macOS Keychain only, scoped to this device.",
            "No telemetry, no analytics. Only outbound traffic is to the servers you configure.",
            "Network discovery (Settings → Discover…) is on-demand only — never automatic.",
        ])

        appendHeading(to: out, "Why this app exists")
        appendBody(to: out, "If you run more than one model server at once — laptop Ollama + Mac mini MLX + a remote vLLM box — there’s no menu-bar tool that monitors them all. ModelStatus is that tool. Open source (MIT), no account, no cloud, no telemetry.\n")

        return out
    }

    private func appendTitle(to out: NSMutableAttributedString, _ s: String) {
        out.append(NSAttributedString(string: "\(s)\n",
            attributes: [.font: NSFont.systemFont(ofSize: 22, weight: .bold), .foregroundColor: NSColor.labelColor]))
    }

    private func appendSub(to out: NSMutableAttributedString, _ s: String) {
        out.append(NSAttributedString(string: s,
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor]))
    }

    private func appendHeading(to out: NSMutableAttributedString, _ s: String) {
        out.append(NSAttributedString(string: "\(s)\n",
            attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: NSColor.labelColor]))
    }

    private func appendBody(to out: NSMutableAttributedString, _ s: String) {
        out.append(NSAttributedString(string: s,
            attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]))
    }

    private func appendBullets(to out: NSMutableAttributedString, _ items: [String]) {
        for item in items {
            out.append(NSAttributedString(string: "  •  \(item)\n",
                attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]))
        }
        out.append(NSAttributedString(string: "\n"))
    }

    private func appendLegend(to out: NSMutableAttributedString) {
        let entries: [(String, NSColor, String)] = [
            ("●", .systemGreen,  "Active — server reachable, models loaded"),
            ("●", .systemBlue,   "Generating — inference in flight (Ollama only)"),
            ("○", .systemYellow, "Idle — reachable, nothing loaded right now"),
            ("✗", .systemRed,    "Unreachable — server is down or URL invalid"),
            ("?", .systemGray,   "Checking — first poll pending")
        ]
        out.append(NSAttributedString(string: "\n"))
        for (icon, color, desc) in entries {
            out.append(NSAttributedString(string: "  \(icon)  ",
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .bold), .foregroundColor: color]))
            out.append(NSAttributedString(string: "\(desc)\n",
                attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]))
        }
    }

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/lucasmullikin/ModelStatus") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openSettings() {
        window?.close()
        NotificationCenter.default.post(name: .welcomeWindowRequestedSettings, object: nil)
    }

    @objc private func closeWindow() { window?.close() }
}

extension Notification.Name {
    static let welcomeWindowRequestedSettings = Notification.Name("ModelStatus.welcomeRequestedSettings")
    static let settingsRequestedWelcome = Notification.Name("ModelStatus.settingsRequestedWelcome")
}
