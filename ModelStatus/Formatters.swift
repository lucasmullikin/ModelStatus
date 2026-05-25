import Foundation

enum Formatters {
    static let systemMemoryBytes: Int64 = {
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        if sysctlbyname("hw.memsize", &size, &len, nil, 0) == 0 {
            return Int64(size)
        }
        return 0
    }()

    static func bytes(_ b: Int64) -> String {
        guard b > 0 else { return "" }
        let gb = Double(b) / 1_073_741_824
        return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(b) / 1_048_576)
    }

    static func elapsed(since d: Date) -> String {
        let e = Date().timeIntervalSince(d)
        if e < 60 { return "\(Int(e))s ago" }
        if e < 3600 { return "\(Int(e/60))m \(Int(e.truncatingRemainder(dividingBy: 60)))s ago" }
        return "\(Int(e/3600))h \(Int(e.truncatingRemainder(dividingBy: 3600)/60))m ago"
    }

    /// Render a unicode-block progress bar like ████░░░░░░░░ for the given fraction (0...1).
    static func bar(fraction: Double, width: Int = 12) -> String {
        let clamped = max(0, min(1, fraction))
        let filled = Int((Double(width) * clamped).rounded())
        return String(repeating: "\u{2588}", count: filled) + String(repeating: "\u{2591}", count: width - filled)
    }

    /// Compact one-line summary: `<dot> <name> · <model> [+N more] · <vram>` or idle/unreachable variant.
    static func compactLine(status: ServerStatus) -> String {
        let dot: String
        switch status.state {
        case .active:      dot = "\u{1F7E2}"
        case .generating:  dot = "\u{1F535}"
        case .idle:        dot = "\u{1F7E1}"
        case .unreachable: dot = "\u{1F534}"
        }
        let name = status.instance.name
        switch status.state {
        case .idle:        return "\(dot) \(name) \u{00B7} idle"
        case .unreachable: return "\(dot) \(name) \u{00B7} unreachable"
        case .active, .generating:
            guard let first = status.loadedModels.first else {
                return "\(dot) \(name) \u{00B7} active"
            }
            var line = "\(dot) \(name) \u{00B7} \(first.name)"
            if status.loadedModels.count > 1 {
                line += " +\(status.loadedModels.count - 1) more"
            }
            if status.vramTotal > 0 {
                line += " \u{00B7} \(bytes(status.vramTotal))"
            }
            return line
        }
    }
}
