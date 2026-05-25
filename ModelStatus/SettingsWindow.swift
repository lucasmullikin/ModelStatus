import AppKit

private var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
}

@MainActor
final class SettingsWindowController: NSWindowController {
    private let tableView = NSTableView()
    private var instances: [Instance] = []
    private let pollPopup = NSPopUpButton()
    private let notifyCheckbox = NSButton(checkboxWithTitle: "Notify on reachability change", target: nil, action: nil)
    private let compactCheckbox = NSButton(checkboxWithTitle: "Compact menu (one line per instance)", target: nil, action: nil)
    var onConfigChanged: (() -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 540),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "ModelStatus Settings"
        window.center()
        super.init(window: window)
        setupUI()
        loadInstances()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let instancesLabel = NSTextField(labelWithString: "Servers")
        instancesLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        instancesLabel.toolTip = "Each row is one model server. Double-click Name/URL to edit inline. Use Add/Discover/Edit Auth/Remove below."
        instancesLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(instancesLabel)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        for (id, title, width, editable, tip) in [
            ("name", "Name", 110, true, "Friendly label shown in the menu bar."),
            ("url",  "URL",  230, true, "http:// or https:// with port. Example: http://192.168.1.50:11434"),
            ("kind", "Kind", 110, false, "Provider type. 'Auto' detects from the URL on first poll."),
            ("auth", "Auth", 60, false, "🔒 Set = an Authorization header is stored in the Keychain.")
        ] as [(String, String, CGFloat, Bool, String)] {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title
            col.width = width
            col.isEditable = editable
            col.headerToolTip = tip
            tableView.addTableColumn(col)
        }

        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsMultipleSelection = false
        tableView.doubleAction = #selector(tableDoubleClick)
        tableView.target = self

        scrollView.documentView = tableView
        contentView.addSubview(scrollView)

        let addButton = NSButton(title: "Add", target: self, action: #selector(addInstance))
        addButton.toolTip = "Add a server. Kind = Auto means the app probes the URL and picks Ollama / LM Studio / vLLM / OpenAI-compatible automatically."
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let discoverButton = NSButton(title: "Discover…", target: self, action: #selector(discover))
        discoverButton.toolTip = "Scan local /24 + Tailscale peers for known model-server ports."
        discoverButton.translatesAutoresizingMaskIntoConstraints = false

        let editAuthButton = NSButton(title: "Edit Auth…", target: self, action: #selector(editAuth))
        editAuthButton.toolTip = "Set/clear the Authorization header for the selected server. Stored in the macOS Keychain."
        editAuthButton.translatesAutoresizingMaskIntoConstraints = false

        let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeInstance))
        removeButton.toolTip = "Delete the selected server. Its Keychain auth header (if any) is also removed."
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(addButton)
        contentView.addSubview(discoverButton)
        contentView.addSubview(editAuthButton)
        contentView.addSubview(removeButton)

        let pollLabel = NSTextField(labelWithString: "Poll Interval")
        pollLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        pollLabel.toolTip = "How often each server is polled. Lower = snappier, more battery. Higher = lighter."
        pollLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(pollLabel)

        for interval in PollInterval.allCases {
            pollPopup.addItem(withTitle: interval.label)
        }
        pollPopup.selectItem(at: PollInterval.allCases.firstIndex(of: PollInterval.closest(to: ConfigManager.shared.pollInterval)) ?? 1)
        pollPopup.target = self
        pollPopup.action = #selector(pollChanged)
        pollPopup.toolTip = "2s / 5s / 10s / 30s / 1m / 3m"
        pollPopup.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(pollPopup)

        notifyCheckbox.target = self
        notifyCheckbox.action = #selector(notifyToggled)
        notifyCheckbox.state = ConfigManager.shared.notifyOnStateChange ? .on : .off
        notifyCheckbox.toolTip = "Show a macOS notification when a server goes offline or comes back."
        notifyCheckbox.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(notifyCheckbox)

        compactCheckbox.target = self
        compactCheckbox.action = #selector(compactToggled)
        compactCheckbox.state = ConfigManager.shared.compactMode ? .on : .off
        compactCheckbox.toolTip = "Show one line per server in the menu instead of full detail."
        compactCheckbox.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(compactCheckbox)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(separator)

        let aboutLabel = NSTextField(labelWithString: "ModelStatus v\(appVersion)")
        aboutLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        aboutLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(aboutLabel)

        let authorLabel = NSTextField(labelWithString: "Lucrative Pictures LLC · MIT License")
        authorLabel.font = NSFont.systemFont(ofSize: 11)
        authorLabel.textColor = .secondaryLabelColor
        authorLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(authorLabel)

        let quickStartButton = NSButton(title: "Quick Start…", target: self, action: #selector(showQuickStart))
        quickStartButton.bezelStyle = .inline
        quickStartButton.toolTip = "Open the Welcome guide."
        quickStartButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(quickStartButton)

        let githubButton = NSButton(title: "GitHub", target: self, action: #selector(openGitHub))
        githubButton.bezelStyle = .inline
        githubButton.toolTip = "Open the project on GitHub."
        githubButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(githubButton)

        NSLayoutConstraint.activate([
            instancesLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16),
            instancesLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            scrollView.topAnchor.constraint(equalTo: instancesLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            scrollView.heightAnchor.constraint(equalToConstant: 160),

            addButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            addButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            addButton.widthAnchor.constraint(equalToConstant: 70),

            discoverButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            discoverButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 8),
            discoverButton.widthAnchor.constraint(equalToConstant: 90),

            editAuthButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            editAuthButton.leadingAnchor.constraint(equalTo: discoverButton.trailingAnchor, constant: 8),
            editAuthButton.widthAnchor.constraint(equalToConstant: 100),

            removeButton.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            removeButton.leadingAnchor.constraint(equalTo: editAuthButton.trailingAnchor, constant: 8),
            removeButton.widthAnchor.constraint(equalToConstant: 80),

            pollLabel.topAnchor.constraint(equalTo: addButton.bottomAnchor, constant: 20),
            pollLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            pollPopup.centerYAnchor.constraint(equalTo: pollLabel.centerYAnchor),
            pollPopup.leadingAnchor.constraint(equalTo: pollLabel.trailingAnchor, constant: 12),
            pollPopup.widthAnchor.constraint(equalToConstant: 80),

            notifyCheckbox.topAnchor.constraint(equalTo: pollLabel.bottomAnchor, constant: 16),
            notifyCheckbox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            compactCheckbox.topAnchor.constraint(equalTo: notifyCheckbox.bottomAnchor, constant: 8),
            compactCheckbox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            separator.topAnchor.constraint(equalTo: compactCheckbox.bottomAnchor, constant: 16),
            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            aboutLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 12),
            aboutLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),

            authorLabel.topAnchor.constraint(equalTo: aboutLabel.bottomAnchor, constant: 4),
            authorLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            authorLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

            githubButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            githubButton.centerYAnchor.constraint(equalTo: authorLabel.centerYAnchor),

            quickStartButton.trailingAnchor.constraint(equalTo: githubButton.leadingAnchor, constant: -8),
            quickStartButton.centerYAnchor.constraint(equalTo: authorLabel.centerYAnchor)
        ])
    }

    @objc private func pollChanged() {
        let idx = pollPopup.indexOfSelectedItem
        let intervals = PollInterval.allCases
        guard idx >= 0 && idx < intervals.count else { return }
        ConfigManager.shared.pollInterval = intervals[idx].rawValue
        onConfigChanged?()
    }

    @objc private func notifyToggled() {
        ConfigManager.shared.notifyOnStateChange = (notifyCheckbox.state == .on)
        onConfigChanged?()
    }

    @objc private func compactToggled() {
        ConfigManager.shared.compactMode = (compactCheckbox.state == .on)
        onConfigChanged?()
    }

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/lucasmullikin/ModelStatus") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func showQuickStart() {
        NotificationCenter.default.post(name: .settingsRequestedWelcome, object: nil)
    }

    private func loadInstances() {
        instances = ConfigManager.shared.instances
        tableView.reloadData()
        pollPopup.selectItem(at: PollInterval.allCases.firstIndex(of: PollInterval.closest(to: ConfigManager.shared.pollInterval)) ?? 1)
        notifyCheckbox.state = ConfigManager.shared.notifyOnStateChange ? .on : .off
        compactCheckbox.state = ConfigManager.shared.compactMode ? .on : .off
    }

    @objc private func tableDoubleClick() {
        let row = tableView.clickedRow
        let col = tableView.clickedColumn
        guard row >= 0, col >= 0 else { return }
        let id = tableView.tableColumns[col].identifier.rawValue
        if id == "auth" { editAuth(); return }
        if id == "kind" { editKind(row: row); return }
        tableView.editColumn(col, row: row, with: nil, select: true)
    }

    private func editKind(row: Int) {
        guard row >= 0 && row < instances.count else { return }
        let inst = instances[row]
        let alert = NSAlert()
        alert.messageText = "Provider kind for \(inst.name)"
        alert.informativeText = "Auto-detect probes the URL on each poll. Choose a specific kind to skip probing (and force richer features if applicable)."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        for k in ProviderKind.allCases { popup.addItem(withTitle: k.displayName) }
        if let idx = ProviderKind.allCases.firstIndex(of: inst.kind) { popup.selectItem(at: idx) }
        alert.accessoryView = popup

        guard let window = self.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let kinds = ProviderKind.allCases
            let idx = popup.indexOfSelectedItem
            guard idx >= 0 && idx < kinds.count else { return }
            ConfigManager.shared.updateInstance(id: inst.id, kind: kinds[idx])
            self?.loadInstances()
            self?.onConfigChanged?()
        }
    }

    @objc private func addInstance() {
        presentInstanceSheet(name: nil, url: nil, kind: .auto) { [weak self] name, url, kind, auth in
            guard let self else { return }
            ConfigManager.shared.addInstance(name: name, url: url, kind: kind, authHeader: auth)
            self.loadInstances()
            self.onConfigChanged?()
        }
    }

    @objc private func discover() {
        let progressAlert = NSAlert()
        progressAlert.messageText = "Scanning…"
        progressAlert.informativeText = "Probing local /24 + Tailscale peers for known model-server ports. ~5 seconds."
        let spinner = NSProgressIndicator(frame: NSRect(x: 0, y: 0, width: 32, height: 32))
        spinner.style = .spinning
        spinner.startAnimation(nil)
        progressAlert.accessoryView = spinner

        guard let window = self.window else { return }
        progressAlert.beginSheetModal(for: window, completionHandler: nil)

        Task { @MainActor in
            let results = await Discovery.scan()
            window.endSheet(progressAlert.window)
            self.presentDiscoveryResults(results)
        }
    }

    private func presentDiscoveryResults(_ results: [DiscoveredServer]) {
        guard let window = self.window else { return }

        if results.isEmpty {
            let alert = NSAlert()
            alert.messageText = "No model servers found"
            alert.informativeText = "Scanned local /24 + Tailscale peers on common ports (11434, 1234, 8080, 8000, 5001). Nothing responded with /api/tags or /v1/models."
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window, completionHandler: nil)
            return
        }

        let alert = NSAlert()
        alert.messageText = "Found \(results.count) server\(results.count == 1 ? "" : "s")"
        alert.informativeText = "Pick which to add."
        alert.addButton(withTitle: "Add Selected")
        alert.addButton(withTitle: "Cancel")

        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 380, height: CGFloat(results.count) * 26))
        stack.orientation = .vertical
        stack.spacing = 4
        stack.alignment = .leading

        var checkboxes: [NSButton] = []
        for r in results {
            let cb = NSButton(checkboxWithTitle: "\(r.suggestedName) — \(r.url) [\(r.source.rawValue)]",
                              target: nil, action: nil)
            cb.state = .on
            checkboxes.append(cb)
            stack.addArrangedSubview(cb)
        }
        alert.accessoryView = stack

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            for (i, r) in results.enumerated() where checkboxes[i].state == .on {
                ConfigManager.shared.addInstance(name: r.suggestedName, url: r.url, kind: r.kind)
            }
            self?.loadInstances()
            self?.onConfigChanged?()
        }
    }

    @objc private func editAuth() {
        let row = tableView.selectedRow
        guard row >= 0 && row < instances.count else {
            presentAlert("Select a server first.", style: .informational); return
        }
        let inst = instances[row]
        let existing = Keychain.authHeader(for: inst.id) ?? ""

        let alert = NSAlert()
        alert.messageText = "Authorization header for \(inst.name)"
        alert.informativeText = "Sent in the HTTP Authorization header (e.g. \"Bearer xxxxx\"). Stored in the macOS Keychain. Leave blank to clear."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = existing
        field.placeholderString = "Bearer …"
        alert.accessoryView = field

        guard let window = self.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Keychain.setAuthHeader(value.isEmpty ? nil : value, for: inst.id)
            self?.loadInstances()
            self?.onConfigChanged?()
        }
    }

    @objc private func removeInstance() {
        let row = tableView.selectedRow
        guard row >= 0 && row < instances.count else { return }
        let inst = instances[row]
        let alert = NSAlert()
        alert.messageText = "Remove Server"
        alert.informativeText = "Remove \"\(inst.name)\"? Its Keychain auth header (if any) is also deleted."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard let window = self.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            ConfigManager.shared.removeInstance(id: inst.id)
            self?.loadInstances()
            self?.onConfigChanged?()
        }
    }

    private func presentInstanceSheet(name preName: String?, url preURL: String?, kind preKind: ProviderKind,
                                      onSave: @escaping (_ name: String, _ url: String, _ kind: ProviderKind, _ auth: String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = preName == nil ? "Add Server" : "Edit Server"
        alert.informativeText = "Kind = Auto means the app probes the URL and picks the right provider. Authorization header is optional and lives in Keychain."
        alert.addButton(withTitle: preName == nil ? "Add" : "Save")
        alert.addButton(withTitle: "Cancel")

        let inputView = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 132))

        let nameField = NSTextField(frame: NSRect(x: 0, y: 96, width: 360, height: 24))
        nameField.placeholderString = "Name (e.g., My Mini)"
        nameField.stringValue = preName ?? ""

        let urlField = NSTextField(frame: NSRect(x: 0, y: 64, width: 360, height: 24))
        urlField.placeholderString = "URL (e.g., http://192.168.1.50:11434)"
        urlField.stringValue = preURL ?? ""

        let kindPopup = NSPopUpButton(frame: NSRect(x: 0, y: 32, width: 360, height: 24))
        for k in ProviderKind.allCases { kindPopup.addItem(withTitle: k.displayName) }
        if let idx = ProviderKind.allCases.firstIndex(of: preKind) { kindPopup.selectItem(at: idx) }

        let authField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        authField.placeholderString = "Authorization header (optional)"

        inputView.addSubview(nameField)
        inputView.addSubview(urlField)
        inputView.addSubview(kindPopup)
        inputView.addSubview(authField)
        alert.accessoryView = inputView

        guard let window = self.window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                self?.presentAlert("Name cannot be empty.", style: .warning); return
            }
            switch URLValidator.validate(urlField.stringValue) {
            case .failure(let issue):
                self?.presentAlert(issue.errorDescription ?? "Invalid URL.", style: .warning)
            case .success(let normalized):
                let kinds = ProviderKind.allCases
                let kind = kinds[max(0, min(kindPopup.indexOfSelectedItem, kinds.count - 1))]
                let auth = authField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                onSave(name, normalized, kind, auth.isEmpty ? nil : auth)
            }
        }
    }

    private func presentAlert(_ message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        if let window = self.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    func showWindow() {
        loadInstances()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension SettingsWindowController: NSTableViewDelegate, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int { instances.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < instances.count else { return nil }
        let inst = instances[row]
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("")
        let cellID = NSUserInterfaceItemIdentifier("Cell_\(identifier.rawValue)")

        let textField: NSTextField
        if let existing = tableView.makeView(withIdentifier: cellID, owner: self) as? NSTextField {
            textField = existing
        } else {
            textField = NSTextField()
            textField.identifier = cellID
            textField.isBordered = false
            textField.backgroundColor = .clear
            textField.delegate = self
            textField.focusRingType = .exterior
        }
        textField.tag = row

        switch identifier.rawValue {
        case "name":
            textField.stringValue = inst.name
            textField.isEditable = true
            textField.textColor = .labelColor
        case "url":
            textField.stringValue = inst.url
            textField.isEditable = true
            textField.textColor = .labelColor
        case "kind":
            textField.stringValue = inst.kind.displayName
            textField.isEditable = false
            textField.textColor = .secondaryLabelColor
        case "auth":
            textField.stringValue = Keychain.hasAuthHeader(for: inst.id) ? "🔒 Set" : "—"
            textField.isEditable = false
            textField.textColor = .secondaryLabelColor
        default: break
        }
        return textField
    }
}

extension SettingsWindowController: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let textField = obj.object as? NSTextField else { return }
        let row = tableView.row(for: textField)
        let col = tableView.column(for: textField)
        guard row >= 0, row < instances.count, col >= 0 else { return }
        let columnID = tableView.tableColumns[col].identifier.rawValue
        let newValue = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newValue.isEmpty else { loadInstances(); return }
        let inst = instances[row]
        switch columnID {
        case "name":
            ConfigManager.shared.updateInstance(id: inst.id, name: newValue)
        case "url":
            switch URLValidator.validate(newValue) {
            case .failure(let issue):
                presentAlert(issue.errorDescription ?? "Invalid URL.", style: .warning)
                loadInstances(); return
            case .success(let normalized):
                ConfigManager.shared.updateInstance(id: inst.id, url: normalized)
            }
        default: break
        }
        loadInstances()
        onConfigChanged?()
    }
}
