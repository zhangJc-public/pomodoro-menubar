// Stats — reporting periods and the text report behind the stats window and `--stats`.
// Foundation only, so `--selftest` can exercise every period without a UI.

import Foundation

/// A reporting window. Day keys are local `yyyy-MM-dd` strings, so plain string
/// comparison is a correct ordering for the same calendar.
enum StatsPeriod: Equatable {
    case today
    case lastDays(Int)
    case thisMonth
    case all
    case custom(from: String, to: String)

    /// The presets offered in the stats window popup, in display order.
    static let presets: [StatsPeriod] = [
        .today,
        .lastDays(7),
        .lastDays(14),
        .lastDays(30),
        .thisMonth,
        .all,
    ]

    var displayName: String {
        switch self {
        case .today:
            return "今天"
        case .lastDays(let days):
            return days <= 1 ? "今天" : "最近 \(days) 天"
        case .thisMonth:
            return "本月"
        case .all:
            return "全部"
        case .custom(let from, let to):
            return "\(from) ~ \(to)"
        }
    }

    /// Inclusive day-key bounds for this period.
    func bounds(now: Date, calendar: Calendar) -> (from: String, to: String) {
        let today = Engine.dayKey(now, calendar: calendar)
        switch self {
        case .today:
            return (today, today)
        case .lastDays(let days):
            let span = max(1, days) - 1
            let start = calendar.date(byAdding: .day, value: -span, to: now) ?? now
            return (Engine.dayKey(start, calendar: calendar), today)
        case .thisMonth:
            let components = calendar.dateComponents([.year, .month], from: now)
            let first = calendar.date(from: components) ?? now
            return (Engine.dayKey(first, calendar: calendar), today)
        case .all:
            // Year 1, not year 0: the Gregorian calendar has no year 0 (it normalises to
            // year 1), so a "0000-01-01" sentinel would fail day-key validation. Every
            // real record sorts at or above 0001-01-01 anyway.
            return ("0001-01-01", "9999-12-31")
        case .custom(let from, let to):
            return from <= to ? (from, to) : (to, from)
        }
    }

    /// Wording used in confirmation dialogs.
    func describedRange(now: Date, calendar: Calendar) -> String {
        if case .all = self { return "全部历史记录" }
        let (from, to) = bounds(now: now, calendar: calendar)
        return from == to ? from : "\(from) ~ \(to)"
    }

    /// Parse a CLI keyword: `today`, `7`, `month`, `all`, or `2026-01-01:2026-01-31`.
    static func parse(_ text: String) -> StatsPeriod? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        switch trimmed.lowercased() {
        case "today", "1":
            return .today
        case "month":
            return .thisMonth
        case "all":
            return .all
        default:
            if let days = Int(trimmed), days > 0 {
                return .lastDays(days)
            }
            let parts = trimmed.split(separator: ":")
            // Both sides must be real calendar days. Accepting any two 10-character
            // tokens let a typo become a range that covered the whole history.
            if parts.count == 2,
               Engine.isDayKey(String(parts[0])),
               Engine.isDayKey(String(parts[1])) {
                return .custom(from: String(parts[0]), to: String(parts[1]))
            }
            return nil
        }
    }
}

enum StatsReport {
    /// Longest window rendered as a full calendar; beyond that only recorded days appear.
    static let calendarDayLimit = 62

    static func text(_ engine: Engine, period: StatsPeriod, now: Date? = nil) -> String {
        let calendar = engine.calendar
        let current = now ?? Date()
        guard let (from, to) = Engine.validBounds(period, now: current, calendar: calendar) else {
            return "统计范围无效：\(period.describedRange(now: current, calendar: calendar))"
        }
        let recorded = engine.history(in: period, now: current)
        var statsByKey: [String: DayStats] = [:]
        for entry in recorded { statsByKey[entry.key] = entry.stats }

        // Short windows list every day (zeros included); long windows list only what happened.
        let enumerated = dayKeys(from: from, to: to, calendar: calendar, limit: calendarDayLimit + 1)
        let keys: [String]
        if enumerated.count <= calendarDayLimit {
            keys = enumerated.reversed()
        } else {
            keys = recorded.map { $0.key }
        }

        var lines: [String] = []
        let title: String
        if case .all = period {
            title = period.displayName
        } else {
            title = from == to ? period.displayName : "\(period.displayName)（\(from) ~ \(to)）"
        }
        lines.append("统计范围：\(title)")
        lines.append("")

        // A short window would otherwise render a table of zeros with no data at all.
        let hasData = recorded.contains { $0.stats != DayStats() }
        guard !keys.isEmpty, hasData else {
            lines.append("（这个时间段内还没有记录）")
            lines.append("")
            lines.append(retentionNote(engine))
            return lines.joined(separator: "\n")
        }

        let maxCount = keys.reduce(0) { max($0, statsByKey[$1]?.completedWork ?? 0) }
        lines.append(header())
        for key in keys {
            let stats = statsByKey[key] ?? DayStats()
            lines.append(row(key: key, stats: stats, maxCount: maxCount, calendar: calendar))
        }

        let recordedDays = keys.filter { (statsByKey[$0] ?? DayStats()) != DayStats() }
        let productiveDays = keys.filter { (statsByKey[$0]?.completedWork ?? 0) > 0 }
        // Saturating sums: a corrupt day must not overflow the report (which traps).
        let totalWork = keys.reduce(0) { Engine.adding($0, statsByKey[$1]?.completedWork ?? 0) }
        let totalFocus = keys.reduce(0.0) { Engine.adding($0, statsByKey[$1]?.focusMinutes ?? 0) }
        let totalSkipped = keys.reduce(0) { Engine.adding($0, statsByKey[$1]?.skipped ?? 0) }
        let totalInterrupted = keys.reduce(0) { Engine.adding($0, statsByKey[$1]?.interrupted ?? 0) }
        let totalAway = keys.reduce(0) { Engine.adding($0, statsByKey[$1]?.endedWhileAway ?? 0) }

        lines.append("")
        lines.append("合计：范围 \(keys.count) 天 · 有记录 \(recordedDays.count) 天 · 有产出 \(productiveDays.count) 天")
        lines.append("      番茄 \(totalWork) 个 · 专注 \(Format.minutes(totalFocus)) 分钟 · 跳过 \(totalSkipped) · 中断 \(totalInterrupted) · 未运行结束 \(totalAway)")
        if !productiveDays.isEmpty {
            let average = Double(totalWork) / Double(productiveDays.count)
            lines.append("      平均每个有产出的日子 \(String(format: "%.1f", average)) 个番茄")
        }
        lines.append("")
        lines.append(retentionNote(engine))
        return lines.joined(separator: "\n")
    }

    /// One line describing the retention cap, shown at the end of every report.
    static func retentionNote(_ engine: Engine) -> String {
        let retention = engine.state.settings.historyRetentionDays
        if retention <= 0 {
            return "保留策略：不限（可在「设置…」里设置统计保留天数）"
        }
        let oldest = engine.oldestDayKey ?? "—"
        return "保留策略：只保留最近 \(retention) 天（最早记录 \(oldest)），超出后自动覆盖最早的记录"
    }

    // MARK: Table rendering

    private static func header() -> String {
        padded("日期", 12)
            + padded("星期", 7)
            + padded("番茄", 7, right: true)
            + padded("专注(分)", 11, right: true)
            + padded("跳过", 7, right: true)
            + padded("中断", 7, right: true)
            + padded("离开结束", 11, right: true)
            + "  分布"
    }

    private static func row(key: String, stats: DayStats, maxCount: Int, calendar: Calendar) -> String {
        padded(key, 12)
            + padded(weekdayLabel(key, calendar: calendar), 7)
            + padded("\(stats.completedWork)", 7, right: true)
            + padded(Format.minutes(stats.focusMinutes), 11, right: true)
            + padded("\(stats.skipped)", 7, right: true)
            + padded("\(stats.interrupted)", 7, right: true)
            + padded("\(stats.endedWhileAway)", 11, right: true)
            + "  " + bar(count: stats.completedWork, max: maxCount)
    }

    static func bar(count: Int, max maxCount: Int) -> String {
        guard count > 0, maxCount > 0 else { return "" }
        let width = max(1, Int((Double(count) / Double(maxCount) * 20).rounded()))
        return String(repeating: "█", count: width)
    }

    static func weekdayLabel(_ key: String, calendar: Calendar) -> String {
        guard let date = date(fromKey: key, calendar: calendar) else { return "—" }
        let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
        let index = calendar.component(.weekday, from: date) - 1
        guard index >= 0, index < names.count else { return "—" }
        return names[index]
    }

    static func date(fromKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var components = DateComponents()
        components.year = parts[0]
        components.month = parts[1]
        components.day = parts[2]
        return calendar.date(from: components)
    }

    /// Every day key in the inclusive range, oldest first, capped at `limit`.
    static func dayKeys(from: String, to: String, calendar: Calendar, limit: Int) -> [String] {
        guard let start = date(fromKey: from, calendar: calendar),
              let end = date(fromKey: to, calendar: calendar),
              start <= end else { return [] }
        var keys: [String] = []
        var cursor = start
        while cursor <= end && keys.count < limit {
            keys.append(Engine.dayKey(cursor, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return keys
    }

    /// Width in monospaced cells: CJK and fullwidth scalars occupy two.
    static func displayWidth(_ text: String) -> Int {
        var width = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF,
                 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA000...0xA4CF,
                 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE6F,
                 0xFF00...0xFF60, 0xFFE0...0xFFE6, 0x20000...0x3FFFD:
                width += 2
            default:
                width += 1
            }
        }
        return width
    }

    static func padded(_ text: String, _ width: Int, right: Bool = false) -> String {
        let current = displayWidth(text)
        guard current < width else { return text }
        let fill = String(repeating: " ", count: width - current)
        return right ? fill + text : text + fill
    }
}
