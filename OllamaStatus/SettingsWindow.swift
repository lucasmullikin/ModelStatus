import AppKit

/// App version
let appVersion = "1.0-beta"

/// Settings window for managing Ollama instances
final class SettingsWindowController: NSWindowController {
    private let tableView = NSTableView()
    private var instances: [OllamaInstance] = []
    var onConfigChanged: (() -> Void)?

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "OllamaStatus Settings"
        window.center()

        super.init(window: window)
        setupUI()
        loadInstances()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        // Table setup
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.width = 120
        tableView.addTableColumn(nameColumn)

        let urlColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("url"))
        urlColumn.title = "URL"
        urlColumn.width = 280
        tableView.addTableColumn(urlColumn)

        tableView.delegate = self
        tableView.dataSource = self
        tableView.allowsMultipleSelection = false

        scrollView.documentView = tableView
        contentView.addSubview(scrollView)

        // Buttons
        let addButton = NSButton(title: "Add", target: self, action: #selector(addInstance))
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let removeButton = NSButton(title: "Remove", target: self, action: #selector(removeInstance))
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(addButton)
        contentView.addSubview(removeButton)

        // About section
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(separator)

        let aboutLabel = NSTextField(labelWithString: "OllamaStatus v\(appVersion)")
        aboutLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        aboutLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(aboutLabel)

        let authorLabel = NSTextField(labelWithString: "by Lucas Mullikin")
        authorLabel.font = NSFont.systemFont(ofSize: 11)
        authorLabel.textColor = .secondaryLabelColor
        authorLabel.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(authorLabel)

        let websiteButton = NSButton(title: "lucasmullikin.com", target: self, action: #selector(openWebsite))
        websiteButton.bezelStyle = .inline
        websiteButton.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(websiteButton)

        // Layout
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -12),

            addButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            addButton.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -16),
            addButton.widthAnchor.constraint(equalToConstant: 80),

            removeButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 8),
            removeButton.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -16),
            removeButton.widthAnchor.constraint(equalToConstant: 80),

            separator.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            separator.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            separator.bottomAnchor.constraint(equalTo: aboutLabel.topAnchor, constant: -12),

            aboutLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            aboutLabel.bottomAnchor.constraint(equalTo: authorLabel.topAnchor, constant: -4),

            authorLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            authorLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),

            websiteButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            websiteButton.centerYAnchor.constraint(equalTo: authorLabel.centerYAnchor)
        ])
    }

    @objc private func openWebsite() {
        if let url = URL(string: "https://lucasmullikin.com") {
            NSWorkspace.shared.open(url)
        }
    }

    private func loadInstances() {
        instances = ConfigManager.shared.instances
        tableView.reloadData()
    }

    @objc private func addInstance() {
        let alert = NSAlert()
        alert.messageText = "Add Ollama Instance"
        alert.informativeText = "Enter the name and URL for the Ollama instance."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")

        let inputView = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 60))

        let nameField = NSTextField(frame: NSRect(x: 0, y: 32, width: 300, height: 24))
        nameField.placeholderString = "Name (e.g., My Server)"

        let urlField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        urlField.placeholderString = "URL (e.g., http://192.168.1.100:11434)"

        inputView.addSubview(nameField)
        inputView.addSubview(urlField)
        alert.accessoryView = inputView

        guard let window = self.window else { return }

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }

            let name = nameField.stringValue.trimmingCharacters(in: .whitespaces)
            var url = urlField.stringValue.trimmingCharacters(in: .whitespaces)

            guard !name.isEmpty, !url.isEmpty else { return }

            // Ensure URL has scheme
            if !url.hasPrefix("http://") && !url.hasPrefix("https://") {
                url = "http://" + url
            }

            ConfigManager.shared.addInstance(name: name, url: url)
            self?.loadInstances()
            self?.onConfigChanged?()
        }
    }

    @objc private func removeInstance() {
        let selectedRow = tableView.selectedRow
        guard selectedRow >= 0 && selectedRow < instances.count else { return }

        let instance = instances[selectedRow]

        let alert = NSAlert()
        alert.messageText = "Remove Instance"
        alert.informativeText = "Are you sure you want to remove \"\(instance.name)\"?"
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        guard let window = self.window else { return }

        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }

            ConfigManager.shared.removeInstance(id: instance.id)
            self?.loadInstances()
            self?.onConfigChanged?()
        }
    }

    func showWindow() {
        loadInstances()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension SettingsWindowController: NSTableViewDelegate, NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        return instances.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < instances.count else { return nil }

        let instance = instances[row]
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("")

        let textField = NSTextField()
        textField.isBordered = false
        textField.isEditable = false
        textField.backgroundColor = .clear

        switch identifier.rawValue {
        case "name":
            textField.stringValue = instance.name
        case "url":
            textField.stringValue = instance.url
        default:
            break
        }

        return textField
    }
}
