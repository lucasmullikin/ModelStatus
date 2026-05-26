import AppKit
import OSLog
import UniformTypeIdentifiers

/// In-app OSLog viewer. One-hour lookback, 2s auto-refresh while visible.
/// Uses `OSLogStore(scope: .currentProcessIdentifier)` so we don't need the
/// `com.apple.developer.logging.private-data` entitlement.
@MainActor
final class LogViewerWindowController: NSWindowController, NSWindowDelegate {

    // MARK: Singleton
    static let shared = LogViewerWindowController()

    // MARK: UI
    private let textView: NSTextView
    private let scrollView: NSScrollView
    private let categoryPopup: NSPopUpButton
    private let statusLabel: NSTextField
    private let refreshButton: NSButton
    private let copyButton: NSButton
    private let exportButton: NSButton

    // MARK: State
    private var refreshTimer: Timer?
    // Active fetch task — cancelled before a new one is started so an older,
    // slower fetch can't overwrite the UI with stale results.
    private var reloadTask: Task<Void, Never>?
    // Monotonically increasing token: the only fetch allowed to apply results
    // is the one whose token matches `latestReloadToken` when it completes.
    private var latestReloadToken: UInt64 = 0
    // Constants used from both MainActor and a detached fetch task — mark
    // nonisolated so the off-main fetch can read them without crossing actors.
    nonisolated private static let maxEntries = 1000
    nonisolated private static let lookbackSeconds: TimeInterval = -3600
    nonisolated private static let refreshInterval: TimeInterval = 2.0

    // Category options drive the predicate. `provider` is special-cased to
    // match every `provider.*` subcategory via BEGINSWITH.
    private enum Category: String, CaseIterable, Sendable {
        case all = "All"
        case monitor = "monitor"
        case updater = "updater"
        case discovery = "discovery"
        case provider = "provider"
    }

    private var selectedCategory: Category {
        Category(rawValue: categoryPopup.titleOfSelectedItem ?? "All") ?? .all
    }

    // MARK: Init

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "ModelStatus — Logs"
        window.center()
        window.setFrameAutosaveName("ModelStatus.LogViewer")

        // Dark monospace text view inside a scroll view.
        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1.0)
        tv.textColor = NSColor(calibratedWhite: 0.92, alpha: 1.0)
        tv.drawsBackground = true
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.textContainer?.widthTracksTextView = true
        self.textView = tv

        let sv = NSScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.borderType = .bezelBorder
        sv.autohidesScrollers = true
        sv.documentView = tv
        self.scrollView = sv

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: Category.allCases.map { $0.rawValue })
        popup.translatesAutoresizingMaskIntoConstraints = false
        // Accessibility-audit-v1final: VoiceOver would just announce "All"
        // or "monitor" with no context about what's being filtered.
        popup.setAccessibilityLabel("Log category filter")
        self.categoryPopup = popup

        let status = NSTextField(labelWithString: "0 entries")
        status.translatesAutoresizingMaskIntoConstraints = false
        status.textColor = .secondaryLabelColor
        status.font = NSFont.systemFont(ofSize: 11)
        self.statusLabel = status

        self.refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
        self.copyButton = NSButton(title: "Copy All", target: nil, action: nil)
        self.exportButton = NSButton(title: "Export to .log file…", target: nil, action: nil)
        // Accessibility-audit-v1final: tooltips + explicit a11y labels so
        // VoiceOver users know what each generic-titled button does.
        refreshButton.toolTip = "Reload log entries now."
        refreshButton.setAccessibilityLabel("Refresh logs")
        copyButton.toolTip = "Copy all visible log entries to the clipboard."
        copyButton.setAccessibilityLabel("Copy all log entries to clipboard")
        exportButton.toolTip = "Save log entries to a .log file."
        exportButton.setAccessibilityLabel("Export logs to a file")
        for b in [refreshButton, copyButton, exportButton] {
            b.bezelStyle = .rounded
            b.translatesAutoresizingMaskIntoConstraints = false
        }

        super.init(window: window)
        window.delegate = self

        popup.target = self
        popup.action = #selector(categoryChanged)
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)
        copyButton.target = self
        copyButton.action = #selector(copyTapped)
        exportButton.target = self
        exportButton.action = #selector(exportTapped)

        layout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    private func layout() {
        guard let contentView = window?.contentView else { return }
        contentView.addSubview(categoryPopup)
        contentView.addSubview(statusLabel)
        contentView.addSubview(refreshButton)
        contentView.addSubview(copyButton)
        contentView.addSubview(exportButton)
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            categoryPopup.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            categoryPopup.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            categoryPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 140),

            statusLabel.centerYAnchor.constraint(equalTo: categoryPopup.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: categoryPopup.trailingAnchor, constant: 12),

            exportButton.centerYAnchor.constraint(equalTo: categoryPopup.centerYAnchor),
            exportButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),

            copyButton.centerYAnchor.constraint(equalTo: categoryPopup.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: exportButton.leadingAnchor, constant: -8),

            refreshButton.centerYAnchor.constraint(equalTo: categoryPopup.centerYAnchor),
            refreshButton.trailingAnchor.constraint(equalTo: copyButton.leadingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: categoryPopup.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12)
        ])
    }

    // MARK: Public

    func showWindow() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startAutoRefresh()
        reload()
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) { stopAutoRefresh() }
    func windowDidMiniaturize(_ notification: Notification) { stopAutoRefresh() }
    func windowDidDeminiaturize(_ notification: Notification) { startAutoRefresh() }

    // MARK: Auto-refresh

    private func startAutoRefresh() {
        stopAutoRefresh()
        // Audit-round-D39: build the timer manually + add to .common mode
        // exactly once. `scheduledTimer(...)` already registers in default
        // mode; calling `RunLoop.main.add(t, forMode: .common)` on TOP of
        // that double-registers (Codex flagged the ambiguity). The non-
        // scheduled `Timer(timeInterval:...)` initializer is the clean
        // single-registration form.
        let t = Timer(timeInterval: Self.refreshInterval, repeats: true) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated { self.reload() }
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
    }

    private func stopAutoRefresh() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        // Also kill any in-flight fetch — applying its result after teardown
        // would leak work onto a window the user already closed. Audit-round-D36:
        // bump the token in addition to cancelling, so a fetch that already
        // passed its Task.isCancelled check can't still apply via the
        // MainActor.run block (the token guard catches it).
        latestReloadToken &+= 1
        reloadTask?.cancel()
        reloadTask = nil
    }

    // MARK: Actions

    @objc private func categoryChanged() { reload() }
    @objc private func refreshTapped() { reload() }

    @objc private func copyTapped() {
        let text = textView.string
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    @objc private func exportTapped() {
        let panel = NSSavePanel()
        // .log isn't a system UTI, so use plainText with the user able to type
        // any extension. Default filename has .log baked in.
        panel.allowedContentTypes = [.plainText]
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = "ModelStatus-\(Self.timestampForFilename()).log"
        panel.title = "Export Logs"
        guard let window else { return }
        let text = textView.string
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            guard let self = self, let parentWindow = self.window else { return }
            // Audit-round-4: surface a UTF-8 encoding failure rather than
            // silently writing nothing. String → UTF-8 effectively never
            // fails, but if it does the user deserves to know.
            // Audit-round-D46: present errors as a sheet on the log window
            // rather than `runModal()` from inside a completed sheet handler
            // — app-modal-over-sheet produces awkward focus/order behavior.
            guard let data = text.data(using: .utf8) else {
                Self.showErrorSheet(on: parentWindow,
                                    title: "Couldn't save log file",
                                    detail: "Failed to encode log text as UTF-8.")
                return
            }
            do {
                try data.write(to: url, options: [.atomic])
            } catch {
                Self.showErrorSheet(on: parentWindow,
                                    title: "Couldn't save log file",
                                    detail: error.localizedDescription)
            }
        }
    }

    private static func showErrorSheet(on window: NSWindow, title: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    private static func timestampForFilename() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date())
    }

    // MARK: Reload

    private func reload() {
        let category = selectedCategory
        let subsystem = ConfigManager.bundleIdentifier
        statusLabel.stringValue = "Loading…"

        // Cancel any in-flight fetch and bump the token so its late-arriving
        // result (if any) is discarded by the applyFetchResult guard.
        reloadTask?.cancel()
        latestReloadToken &+= 1
        let myToken = latestReloadToken

        // Audit-round-D40: propagate cancellation INTO the detached task so
        // a stale OSLog scan stops doing work when superseded. The previous
        // version cancelled the outer task but the detached fetch ran to
        // completion. `withTaskCancellationHandler` is the structured way
        // to forward cancellation.
        reloadTask = Task { [weak self] in
            let fetchTask = Task.detached(priority: .userInitiated) {
                LogViewerWindowController.fetchEntries(subsystem: subsystem, category: category)
            }
            let result: FetchResult? = await withTaskCancellationHandler {
                await fetchTask.value
            } onCancel: {
                fetchTask.cancel()
            }
            // v0.2.1 fix: previously, when `result` was nil (fetch
            // cancelled because a newer reload superseded this one) or when
            // the token check failed, we returned silently leaving the
            // statusLabel stuck on "Loading…". Now: if the fetch returned a
            // valid result AND this is still the current token, apply it;
            // otherwise leave the previously-displayed content alone but
            // restore a non-Loading status so the user never sees a stale
            // "Loading…" stuck state across the 2-second refresh window.
            guard let self else { return }
            if let result, myToken == self.latestReloadToken {
                self.applyFetchResult(result)
            } else if myToken == self.latestReloadToken {
                // Our token is still current but fetch returned nil
                // (cancellation). Just clear the Loading… text since a
                // newer fetch is about to overwrite anyway.
                self.statusLabel.stringValue = "Refreshing…"
            }
            // else: a newer token has been issued — let it handle the UI.
        }
    }

    private struct FetchResult: Sendable {
        let text: String
        let count: Int          // entries actually in the retained ring
        let totalMatched: Int   // matched entries across the whole scan (may exceed count)
        let truncated: Bool
        let error: String?
    }

    private func applyFetchResult(_ r: FetchResult) {
        if let err = r.error {
            textView.string = err
            statusLabel.stringValue = "Error"
            return
        }
        textView.string = r.text
        // Audit-round-D46: when truncated, surface BOTH the retained ring
        // size and the actual matched total. The single-number form lost
        // the matched count completely.
        if r.truncated {
            statusLabel.stringValue = "Showing \(r.count) of \(r.totalMatched) entries (capped at \(Self.maxEntries))"
        } else {
            statusLabel.stringValue = "\(r.count) entries"
        }
        // Scroll to bottom — newest entries are at the end.
        textView.scrollToEndOfDocument(nil)
    }

    // MARK: OSLogStore (off main)

    /// Streams OSLogStore entries through a rolling buffer of at most `maxEntries`
    /// rather than materializing the whole hour of logs first. Bounds memory,
    /// short-circuits on Task.isCancelled every 200 entries so a stale refresh
    /// can stop doing work as soon as a newer one starts.
    ///
    /// Returns nil on cancellation so the caller can skip the UI apply step
    /// entirely (audit-round-3: a sentinel empty-but-successful FetchResult
    /// would otherwise clear the visible log view).
    nonisolated private static func fetchEntries(subsystem: String, category: Category) -> FetchResult? {
        // v0.2.1 fix: `OSLogStore(scope: .currentProcessIdentifier)` returned
        // ZERO entries on macOS 26.x with hardened-runtime signed builds,
        // even though `OSLogStore.local()` with the same predicate returned
        // 136+ entries from the same process. Tested via standalone Swift
        // diagnostic in /tmp/test-oslog.swift. Switch to `.local()` which is
        // also fine under the App Store sandbox — sandboxed apps can read
        // their OWN process's entries from the local store; they just can't
        // read other processes' entries (which we wouldn't want anyway).
        // The subsystem predicate naturally scopes to our own logs.
        let store: OSLogStore
        do {
            store = try OSLogStore.local()
        } catch {
            return FetchResult(
                text: "",
                count: 0,
                totalMatched: 0,
                truncated: false,
                error: "Failed to read OSLogStore: \(error.localizedDescription). "
                     + "Try Console.app → filter on subsystem \(subsystem)."
            )
        }

        let position = store.position(date: Date().addingTimeInterval(lookbackSeconds))
        let predicate = predicateFor(subsystem: subsystem, category: category)

        let entrySequence: AnySequence<OSLogEntry>
        do {
            entrySequence = try store.getEntries(at: position, matching: predicate)
        } catch {
            return FetchResult(
                text: "",
                count: 0,
                totalMatched: 0,
                truncated: false,
                error: "Failed to read OSLogStore: \(error.localizedDescription). "
                     + "Try Console.app → filter on subsystem \(subsystem)."
            )
        }

        // Rolling buffer — never holds more than maxEntries OSLogEntryLog values.
        // Audit-round-4: ring buffer with explicit head/count instead of
        // `removeFirst()` so each insertion is O(1) regardless of how many
        // entries we've seen in a busy hour.
        var ring = [OSLogEntryLog?](repeating: nil, count: maxEntries)
        var ringCount = 0
        var ringHead = 0
        var total = 0
        var checkCounter = 0
        for entry in entrySequence {
            checkCounter += 1
            // Audit-round-D41: check cancellation more frequently so a
            // stale detached scan unwinds faster when superseded.
            if checkCounter % 50 == 0 && Task.isCancelled { return nil }
            guard let log = entry as? OSLogEntryLog else { continue }
            total += 1
            if ringCount < maxEntries {
                ring[(ringHead + ringCount) % maxEntries] = log
                ringCount += 1
            } else {
                ring[ringHead] = log
                ringHead = (ringHead + 1) % maxEntries
            }
        }
        let truncated = total > maxEntries
        var rolling: [OSLogEntryLog] = []
        rolling.reserveCapacity(ringCount)
        for i in 0..<ringCount {
            if let e = ring[(ringHead + i) % maxEntries] { rolling.append(e) }
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"

        var lines: [String] = []
        lines.reserveCapacity(rolling.count)
        for e in rolling {
            if Task.isCancelled { return nil }
            let ts = formatter.string(from: e.date)
            let lvl = levelTag(e.level)
            let cat = e.category.isEmpty ? "-" : e.category
            lines.append("\(ts) [\(lvl)] [\(cat)] \(e.composedMessage)")
        }

        return FetchResult(
            text: lines.joined(separator: "\n"),
            count: rolling.count,
            totalMatched: total,
            truncated: truncated,
            error: nil
        )
    }

    nonisolated private static func predicateFor(subsystem: String, category: Category) -> NSPredicate {
        switch category {
        case .all:
            return NSPredicate(format: "subsystem == %@", subsystem)
        case .provider:
            return NSPredicate(format: "subsystem == %@ AND category BEGINSWITH 'provider.'", subsystem)
        case .monitor, .updater, .discovery:
            return NSPredicate(format: "subsystem == %@ AND category == %@", subsystem, category.rawValue)
        }
    }

    nonisolated private static func levelTag(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug:    return "DEBUG"
        case .info:     return "INFO "
        case .notice:   return "NOTE "
        case .error:    return "ERROR"
        case .fault:    return "FAULT"
        case .undefined: return "----- "
        @unknown default: return "----- "
        }
    }
}
