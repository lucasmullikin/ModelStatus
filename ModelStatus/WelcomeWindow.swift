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
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let initialWidth: CGFloat = 532
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: initialWidth, height: 10_000))
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: 1_000_000, height: 1_000_000)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: initialWidth, height: 1_000_000)
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
        appendSub(to: out, "Watch every local AI model server you’re running — from the menu bar.\n\n")

        appendHeading(to: out, "What this app does")
        appendBody(to: out, "ModelStatus puts a small 🧠 in your menu bar. Beside the brain are colored dots, one per AI model server you’ve told it about. Green = working, yellow = sleeping, red = can’t reach it, blue = thinking right now. Click the brain to see what’s loaded, how much VRAM it’s using, who’s talking to it, and how long since it last did anything.\n\n")

        appendHeading(to: out, "Getting started in 60 seconds")
        appendNumbered(to: out, [
            "Make sure at least one model server is running. Common ones: Ollama (brew install ollama && brew services start ollama), LM Studio (turn on its built-in server), vLLM, llama.cpp, or anything that exposes /v1/models.",
            "Pull a model so there’s something to see: ollama pull llama3.2 (Ollama users), or load one in LM Studio’s UI.",
            "Look for the 🧠 in your menu bar. By default it’s already polling http://127.0.0.1:11434 (Ollama’s default). If you see a green or yellow dot, you’re live.",
            "To add another server: click 🧠 → Settings… → Add. Kind = Auto means the app figures out what kind it is for you.",
            "To find servers on your network: Settings → Discover… scans your LAN and Tailscale peers.",
        ])

        appendHeading(to: out, "What the dots mean")
        appendLegend(to: out)
        appendBody(to: out, "\nThe blue ‘Generating’ dot only appears for Ollama, which is the only provider that tells us when it’s actively running inference. Other servers stay green during inference — we don’t pretend to know.\n\n")

        appendHeading(to: out, "Things you can do from the menu")
        appendBullets(to: out, [
            "Click a loaded model name → ejects it (frees VRAM). Works on Ollama + LM Studio.",
            "“N models available” → expand the submenu, click any model to preload it. Ollama + LM Studio.",
            "Start Local Ollama / Stop Local Ollama → toggles your local Ollama service.",
            "Settings… → manage servers, change poll interval, enable notifications, toggle compact menu mode.",
            "Show Quick Start… → reopens this window whenever you want.",
        ])

        appendHeading(to: out, "Remote servers and authentication")
        appendBody(to: out, "If your model server is behind Tailscale Funnel, Cloudflare Tunnel, or a reverse proxy that requires an Authorization header, add the server normally, then select it in Settings and click “Edit Auth…”. Your token (e.g. “Bearer xxxxx”) is stored in the macOS Keychain — never in the config file, never synced anywhere.\n\n")

        appendHeading(to: out, "Privacy and where your data lives")
        appendBullets(to: out, [
            "Config: ~/Library/Preferences/com.lucrativepictures.ModelStatus.json (file mode 0600 — your user only).",
            "Auth tokens: macOS Keychain only, scoped to this device.",
            "Discovery scan: only when you click the Discover button. Never automatic.",
            "Network: only outbound traffic is to the servers you configure. No telemetry, no analytics, no phone-home, no crash reporting.",
        ])

        appendHeading(to: out, "Why this app exists")
        appendBody(to: out, "If you run more than one AI model server at once — laptop Ollama + Mac mini MLX + a remote vLLM box — there’s no menu-bar tool that monitors all of them. ModelStatus is that tool. Open source (MIT), no account, no cloud, no telemetry. Built by Lucrative Pictures LLC. Source on GitHub.\n")

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

    private func appendNumbered(to out: NSMutableAttributedString, _ items: [String]) {
        for (i, item) in items.enumerated() {
            out.append(NSAttributedString(string: "  \(i + 1).  \(item)\n",
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
