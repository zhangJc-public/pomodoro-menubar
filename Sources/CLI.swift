// CLI — headless modes, used both by the user and by the acceptance checks.

import AppKit
import Foundation

enum CLIMode {
    case selftest
    case uiSelfTest
    case notifyTest
    case status
    case once(minutes: Double, label: String?, force: Bool)
    case stats(period: StatsPeriod, raw: String)
    case resetStats(period: StatsPeriod, raw: String, confirmed: Bool)
    case loginItem(action: String)
    case help
    /// A bad value or unknown argument. Distinct from `.help` so the process can exit
    /// non-zero and scripts can tell a rejection from a successful run.
    case invalidUsage
    case version
}

/// Set from the SIGINT handler in `--once` mode.
private var interrupted = false

private func handleInterrupt(_ signal: Int32) {
    interrupted = true
}

enum CLI {
    static let version = "1.0.0"

    static func usage() -> String {
        """
        番茄钟（Pomodoro）— 独立运行的 macOS 菜单栏番茄钟

        用法：
          Pomodoro                      启动菜单栏番茄钟（无参数）
          Pomodoro --selftest           运行引擎/统计/持久化自检
          Pomodoro --ui-selftest        无界面构建两个窗口做 UI 冒烟测试
          Pomodoro --notify-test        发送一条测试通知并报告所用通道
          Pomodoro --status             打印当前状态与今日统计
          Pomodoro --once <分钟>        前台跑一个专注阶段，结束后通知并退出
                                        [--label 文案] [--force]
          Pomodoro --stats [范围]         打印统计报表，范围见下（默认 14）
          Pomodoro --reset-stats <范围>   重置统计；不加 --yes 只预览不删除
          Pomodoro --login-item <动作>    开机自启：status | on | off
          Pomodoro --version              打印版本
          Pomodoro --help                 显示本帮助

        统计范围写法（--stats / --reset-stats 通用）：
          today | 7 | 14 | 30 | month | all | 2026-01-01:2026-01-31
        """
    }

    /// Returns nil when the app should start its menu bar UI.
    /// Every argument is validated: an unrecognised or surplus token is a usage error, not
    /// something to ignore. Silently skipping extras is how `--once 25 --bogus --help`
    /// used to start a real 25-minute timer.
    static func parse(_ arguments: [String]) -> CLIMode? {
        guard let first = arguments.first else { return nil }
        let rest = Array(arguments.dropFirst())
        // Modes that take no further arguments.
        func noExtras(_ mode: CLIMode) -> CLIMode {
            rest.isEmpty ? mode : .invalidUsage
        }
        switch first {
        case "--selftest":
            return noExtras(.selftest)
        case "--ui-selftest":
            return noExtras(.uiSelfTest)
        case "--notify-test":
            return noExtras(.notifyTest)
        case "--status":
            return noExtras(.status)
        case "--help", "-h":
            return noExtras(.help)
        case "--version":
            return noExtras(.version)
        case "--stats":
            guard rest.count <= 1 else { return .invalidUsage }
            let raw = rest.first ?? "14"
            return StatsPeriod.parse(raw).map { CLIMode.stats(period: $0, raw: raw) } ?? .invalidUsage
        case "--reset-stats":
            // One optional range plus the optional --yes, nothing else.
            let positional = rest.filter { !$0.hasPrefix("--") }
            let flags = rest.filter { $0.hasPrefix("--") }
            guard positional.count <= 1, flags.allSatisfy({ $0 == "--yes" }) else { return .invalidUsage }
            let raw = positional.first ?? "all"
            let confirmed = flags.contains("--yes")
            return StatsPeriod.parse(raw).map { CLIMode.resetStats(period: $0, raw: raw, confirmed: confirmed) } ?? .invalidUsage
        case "--login-item":
            guard let action = rest.first, rest.count == 1,
                  ["status", "on", "off"].contains(action) else { return .invalidUsage }
            return .loginItem(action: action)
        case "--once":
            // Bound the value: a huge or infinite duration used to trap the formatter or
            // spin the completion loop forever, and anything below the engine's floor
            // would be silently clamped and reported as "0 分钟".
            guard let raw = rest.first,
                  let minutes = Double(raw),
                  minutes.isFinite, minutes >= 0.01, minutes <= 600 else {
                return .invalidUsage
            }
            var label: String?
            var force = false
            var index = 1
            while index < rest.count {
                if rest[index] == "--label" {
                    // A valueless --label is a usage error, not something to skip.
                    guard index + 1 < rest.count else { return .invalidUsage }
                    label = rest[index + 1]
                    index += 2
                } else if rest[index] == "--force" {
                    force = true
                    index += 1
                } else {
                    return .invalidUsage
                }
            }
            return .once(minutes: minutes, label: label, force: force)
        default:
            // An unrecognised argument is a typo, not a request for the menu bar app:
            // only the no-argument invocation starts the GUI.
            return .invalidUsage
        }
    }

    static func run(_ mode: CLIMode) -> Int32 {
        switch mode {
        case .help:
            print(usage())
            return 0
        case .invalidUsage:
            // Usage goes to stderr and the exit status is non-zero, so a script can tell
            // a rejected argument from a successful run.
            FileHandle.standardError.write(Data((usage() + "\n").utf8))
            return 2
        case .version:
            print("Pomodoro \(version)")
            return 0
        case .selftest:
            var runner = SelfTest()
            return Int32(runner.run())
        case .uiSelfTest:
            return runUISelfTest()
        case .notifyTest:
            return runNotifyTest()
        case .status:
            return runStatus()
        case .stats(let period, _):
            return runStats(period: period)
        case .resetStats(let period, let raw, let confirmed):
            return runResetStats(period: period, raw: raw, confirmed: confirmed)
        case .loginItem(let action):
            return runLoginItem(action)
        case .once(let minutes, let label, let force):
            return runOnce(minutes: minutes, label: label, force: force)
        }
    }

    // MARK: Modes

    /// Build both auxiliary windows headlessly. Catches construction crashes that
    /// would otherwise only appear when the user opens them.
    private static func runUISelfTest() -> Int32 {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomodoro-uitest-\(UUID().uuidString)")
        let model = AppModel(store: Store(directory: scratch))
        var problems: [String] = []

        print("UI 自检")

        let stats = StatsWindowController(model: model)
        if let window = stats.buildIfNeeded() {
            print("  ✓ 统计窗口构建成功（\(Int(window.frame.width))×\(Int(window.frame.height))）")
        } else {
            problems.append("统计窗口未构建")
        }
        stats.refresh()

        let settings = SettingsWindowController(model: model)
        if let window = settings.buildIfNeeded() {
            print("  ✓ 设置窗口构建成功（\(Int(window.frame.width))×\(Int(window.frame.height))）")
        } else {
            problems.append("设置窗口未构建")
        }

        // The report must render into a real window, not just into a string.
        let report = StatsReport.text(model.engine, period: .lastDays(14))
        if report.contains("统计范围") {
            print("  ✓ 统计报表可渲染（\(report.count) 字符）")
        } else {
            problems.append("统计报表渲染失败")
        }

        try? FileManager.default.removeItem(at: scratch)

        print("")
        if problems.isEmpty {
            print("UI 自检通过")
            return 0
        }
        for problem in problems { print("  ✗ \(problem)") }
        return 1
    }

    private static func runNotifyTest() -> Int32 {
        // Diagnostic only: never request authorization here. A request from a
        // non-GUI process is not answerable and macOS records it as a denial,
        // which would then block the menu bar app's own prompt. The app asks
        // for permission itself on first launch.
        let notifier = Notifier()
        let status = notifier.authorizationStatus()
        print("通知授权：\(Notifier.describe(status))（授权请求只在菜单栏应用首次启动时发起）")
        let store = Store.default()
        let channel = store.load().state.settings.notifyChannel
        let result = notifier.post(
            title: "番茄钟测试通知",
            body: "看到横幅、听到提示音即为正常。",
            channel: channel,
            sound: true
        )
        print("通知结果：\(result.summary)")
        if status == .denied {
            print("提示：系统里该应用的通知已被拒绝。可在「系统设置 › 通知」里允许 Pomodoro，")
            print("      或在菜单「设置…」里把通知方式改为「仅提示音」／「仅 osascript 脚本」。")
        } else if !result.ok {
            print("提示：可在设置里把通知方式改为「仅提示音」或「仅 osascript 脚本」。")
        }
        return result.ok ? 0 : 1
    }

    private static func runStatus() -> Int32 {
        let store = Store.default()
        let loaded = store.load()
        let engine = Engine(state: loaded.state)
        print(Format.statusText(engine))
        let retention = engine.state.settings.historyRetentionDays
        print("统计保留：\(retention > 0 ? "最近 \(retention) 天" : "不限")\(engine.oldestDayKey.map { "（最早记录 \($0)）" } ?? "")")
        if let note = loaded.note { print("提示：\(note)") }
        if let pid = store.runningGUIPid() {
            print("菜单栏应用：运行中（pid \(pid)）")
        } else {
            print("菜单栏应用：未运行")
        }
        print("数据文件：\(store.stateURL.path)")
        return 0
    }

    private static func runStats(period: StatsPeriod) -> Int32 {
        let store = Store.default()
        let engine = Engine(state: store.load().state)
        print(StatsReport.text(engine, period: period))
        return 0
    }

    private static func runResetStats(period: StatsPeriod, raw: String, confirmed: Bool) -> Int32 {
        let store = Store.default()
        var engine = Engine(state: store.load().state)
        let calendar = engine.calendar
        let scope = period.describedRange(now: Date(), calendar: calendar)
        let affected = engine.history(in: period)

        if !confirmed {
            print("将要删除的统计记录：\(scope)")
            print("命中 \(affected.count) 天的记录：")
            if affected.isEmpty {
                print("  （没有记录）")
            } else {
                for entry in affected.prefix(20) {
                    print("  \(entry.key)  番茄 \(entry.stats.completedWork)  专注 \(Format.minutes(entry.stats.focusMinutes)) 分钟")
                }
                if affected.count > 20 { print("  …另有 \(affected.count - 20) 天") }
            }
            print("")
            print("这是预览，未做任何改动。确认删除请追加 --yes：")
            print("  Pomodoro --reset-stats \(raw) --yes")
            return 0
        }

        if let pid = store.runningGUIPid() {
            print("菜单栏番茄钟正在运行（pid \(pid)），它的内存状态会在下次改动时覆盖磁盘。")
            print("请先在菜单里退出，再执行重置。")
            return 2
        }

        let removed = engine.clearHistory(in: period)
        report(store.save(engine.state))
        print("已删除 \(removed) 天的记录（\(scope)）。")
        return 0
    }

    private static func runLoginItem(_ action: String) -> Int32 {
        switch action {
        case "status":
            print("开机自启：\(LoginItem.isEnabled() ? "已开启" : "已关闭")")
            if FileManager.default.fileExists(atPath: LoginItem.agentPlistURL.path) {
                print("方式：LaunchAgent（\(LoginItem.agentPlistURL.path)）")
            } else {
                print("方式：系统登录项（SMAppService）")
            }
            return 0
        case "on", "off":
            let enable = action == "on"
            if let error = LoginItem.setEnabled(enable) {
                print("设置失败：\(error)")
                return 1
            }
            print("开机自启已\(enable ? "开启" : "关闭")。")
            return 0
        default:
            // stderr, like every other usage error, so scripts can separate it from output.
            FileHandle.standardError.write(Data("用法：--login-item status|on|off\n".utf8))
            return 2
        }
    }

    private static func runOnce(minutes: Double, label: String?, force: Bool) -> Int32 {
        let store = Store.default()
        if !force, let pid = store.runningGUIPid() {
            print("菜单栏番茄钟正在运行（pid \(pid)），为避免状态互相覆盖已中止。")
            print("请先在菜单里退出，或加 --force 强制运行。")
            return 2
        }

        let notifier = Notifier()
        let loaded = store.load()
        var engine = Engine(state: loaded.state)
        report(loaded.note)
        // Repair impossible values before anything acts on them. The GUI does this in
        // AppModel.init; without it here, an absurd retention or counter from the same
        // file would be applied destructively by a headless run.
        if engine.sanitizeLoadedState() {
            report(store.save(engine.state))
        }

        // Resolve a phase left over from a killed GUI session first, so `--once` can never
        // silently adopt it and record a completion for a pomodoro that never ran here.
        let resolved = engine.reconcile()
        if !resolved.isEmpty {
            deliver(resolved, engine: engine, notifier: notifier)
            report(store.save(engine.state))
        }
        if let phase = engine.state.phase {
            print("状态文件里已有一个进行中的阶段（\(phase.kind.displayName)，"
                + "计划 \(Format.minutes(phase.minutes)) 分钟，至 \(Format.localTime(phase.endsAt, calendar: engine.calendar))）。")
            print("请先在菜单栏里结束它，或删除状态文件后重试。")
            return 2
        }

        let started = engine.startWork(minutes: minutes, label: label)
        guard !started.isEmpty else {
            print("无法开始新的专注阶段。")
            return 2
        }
        deliver(started, engine: engine, notifier: notifier)
        report(store.save(engine.state))

        let suffix = label.map { "：\($0)" } ?? ""
        print("开始 \(Format.minutes(minutes)) 分钟专注\(suffix)，Ctrl-C 可中断。")
        interrupted = false
        signal(SIGINT, handleInterrupt)
        // SIGTERM too (logout, launchd shutdown): without it the process dies leaving a
        // dangling running phase behind, which the next launch reconciles as "away".
        signal(SIGTERM, handleInterrupt)

        var finished: [EngineEvent] = []
        while true {
            if interrupted {
                finished = engine.stop()
                print("已中断。")
                break
            }
            let events = engine.tick()
            if !events.isEmpty {
                finished = events
                break
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        deliver(finished, engine: engine, notifier: notifier)
        // Headless runs leave no dangling phase behind, even when autoBreak started one.
        engine.abandonPhase()
        report(store.save(engine.state))
        print("")
        print(Format.statusText(engine))
        return 0
    }

    /// Surface persistence problems instead of silently dropping the state.
    private static func report(_ error: String?) {
        if let error { print("警告：\(error)") }
    }

    private static func deliver(_ events: [EngineEvent], engine: Engine, notifier: Notifier) {
        for event in events {
            guard let note = event.notification else { continue }
            _ = notifier.post(
                title: note.title,
                body: note.body,
                channel: engine.state.settings.notifyChannel,
                sound: engine.state.settings.sound
            )
        }
    }
}
