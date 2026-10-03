// PomodoroEngine — pure, UI-free pomodoro state machine.
//
// Rules:
//   work -> shortBreak; every `longBreakEvery` completed work phases -> longBreak.
//   A finished work phase notifies, then a break starts only when `autoBreak`.
//   A finished break returns to idle unless `autoNextWork`.
//   Remaining time is always derived from the absolute `endsAt`, so the UI refresh
//   timer never accumulates drift.
//
// Only Foundation is imported here so `--selftest` can exercise it headlessly.

import Foundation

// MARK: - Vocabulary

enum PhaseKind: String, Codable, CaseIterable {
    case work
    case shortBreak
    case longBreak

    var isBreak: Bool { self != .work }

    var displayName: String {
        switch self {
        case .work: return "专注"
        case .shortBreak: return "短休息"
        case .longBreak: return "长休息"
        }
    }
}

enum NotifyChannel: String, Codable, CaseIterable {
    case auto
    case native
    case script
    case soundOnly

    var displayName: String {
        switch self {
        case .auto: return "自动（原生优先，失败降级脚本）"
        case .native: return "仅系统通知"
        case .script: return "仅 osascript 脚本"
        case .soundOnly: return "仅提示音"
        }
    }
}

/// Why the current phase ended. Drives both statistics and what happens next.
enum FinishReason {
    case completed
    case skipped
    case stopped
    case away
}

// MARK: - Persisted model

struct Settings: Codable, Equatable {
    var workMinutes: Double = 25
    var shortBreakMinutes: Double = 5
    var longBreakMinutes: Double = 15
    var longBreakEvery: Int = 4
    var autoBreak: Bool = true
    var autoNextWork: Bool = false
    var sound: Bool = true
    /// Show the transient on-screen card on every phase change (needs no permission).
    var onscreen: Bool = true
    /// How many days of history to keep. 0 means unlimited.
    var historyRetentionDays: Int = 365
    var notifyChannel: NotifyChannel = .auto

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        // Per-field tolerance: one unreadable value costs that value only, never the
        // whole settings section (and never the rest of the state file).
        workMinutes = (try? c.decodeIfPresent(Double.self, forKey: .workMinutes)) ?? d.workMinutes
        shortBreakMinutes = (try? c.decodeIfPresent(Double.self, forKey: .shortBreakMinutes)) ?? d.shortBreakMinutes
        longBreakMinutes = (try? c.decodeIfPresent(Double.self, forKey: .longBreakMinutes)) ?? d.longBreakMinutes
        longBreakEvery = (try? c.decodeIfPresent(Int.self, forKey: .longBreakEvery)) ?? d.longBreakEvery
        autoBreak = (try? c.decodeIfPresent(Bool.self, forKey: .autoBreak)) ?? d.autoBreak
        autoNextWork = (try? c.decodeIfPresent(Bool.self, forKey: .autoNextWork)) ?? d.autoNextWork
        sound = (try? c.decodeIfPresent(Bool.self, forKey: .sound)) ?? d.sound
        onscreen = (try? c.decodeIfPresent(Bool.self, forKey: .onscreen)) ?? d.onscreen
        historyRetentionDays = (try? c.decodeIfPresent(Int.self, forKey: .historyRetentionDays)) ?? d.historyRetentionDays
        notifyChannel = (try? c.decodeIfPresent(NotifyChannel.self, forKey: .notifyChannel)) ?? d.notifyChannel
    }

    /// Clamp every duration into a sane range; used after a settings-window edit and
    /// after loading a hand-edited file.
    mutating func sanitize() {
        workMinutes = Settings.clamp(workMinutes, 0.1, 600, fallback: 25)
        shortBreakMinutes = Settings.clamp(shortBreakMinutes, 0.1, 600, fallback: 5)
        longBreakMinutes = Settings.clamp(longBreakMinutes, 0.1, 600, fallback: 15)
        longBreakEvery = min(max(longBreakEvery, 1), 24)
        historyRetentionDays = min(max(historyRetentionDays, 0), 3650)
    }

    /// Clamp a duration into range. A non-finite value (NaN/±inf) falls back to the
    /// default instead of poisoning every later comparison.
    static func clamp(_ value: Double, _ low: Double, _ high: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return min(max(value, low), high)
    }
}

struct DayStats: Codable, Equatable {
    var completedWork: Int = 0
    var focusMinutes: Double = 0
    var skipped: Int = 0
    var interrupted: Int = 0
    var endedWhileAway: Int = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Per-field tolerance: a single unreadable counter must not discard the day,
        // and a single bad day must not discard the whole history.
        completedWork = (try? c.decodeIfPresent(Int.self, forKey: .completedWork)) ?? 0
        focusMinutes = (try? c.decodeIfPresent(Double.self, forKey: .focusMinutes)) ?? 0
        skipped = (try? c.decodeIfPresent(Int.self, forKey: .skipped)) ?? 0
        interrupted = (try? c.decodeIfPresent(Int.self, forKey: .interrupted)) ?? 0
        endedWhileAway = (try? c.decodeIfPresent(Int.self, forKey: .endedWhileAway)) ?? 0
        clampCounters()
    }

    /// Bound every counter into a sane range. A decoded `Int.max` is otherwise carried
    /// straight into `+= 1` or a report total, both of which trap on overflow.
    mutating func clampCounters() {
        completedWork = min(max(completedWork, 0), Engine.counterLimit)
        skipped = min(max(skipped, 0), Engine.counterLimit)
        interrupted = min(max(interrupted, 0), Engine.counterLimit)
        endedWhileAway = min(max(endedWhileAway, 0), Engine.counterLimit)
        focusMinutes = focusMinutes.isFinite
            ? min(max(focusMinutes, 0), Engine.focusMinuteLimit)
            : 0
    }
}

struct Phase: Codable, Equatable {
    var kind: PhaseKind
    var minutes: Double
    var startedAt: Date
    var endsAt: Date
    var label: String?
    /// Non-nil while paused: the frozen remaining seconds.
    var pausedRemaining: Double?

    var isPaused: Bool { pausedRemaining != nil }
}

struct PomodoroState: Codable, Equatable {
    var version: Int = 1
    var settings: Settings = Settings()
    /// Keyed by local `yyyy-MM-dd`.
    var history: [String: DayStats] = [:]
    var phase: Phase?
    /// Completed work phases since the last long break.
    var cycleWork: Int = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        // These deliberately throw. A section that cannot be decoded at all must reach
        // Store.load(), which moves the file aside before anything overwrites it;
        // `try?` here is what used to let a broken file be silently reset and then
        // permanently overwritten. `salvaging` is the best-effort path used after that.
        settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
        history = try c.decodeIfPresent([String: DayStats].self, forKey: .history) ?? [:]
        phase = try c.decodeIfPresent(Phase.self, forKey: .phase)
        cycleWork = try c.decodeIfPresent(Int.self, forKey: .cycleWork) ?? 0
    }

    /// Best-effort decode used *after* the strict decode failed: keep every section and
    /// every day that can still be read, so one broken part costs one part, not the file.
    /// The original bytes are backed up by `Store.load()` before this runs.
    static func salvaging(_ data: Data) -> PomodoroState? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return nil }
        // Store's decoder, not a bare one: the ISO-8601 date strategy lives there, and
        // without it `phase` (the only section carrying dates) could never be recovered.
        let decoder = Store.makeDecoder()
        var state = PomodoroState()
        if let value = root["version"] as? Int { state.version = value }
        if let raw = root["settings"] as? [String: Any],
           let section = try? JSONSerialization.data(withJSONObject: raw),
           let settings = try? decoder.decode(Settings.self, from: section) {
            state.settings = settings
        }
        if let raw = root["history"] as? [String: Any] {
            for (key, value) in raw {
                // A day must be a JSON object. This guard is load-bearing: for a
                // non-container top-level value `JSONSerialization` raises an
                // Objective-C exception, which Swift cannot catch and which aborts the
                // whole process. A single day stored as a string used to kill the app.
                guard let dayObject = value as? [String: Any],
                      let day = try? JSONSerialization.data(withJSONObject: dayObject),
                      let stats = try? decoder.decode(DayStats.self, from: day) else { continue }
                state.history[key] = stats
            }
        }
        if let raw = root["phase"] as? [String: Any],
           let section = try? JSONSerialization.data(withJSONObject: raw),
           let phase = try? decoder.decode(Phase.self, from: section) {
            state.phase = phase
        }
        if let value = root["cycleWork"] as? Int { state.cycleWork = value }
        return state
    }
}

// MARK: - Events

enum EngineEvent: Equatable {
    case phaseStarted(Phase)
    /// The engine started the next phase by itself (`autoBreak` / `autoNextWork`).
    /// Deliberately silent: the completion event already announced the change, and two
    /// banners plus two sounds per pomodoro was a bug.
    case phaseAutoStarted(Phase)
    case workCompleted(Phase, next: PhaseKind, nextMinutes: Double)
    case breakCompleted(Phase, next: PhaseKind?, nextMinutes: Double)
    case phaseSkipped(Phase, next: PhaseKind?)
    case phaseStopped(Phase)
    case phaseEndedWhileAway(Phase)
    case phaseResumed(Phase, remaining: Double)

    /// Notification title/body for a phase transition, or nil when the event is silent.
    var notification: (title: String, body: String)? {
        switch self {
        case .phaseStarted(let p):
            return ("番茄钟开始", "\(p.kind.displayName) \(Format.minutes(p.minutes))\(p.label.map { "：\($0)" } ?? "")")
        case .workCompleted(let p, let next, let nextMinutes):
            return ("🍅 番茄完成", "已完成 \(Format.minutes(p.minutes)) 专注。接下来：\(next.displayName) \(Format.minutes(nextMinutes))")
        case .breakCompleted(_, let next, let nextMinutes):
            if let next {
                return ("休息结束", "开始下一个番茄：\(next.displayName) \(Format.minutes(nextMinutes))")
            }
            return ("休息结束", "可以开始下一个番茄了。")
        case .phaseSkipped(let p, let next):
            if let next {
                return ("已跳过", "\(p.kind.displayName)已跳过，进入\(next.displayName)。")
            }
            return ("已跳过", "\(p.kind.displayName)已跳过。")
        case .phaseStopped, .phaseEndedWhileAway, .phaseResumed, .phaseAutoStarted:
            return nil
        }
    }
}

// MARK: - Engine

struct Engine {
    var state: PomodoroState
    var calendar: Calendar
    private let clock: () -> Date

    init(state: PomodoroState, calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.state = state
        self.calendar = calendar
        self.clock = now
    }

    // MARK: Time helpers

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    var todayKey: String { Self.dayKey(clock(), calendar: calendar) }

    /// Upper bound for every counter. No real user reaches it, and bounding here stops a
    /// corrupt `Int.max` in the state file from overflowing later arithmetic — which traps.
    static let counterLimit = 1_000_000
    /// Upper bound for accumulated focus minutes, for the same reason.
    static let focusMinuteLimit: Double = 1_000_000

    /// Saturating add. A corrupt counter must never be able to crash the app.
    static func adding(_ value: Int, _ delta: Int) -> Int {
        let (sum, overflow) = value.addingReportingOverflow(delta)
        guard !overflow else { return delta > 0 ? counterLimit : 0 }
        return min(max(sum, 0), counterLimit)
    }

    /// Saturating add for focus minutes.
    static func adding(_ value: Double, _ delta: Double) -> Double {
        let sum = value + delta
        guard sum.isFinite else { return focusMinuteLimit }
        return min(max(sum, 0), focusMinuteLimit)
    }

    /// Remaining seconds of the current phase, or nil when idle.
    /// Never exceeds the phase's planned length: if the wall clock jumps backwards the
    /// countdown stays honest instead of growing past what was ever scheduled.
    func remaining(at date: Date? = nil) -> Double? {
        guard let phase = state.phase else { return nil }
        if let paused = phase.pausedRemaining { return max(0, paused) }
        let raw = max(0, phase.endsAt.timeIntervalSince(date ?? clock()))
        let planned = phase.minutes * 60
        // A degenerate planned length must not become the answer; only a sane one clamps.
        guard planned.isFinite, planned > 0, raw > planned else { return raw }
        return planned
    }

    var isIdle: Bool { state.phase == nil }

    var isPaused: Bool { state.phase?.isPaused ?? false }

    func todayStats() -> DayStats { state.history[todayKey] ?? DayStats() }

    /// History sorted newest-first, limited to `days` entries.
    func recentDays(_ days: Int) -> [(key: String, stats: DayStats)] {
        state.history
            .sorted { $0.key > $1.key }
            .prefix(max(0, days))
            .map { (key: $0.key, stats: $0.value) }
    }

    /// History inside a reporting period, newest first. An unusable range yields nothing.
    func history(in period: StatsPeriod, now: Date? = nil) -> [(key: String, stats: DayStats)] {
        guard let (from, to) = Self.validBounds(period, now: now ?? clock(), calendar: calendar) else {
            return []
        }
        return state.history
            .filter { $0.key >= from && $0.key <= to }
            .sorted { $0.key > $1.key }
            .map { (key: $0.key, stats: $0.value) }
    }

    /// Delete every record inside a period. Returns how many days were removed.
    /// An unusable range deletes nothing: a malformed custom range must never degrade
    /// into "delete everything".
    @discardableResult
    mutating func clearHistory(in period: StatsPeriod, now: Date? = nil) -> Int {
        guard let (from, to) = Self.validBounds(period, now: now ?? clock(), calendar: calendar) else {
            return 0
        }
        let doomed = state.history.keys.filter { $0 >= from && $0 <= to }
        for key in doomed { state.history.removeValue(forKey: key) }
        return doomed.count
    }

    /// Bounds of a period, or nil when the range cannot be trusted (not a real
    /// `yyyy-MM-dd` pair). Guards every destructive and reporting path. A reversed but
    /// valid pair is deliberately normalised by `bounds()`, which is a documented
    /// convenience; only unusable values are rejected.
    static func validBounds(_ period: StatsPeriod, now: Date, calendar: Calendar) -> (String, String)? {
        let (from, to) = period.bounds(now: now, calendar: calendar)
        guard isDayKey(from), isDayKey(to), from <= to else { return nil }
        return (from, to)
    }

    /// True when the text is a real `yyyy-MM-dd` calendar day. Shape alone is not enough:
    /// `2026-02-31` looks right but is not a day, and would silently normalise to March.
    static func isDayKey(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              year >= 0, (1...12).contains(month), (1...31).contains(day) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return false }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == year && back.month == month && back.day == day
    }

    /// Zero the "completed since last long break" counter without touching history.
    mutating func resetCycle() {
        state.cycleWork = 0
    }

    // MARK: Mutations

    /// Record a result against the day the phase actually belongs to. Callers that are
    /// not finishing a phase omit the date and get today.
    private mutating func bump(on date: Date? = nil, _ mutate: (inout DayStats) -> Void) {
        let key = Self.dayKey(date ?? clock(), calendar: calendar)
        var stats = state.history[key] ?? DayStats()
        mutate(&stats)
        // Clamp after mutating too: a day that arrived corrupt must not stay poisonous.
        stats.clampCounters()
        state.history[key] = stats
        // Recording new data is what pushes the oldest days out of the window.
        pruneHistory()
    }

    /// Oldest day key currently kept, or nil when there is no history.
    var oldestDayKey: String? { state.history.keys.min() }

    /// Drop records older than the retention window. Returns how many days were removed.
    /// `historyRetentionDays == 0` means unlimited, so nothing is ever dropped.
    @discardableResult
    mutating func pruneHistory(now: Date? = nil) -> Int {
        // Clamp here as well as in sanitize: an absurd retention makes the cutoff date
        // saturate into the far future, whose key sorts above every real day, so the
        // whole history would be "older than the window" and get deleted.
        let retention = min(max(state.settings.historyRetentionDays, 0), 3650)
        guard retention > 0 else { return 0 }
        let current = now ?? clock()
        let span = max(0, retention - 1)
        guard let cutoffDate = calendar.date(byAdding: .day, value: -span, to: current) else { return 0 }
        let cutoff = Self.dayKey(cutoffDate, calendar: calendar)
        // A cutoff that is not a plausible day means the calendar gave up; deleting on it
        // would be destructive, so keep everything.
        guard Self.isDayKey(cutoff) else { return 0 }
        let doomed = state.history.keys.filter { $0 < cutoff }
        for key in doomed { state.history.removeValue(forKey: key) }
        return doomed.count
    }

    /// Start a phase. `announce` is false for phases the engine starts by itself, so a
    /// completion produces exactly one notification instead of two.
    private mutating func begin(
        _ kind: PhaseKind,
        minutes: Double,
        label: String?,
        at date: Date,
        announce: Bool = true
    ) -> EngineEvent {
        let clamped = Settings.clamp(minutes, 0.01, 600, fallback: 25)
        let phase = Phase(
            kind: kind,
            minutes: clamped,
            startedAt: date,
            endsAt: date.addingTimeInterval(clamped * 60),
            label: label,
            pausedRemaining: nil
        )
        state.phase = phase
        return announce ? .phaseStarted(phase) : .phaseAutoStarted(phase)
    }

    /// Start a work phase. No-op (empty result) while another phase is live.
    mutating func startWork(minutes: Double? = nil, label: String? = nil) -> [EngineEvent] {
        guard state.phase == nil else { return [] }
        let resolved = minutes ?? state.settings.workMinutes
        return [begin(.work, minutes: resolved, label: label, at: clock())]
    }

    mutating func pause() -> [EngineEvent] {
        guard let phase = state.phase, !phase.isPaused else { return [] }
        let remaining = phase.endsAt.timeIntervalSince(clock())
        // Pausing at or after the deadline would freeze the phase at 00:00 forever,
        // because tick() deliberately skips paused phases. Finish it instead.
        guard remaining > 0 else { return finish(phase, at: clock(), reason: .completed) }
        var paused = phase
        paused.pausedRemaining = remaining
        state.phase = paused
        return []
    }

    mutating func resume() -> [EngineEvent] {
        guard var phase = state.phase, let remaining = phase.pausedRemaining else { return [] }
        phase.endsAt = clock().addingTimeInterval(remaining)
        phase.pausedRemaining = nil
        state.phase = phase
        return [.phaseResumed(phase, remaining: remaining)]
    }

    mutating func skip() -> [EngineEvent] {
        guard let phase = state.phase else { return [] }
        return finish(phase, at: clock(), reason: .skipped)
    }

    mutating func stop() -> [EngineEvent] {
        guard let phase = state.phase else { return [] }
        return finish(phase, at: clock(), reason: .stopped)
    }

    /// Drop the current phase without recording anything. Used by headless `--once`
    /// so a run leaves no dangling phase (and no auto-started break) behind.
    mutating func abandonPhase() {
        state.phase = nil
    }

    /// Advance a phase whose deadline has passed. Returns no events while nothing is due.
    mutating func tick() -> [EngineEvent] {
        guard let phase = state.phase, !phase.isPaused else { return [] }
        guard clock() >= phase.endsAt else { return [] }
        return finish(phase, at: clock(), reason: .completed)
    }

    /// Resolve the persisted phase after a launch, wake, or other time gap.
    mutating func reconcile() -> [EngineEvent] {
        guard let phase = state.phase else { return [] }
        if let paused = phase.pausedRemaining {
            return [.phaseResumed(phase, remaining: paused)]
        }
        let date = clock()
        if date >= phase.endsAt {
            return finish(phase, at: date, reason: .away)
        }
        return [.phaseResumed(phase, remaining: phase.endsAt.timeIntervalSince(date))]
    }

    /// End the current phase. The reason decides statistics and the next phase.
    private mutating func finish(_ phase: Phase, at date: Date, reason: FinishReason) -> [EngineEvent] {
        state.phase = nil
        let settings = state.settings
        var events: [EngineEvent] = []
        // A phase that ran out while the app was closed belongs to the day it actually
        // ended, not to the day the app happened to be reopened.
        let credited = min(date, phase.endsAt)

        if phase.kind == .work {
            switch reason {
            case .completed:
                bump(on: credited) {
                    $0.completedWork = Self.adding($0.completedWork, 1)
                    $0.focusMinutes = Self.adding($0.focusMinutes, phase.minutes)
                }
                state.cycleWork = Self.adding(state.cycleWork, 1)
            case .skipped:
                bump(on: credited) { $0.skipped = Self.adding($0.skipped, 1) }
            case .stopped:
                bump(on: credited) { $0.interrupted = Self.adding($0.interrupted, 1) }
            case .away:
                bump(on: credited) {
                    $0.endedWhileAway = Self.adding($0.endedWhileAway, 1)
                    $0.focusMinutes = Self.adding($0.focusMinutes, phase.minutes)
                }
            }

            // Only completion and skip continue the cycle; stop and "away" go idle.
            guard reason == .completed || reason == .skipped else {
                events.append(reason == .stopped ? .phaseStopped(phase) : .phaseEndedWhileAway(phase))
                return events
            }

            let effective = Self.adding(state.cycleWork, reason == .completed ? 0 : 1)
            let every = max(1, settings.longBreakEvery)
            let nextKind: PhaseKind = effective % every == 0 ? .longBreak : .shortBreak
            let nextMinutes = nextKind == .longBreak ? settings.longBreakMinutes : settings.shortBreakMinutes

            if reason == .completed {
                events.append(.workCompleted(phase, next: nextKind, nextMinutes: nextMinutes))
            } else {
                events.append(.phaseSkipped(phase, next: nextKind))
            }
            if settings.autoBreak {
                events.append(begin(nextKind, minutes: nextMinutes, label: nil, at: date, announce: false))
            }
            return events
        }

        // Break phase.
        switch reason {
        case .completed, .away:
            if phase.kind == .longBreak { state.cycleWork = 0 }
        case .skipped, .stopped:
            if phase.kind == .longBreak { state.cycleWork = 0 }
        }

        switch reason {
        case .stopped:
            events.append(.phaseStopped(phase))
            return events
        case .away:
            events.append(.phaseEndedWhileAway(phase))
            return events
        case .completed:
            let next: PhaseKind? = settings.autoNextWork ? .work : nil
            events.append(.breakCompleted(phase, next: next, nextMinutes: settings.workMinutes))
            if let next {
                events.append(begin(next, minutes: settings.workMinutes, label: nil, at: date, announce: false))
            }
            return events
        case .skipped:
            events.append(.phaseSkipped(phase, next: nil))
            return events
        }
    }

    /// Repair anything a hand-edited or partially broken state file could have carried.
    /// Returns true when something had to change, so the caller can persist the repair
    /// and tell the user instead of running with impossible values.
    mutating func sanitizeLoadedState() -> Bool {
        let before = state
        state.settings.sanitize()
        state.cycleWork = Self.adding(state.cycleWork, 0)
        if let phase = state.phase {
            let sane = phase.minutes.isFinite
                && phase.minutes > 0
                && phase.startedAt.timeIntervalSince1970.isFinite
                && phase.endsAt.timeIntervalSince1970.isFinite
                // An inverted phase (start after end) would finish instantly and be
                // recorded as a completed pomodoro that never happened.
                && phase.startedAt <= phase.endsAt
            if !sane {
                state.phase = nil
            } else if let paused = phase.pausedRemaining, !paused.isFinite || paused < 0 {
                state.phase?.pausedRemaining = nil
            }
        }
        state.history = state.history.filter { Self.isDayKey($0.key) }
        for key in state.history.keys {
            state.history[key]?.clampCounters()
        }
        return state != before
    }
}
