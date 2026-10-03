// Format — pure text helpers shared by the menu bar, CLI, windows, and self-test.
// Foundation only, so `--selftest` can use it without AppKit.

import Foundation

enum Format {
    /// Largest value either formatter will convert, so a corrupt or hand-typed number
    /// can never reach `Int(_:)` — which traps — no matter where it came from.
    private static let ceiling = 1e15

    /// Trim trailing zeros: 25 -> "25", 0.1 -> "0.1", 2.5 -> "2.5".
    /// Non-finite input renders as text instead of trapping.
    static func minutes(_ value: Double) -> String {
        guard value.isFinite else { return value > 0 ? "∞" : "0" }
        let safe = min(max(value, 0), ceiling)
        if abs(safe.rounded() - safe) < 0.0001 {
            return String(Int(safe.rounded()))
        }
        var text = String(format: "%.2f", safe)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// Seconds -> "MM:SS", or "H:MM:SS" past an hour.
    /// The input is saturated first: an infinite or absurd value must not reach
    /// `Int(_:)`, and a backwards clock jump must not print a nonsense countdown.
    static func clock(_ seconds: Double) -> String {
        let bounded: Double
        if seconds.isFinite {
            bounded = min(max(0, seconds), ceiling)
        } else {
            bounded = seconds > 0 ? ceiling : 0
        }
        let total = Int(bounded.rounded(.down))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            // %ld, not %d: hours are a 64-bit Int, and %d would truncate them.
            return String(format: "%ld:%02d:%02d", h, m, s)
        }
        return String(format: "%02d:%02d", m, s)
    }

    /// Wall-clock time in the given calendar's zone.
    static func localTime(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// Local date-time in the given calendar's zone.
    static func localDateTime(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.month, .day, .hour, .minute], from: date)
        return String(format: "%02d-%02d %02d:%02d", c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// One-line phase summary, e.g. "专注 24:31（至 15:32）" or "空闲".
    static func phaseLine(_ engine: Engine) -> String {
        guard let phase = engine.state.phase else { return "空闲" }
        let remaining = engine.remaining() ?? 0
        let suffix = phase.isPaused ? " · 已暂停" : ""
        let label = phase.label.map { "：\($0)" } ?? ""
        return "\(phase.kind.displayName)\(label) \(clock(remaining))（至 \(localTime(phase.endsAt, calendar: engine.calendar))）\(suffix)"
    }

    /// Compact menu bar title.
    static func menuTitle(_ engine: Engine) -> String {
        guard let phase = engine.state.phase else { return "🍅" }
        let remaining = engine.remaining() ?? 0
        let mark: String
        switch phase.kind {
        case .work: mark = "🍅"
        case .shortBreak: mark = "☕️"
        case .longBreak: mark = "🌴"
        }
        return phase.isPaused ? "\(mark) \(clock(remaining)) ⏸" : "\(mark) \(clock(remaining))"
    }

    /// Multi-line status used by `--status` and the "状态" menu row.
    static func statusText(_ engine: Engine) -> String {
        let stats = engine.todayStats()
        var lines: [String] = []
        lines.append("当前：\(phaseLine(engine))")
        if let phase = engine.state.phase {
            lines.append("阶段：\(phase.kind.displayName) · 计划 \(minutes(phase.minutes)) 分钟 · 开始于 \(localTime(phase.startedAt, calendar: engine.calendar))")
        }
        lines.append("今日：完成 \(stats.completedWork) 个番茄 · 专注 \(minutes(stats.focusMinutes)) 分钟 · 跳过 \(stats.skipped) · 中断 \(stats.interrupted)")
        lines.append("本周期已完成 \(engine.state.cycleWork)/\(max(1, engine.state.settings.longBreakEvery)) 个番茄")
        return lines.joined(separator: "\n")
    }

    /// Escape one string for an AppleScript double-quoted literal.
    /// Backslash and quote are escaped; control characters collapse to a space.
    static func escapeAppleScript(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n", "\r", "\t": out += " "
            default:
                if scalar.value < 0x20 {
                    out += " "
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// The AppleScript source that posts a notification banner with an optional sound.
    static func notificationScript(title: String, body: String, sound: Bool) -> String {
        let t = escapeAppleScript(title)
        let b = escapeAppleScript(body)
        let soundClause = sound ? " sound name \"Glass\"" : ""
        return "display notification \"\(b)\" with title \"\(t)\"\(soundClause)"
    }
}
