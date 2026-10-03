// SelfTest — headless checks for the pure engine, formatting, and persistence model.
// Run with: Pomodoro.app/Contents/MacOS/Pomodoro --selftest

import Foundation

/// Mutable clock so tests can move time forward deterministically.
final class TestClock {
    var now: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { now = start }
    func advance(_ seconds: Double) { now = now.addingTimeInterval(seconds) }
}

struct SelfTest {
    private var passed = 0
    private var failures: [String] = []
    private var calendar: Calendar
    private var clock: TestClock

    init() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        calendar = cal
        clock = TestClock()
    }

    private mutating func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
        if condition {
            passed += 1
            print("  ✓ \(name)")
        } else {
            let extra = detail()
            failures.append(name + (extra.isEmpty ? "" : " — \(extra)"))
            print("  ✗ \(name)\(extra.isEmpty ? "" : " — \(extra)")")
        }
    }

    private func makeEngine(_ state: PomodoroState = PomodoroState()) -> Engine {
        Engine(state: state, calendar: calendar, now: { [clock] in clock.now })
    }

    /// Start a 25-minute work phase, run it out, and settle any break that follows.
    /// Returns the events produced by the work phase itself.
    private func completeWork(_ engine: inout Engine) -> [EngineEvent] {
        _ = engine.startWork(minutes: 25)
        clock.advance(25 * 60)
        let events = engine.tick()
        if engine.state.phase != nil {
            clock.advance(60 * 60)
            _ = engine.tick()
        }
        return events
    }

    mutating func run() -> Int {
        print("Pomodoro self-test")
        print("")

        testStartAndTick()
        testCycleAndLongBreak()
        testSkipAndStop()
        testPauseAndResume()
        testReconcile()
        testStats()
        testStatsPeriods()
        testRetention()
        testInstanceGuard()
        testPersistence()
        testStore()
        testNotificationCount()
        testDayAttribution()
        testClockRollback()
        testPauseAtDeadline()
        testLoadedStateRepair()
        testPartialCorruption()
        testCorruptFileSalvage()
        testBackupCollision()
        testMalformedRange()
        testCLIBounds()
        testStrictArguments()
        testProcessHelper()
        testCorruptCounters()
        testHugeRetention()
        testSalvagePhase()
        testDayKeyValidation()
        testInvertedPhase()
        testLoadNoteSurvivesSave()
        testFormattingHardening()
        testFormatting()

        print("")
        if failures.isEmpty {
            print("全部通过：\(passed) 项检查")
            return 0
        }
        print("失败 \(failures.count) 项（通过 \(passed) 项）：")
        for failure in failures { print("  - \(failure)") }
        return 1
    }

    // MARK: Cases

    private mutating func testStartAndTick() {
        print("状态机：开始与到点")
        clock = TestClock()
        var engine = makeEngine()

        check("初始为空闲", engine.isIdle)

        let started = engine.startWork(minutes: 25, label: "写方案")
        check("开始返回一个事件", started.count == 1)
        check("阶段为专注", engine.state.phase?.kind == .work)
        check("剩余为 1500 秒", abs((engine.remaining() ?? 0) - 1500) < 0.001)
        check("标签已记录", engine.state.phase?.label == "写方案")

        check("重复开始被拒绝", engine.startWork(minutes: 5).isEmpty)

        clock.advance(10 * 60)
        check("未到点不产生事件", engine.tick().isEmpty)
        check("未到点仍在运行", engine.state.phase != nil)
        check("剩余约 900 秒", abs((engine.remaining() ?? 0) - 900) < 0.001)

        clock.advance(15 * 60)
        let events = engine.tick()
        check("到点产生两个事件", events.count == 2)
        if case .workCompleted(_, let next, _) = events.first {
            check("下一个阶段是短休息", next == .shortBreak)
        } else {
            check("下一个阶段是短休息", false, "首个事件不是 workCompleted")
        }
        check("自动开始休息", engine.state.phase?.kind == .shortBreak)
        print("")
    }

    private mutating func testCycleAndLongBreak() {
        print("状态机：长休息周期")
        clock = TestClock()
        var engine = makeEngine()

        var lastNext: PhaseKind?
        for index in 1...4 {
            let events = completeWork(&engine)
            if case .workCompleted(_, let next, _) = events.first {
                lastNext = next
            }
            if index < 4 {
                check("第 \(index) 个番茄后是短休息", lastNext == .shortBreak, "实际 \(String(describing: lastNext))")
            }
        }
        check("第 4 个番茄后是长休息", lastNext == .longBreak, "实际 \(String(describing: lastNext))")
        check("已完成 4 个番茄", engine.todayStats().completedWork == 4)
        check("长休息结束后周期归零", engine.state.cycleWork == 0)
        check("长休息结束回到空闲", engine.isIdle)
        print("")
    }

    private mutating func testSkipAndStop() {
        print("状态机：跳过与停止")
        clock = TestClock()
        var engine = makeEngine()

        _ = engine.startWork(minutes: 25)
        clock.advance(60)
        let skipEvents = engine.skip()
        check("跳过产生事件", !skipEvents.isEmpty)
        if case .phaseSkipped(_, let next) = skipEvents.first {
            check("跳过后进入休息", next == .shortBreak)
        } else {
            check("跳过后进入休息", false)
        }
        check("跳过不计入完成数", engine.todayStats().completedWork == 0)
        check("跳过计入跳过数", engine.todayStats().skipped == 1)

        // Stopping a break is silent; only a stopped work phase counts as interrupted.
        clock.advance(60)
        _ = engine.stop()
        check("停止休息后回到空闲", engine.isIdle)
        check("停止休息不计入中断数", engine.todayStats().interrupted == 0)

        _ = engine.startWork(minutes: 25)
        clock.advance(60)
        _ = engine.stop()
        check("停止专注后回到空闲", engine.isIdle)
        check("停止计入中断数", engine.todayStats().interrupted == 1)

        // A skipped break returns straight to idle.
        _ = engine.startWork(minutes: 25)
        clock.advance(25 * 60)
        _ = engine.tick()
        check("休息已开始", engine.state.phase?.kind == .shortBreak)
        clock.advance(30)
        _ = engine.skip()
        check("跳过休息后回到空闲", engine.isIdle)

        // autoNextWork chains the next work phase after a break.
        var chained = PomodoroState()
        chained.settings.autoNextWork = true
        var chainedEngine = makeEngine(chained)
        _ = chainedEngine.startWork(minutes: 25)
        clock.advance(25 * 60)
        _ = chainedEngine.tick()
        clock.advance(5 * 60)
        _ = chainedEngine.tick()
        check("开启自动下一个后休息结束即开始专注", chainedEngine.state.phase?.kind == .work)

        // autoBreak off leaves the app idle after a work phase.
        var manual = PomodoroState()
        manual.settings.autoBreak = false
        var manualEngine = makeEngine(manual)
        _ = manualEngine.startWork(minutes: 25)
        clock.advance(25 * 60)
        _ = manualEngine.tick()
        check("关闭自动休息后回到空闲", manualEngine.isIdle)
        print("")
    }

    private mutating func testPauseAndResume() {
        print("状态机：暂停与恢复")
        clock = TestClock()
        var engine = makeEngine()

        _ = engine.startWork(minutes: 25)
        clock.advance(5 * 60)
        _ = engine.pause()
        check("暂停标记生效", engine.isPaused)
        let frozen = engine.remaining() ?? 0
        check("暂停时剩余 1200 秒", abs(frozen - 1200) < 0.001)

        clock.advance(60 * 60)
        check("暂停期间剩余不变", abs((engine.remaining() ?? 0) - frozen) < 0.001)
        check("暂停期间不会到点", engine.tick().isEmpty)

        _ = engine.resume()
        check("恢复后未暂停", !engine.isPaused)
        check("恢复后剩余仍是 1200 秒", abs((engine.remaining() ?? 0) - 1200) < 0.001)
        print("")
    }

    private mutating func testReconcile() {
        print("状态机：重启对账")
        clock = TestClock()

        // Still running: resume with the remaining time.
        var running = makeEngine()
        _ = running.startWork(minutes: 25)
        clock.advance(5 * 60)
        let resumeEvents = running.reconcile()
        if case .phaseResumed(_, let remaining) = resumeEvents.first {
            check("未到点则按剩余时间恢复", abs(remaining - 1200) < 0.001)
        } else {
            check("未到点则按剩余时间恢复", false)
        }
        check("恢复后仍在运行", running.state.phase?.kind == .work)

        // 唤醒对账必须是无副作用的：状态不变，调用方就不会写盘、也不会弹通知。
        let snapshot = running.state
        _ = running.reconcile()
        check("仍在运行的阶段唤醒后状态不变", running.state == snapshot)

        // 暂停中的阶段在重启后必须被如实报告为「已暂停」，而不是「已恢复」。
        clock = TestClock()
        var frozen = makeEngine()
        _ = frozen.startWork(minutes: 25)
        clock.advance(5 * 60)
        _ = frozen.pause()
        if case .phaseResumed(let phase, let remaining) = frozen.reconcile().first {
            check("暂停阶段的对账事件带暂停标记", phase.isPaused)
            check("剩余时间是暂停时冻结的值", abs(remaining - 20 * 60) < 0.001)
        } else {
            check("暂停阶段的对账事件带暂停标记", false, "没有产生恢复事件")
        }

        // Deadline passed while the app was closed.
        var expired = makeEngine()
        _ = expired.startWork(minutes: 25)
        clock.advance(2 * 60 * 60)
        let awayEvents = expired.reconcile()
        if case .phaseEndedWhileAway = awayEvents.first {
            check("过期记为未运行期间结束", true)
        } else {
            check("过期记为未运行期间结束", false, "实际 \(awayEvents)")
        }
        check("过期后回到空闲", expired.isIdle)
        check("过期不补开休息", expired.state.phase == nil)
        check("过期计入统计", expired.todayStats().endedWhileAway == 1)
        check("过期不计入完成数", expired.todayStats().completedWork == 0)

        // Paused across a restart stays paused with its frozen remainder.
        var paused = makeEngine()
        _ = paused.startWork(minutes: 25)
        clock.advance(5 * 60)
        _ = paused.pause()
        clock.advance(10 * 60)
        _ = paused.reconcile()
        check("暂停状态跨重启保留", paused.isPaused)
        check("暂停剩余仍为 1200 秒", abs((paused.remaining() ?? 0) - 1200) < 0.001)
        print("")
    }

    private mutating func testStats() {
        print("统计")
        clock = TestClock()
        var engine = makeEngine()

        _ = completeWork(&engine)
        _ = completeWork(&engine)
        let stats = engine.todayStats()
        check("完成 2 个番茄", stats.completedWork == 2)
        check("专注 50 分钟", abs(stats.focusMinutes - 50) < 0.001)

        // A second day keeps separate buckets.
        let firstDayKey = engine.todayKey
        clock.advance(24 * 60 * 60)
        _ = completeWork(&engine)
        check("跨天分桶", engine.todayStats().completedWork == 1)
        check("前一天记录保留", engine.state.history[firstDayKey]?.completedWork == 2)

        let recent = engine.recentDays(14)
        check("按日期倒序返回", recent.count == 2 && recent[0].key > recent[1].key)
        check("最近天数限制生效", engine.recentDays(1).count == 1)
        print("")
    }

    private mutating func testStatsPeriods() {
        print("统计时间段与重置")
        clock = TestClock()
        // Build 20 days of history: 1 pomodoro per day, today included.
        var state = PomodoroState()
        let today = Engine.dayKey(clock.now, calendar: calendar)
        for offset in 0..<20 {
            let date = calendar.date(byAdding: .day, value: -offset, to: clock.now) ?? clock.now
            var stats = DayStats()
            stats.completedWork = offset + 1
            stats.focusMinutes = Double(offset + 1) * 25
            state.history[Engine.dayKey(date, calendar: calendar)] = stats
        }
        var engine = makeEngine(state)

        check("今天范围只含 1 天", engine.history(in: .today).count == 1)
        check("最近 7 天含 7 天", engine.history(in: .lastDays(7)).count == 7)
        check("最近 30 天含 20 天（数据只有 20 天）", engine.history(in: .lastDays(30)).count == 20)
        check("全部含 20 天", engine.history(in: .all).count == 20)
        check("最近 7 天按日期倒序", engine.history(in: .lastDays(7)).first?.key == today)

        let monthCount = engine.history(in: .thisMonth).count
        check("本月范围在 1…20 天之间", monthCount >= 1 && monthCount <= 20, "实际 \(monthCount)")

        let fromKey = Engine.dayKey(calendar.date(byAdding: .day, value: -3, to: clock.now) ?? clock.now, calendar: calendar)
        let toKey = Engine.dayKey(calendar.date(byAdding: .day, value: -1, to: clock.now) ?? clock.now, calendar: calendar)
        check("自定义区间含 3 天", engine.history(in: .custom(from: fromKey, to: toKey)).count == 3)
        check("自定义区间顺序颠倒也能用", engine.history(in: .custom(from: toKey, to: fromKey)).count == 3)

        check("关键词解析 today", StatsPeriod.parse("today") == .today)
        check("关键词解析 7", StatsPeriod.parse("7") == .lastDays(7))
        check("关键词解析 month", StatsPeriod.parse("month") == .thisMonth)
        check("关键词解析 all", StatsPeriod.parse("all") == .all)
        check("关键词解析自定义区间", StatsPeriod.parse("2026-01-01:2026-01-31") == .custom(from: "2026-01-01", to: "2026-01-31"))
        check("非法关键词被拒绝", StatsPeriod.parse("yesterday") == nil)

        // Report content. Pass the test clock so the period matches the fixture data.
        let report = StatsReport.text(engine, period: .lastDays(7), now: clock.now)
        check("报表含范围标题", report.contains("统计范围：最近 7 天"))
        check("报表含日期", report.contains(today))
        check("报表含星期", report.contains("周"))
        check("报表含合计", report.contains("合计：范围 7 天"))
        check("报表含分布条", report.contains("█"))

        let emptyReport = StatsReport.text(makeEngine(), period: .lastDays(7), now: clock.now)
        check("空报表给出提示", emptyReport.contains("还没有记录"))

        // Width helpers keep the monospaced columns aligned.
        check("中文按两格计算", StatsReport.displayWidth("日期") == 4)
        check("英文按一格计算", StatsReport.displayWidth("abc") == 3)
        check("补齐到指定宽度", StatsReport.displayWidth(StatsReport.padded("日期", 12)) == 12)
        check("右对齐补齐", StatsReport.padded("7", 5, right: true) == "    7")
        check("分布条按比例", StatsReport.bar(count: 5, max: 10).count == 10)
        check("零值不画条", StatsReport.bar(count: 0, max: 10).isEmpty)

        // Clearing a single period keeps everything else.
        let removed = engine.clearHistory(in: .lastDays(7))
        check("最近 7 天删除 7 天", removed == 7)
        check("删除后只剩 13 天", engine.state.history.count == 13)
        check("删除未波及更早记录", engine.state.history[Engine.dayKey(calendar.date(byAdding: .day, value: -10, to: clock.now) ?? clock.now, calendar: calendar)] != nil)

        engine.clearHistory(in: .all)
        check("清空全部后为空", engine.state.history.isEmpty)

        // Resetting the cycle counter leaves history alone.
        engine.state.cycleWork = 3
        engine.resetCycle()
        check("周期计数归零", engine.state.cycleWork == 0)
        print("")
    }

    private mutating func testRetention() {
        print("统计保留上限")
        clock = TestClock()
        check("默认保留 365 天", Settings().historyRetentionDays == 365)

        func key(daysAgo: Int) -> String {
            let date = calendar.date(byAdding: .day, value: -daysAgo, to: clock.now) ?? clock.now
            return Engine.dayKey(date, calendar: calendar)
        }

        // Unlimited keeps everything, including very old days.
        var unlimited = PomodoroState()
        unlimited.settings.historyRetentionDays = 0
        for daysAgo in [0, 10, 400, 900] {
            var stats = DayStats()
            stats.completedWork = 1
            unlimited.history[key(daysAgo: daysAgo)] = stats
        }
        var unlimitedEngine = makeEngine(unlimited)
        check("0 表示不限，不删除任何记录", unlimitedEngine.pruneHistory() == 0)
        check("不限时旧记录仍在", unlimitedEngine.state.history.count == 4)

        // A cap trims anything older than the window.
        var capped = unlimited
        capped.settings.historyRetentionDays = 30
        var cappedEngine = makeEngine(capped)
        let removed = cappedEngine.pruneHistory()
        check("保留 30 天时删除 2 天旧记录", removed == 2, "实际 \(removed)")
        check("保留 30 天后剩 2 天", cappedEngine.state.history.count == 2)
        check("今天的记录保留", cappedEngine.state.history[key(daysAgo: 0)] != nil)
        check("10 天前的记录保留", cappedEngine.state.history[key(daysAgo: 10)] != nil)
        check("400 天前的记录被删除", cappedEngine.state.history[key(daysAgo: 400)] == nil)
        check("最早记录键正确", cappedEngine.oldestDayKey == key(daysAgo: 10))

        // Exactly at the boundary: keeping N days means today .. today-(N-1).
        var edge = PomodoroState()
        edge.settings.historyRetentionDays = 5
        for daysAgo in 0...6 {
            var stats = DayStats()
            stats.completedWork = 1
            edge.history[key(daysAgo: daysAgo)] = stats
        }
        var edgeEngine = makeEngine(edge)
        edgeEngine.pruneHistory()
        check("保留 5 天时边界含第 5 天", edgeEngine.state.history[key(daysAgo: 4)] != nil)
        check("保留 5 天时第 6 天被删除", edgeEngine.state.history[key(daysAgo: 5)] == nil)
        check("保留 5 天后正好 5 天", edgeEngine.state.history.count == 5)

        // Recording a new day pushes the oldest day out (progressive overwrite).
        var rolling = PomodoroState()
        rolling.settings.historyRetentionDays = 3
        var rollingEngine = makeEngine(rolling)
        for daysAgo in [2, 1, 0] {
            let date = calendar.date(byAdding: .day, value: -daysAgo, to: clock.now) ?? clock.now
            var stats = DayStats()
            stats.completedWork = 1
            rollingEngine.state.history[Engine.dayKey(date, calendar: calendar)] = stats
        }
        check("滚动窗口内有 3 天", rollingEngine.state.history.count == 3)
        // Remember the absolute key that should be evicted before time moves on.
        let evictedKey = key(daysAgo: 2)
        // One day later, a fresh record arrives.
        clock.advance(24 * 60 * 60)
        _ = rollingEngine.startWork(minutes: 25)
        clock.advance(25 * 60)
        _ = rollingEngine.tick()
        check("新记录后仍是 3 天", rollingEngine.state.history.count == 3, "实际 \(rollingEngine.state.history.count)")
        check("最早的那天被覆盖", rollingEngine.state.history[evictedKey] == nil)
        check("新的一天已记录", rollingEngine.state.history[key(daysAgo: 0)] != nil)
        check("统计仍能正常累计", rollingEngine.todayStats().completedWork >= 1)

        // Sanitize clamps absurd values.
        var crazy = Settings()
        crazy.historyRetentionDays = -5
        crazy.sanitize()
        check("负数被夹到 0", crazy.historyRetentionDays == 0)
        crazy.historyRetentionDays = 99999
        crazy.sanitize()
        check("过大值被夹到 3650", crazy.historyRetentionDays == 3650)

        // The report states the policy.
        check("报表含保留策略", StatsReport.text(rollingEngine, period: .all, now: clock.now).contains("保留策略"))

        // Launch-time trimming: an oversized file is cut down and re-saved.
        // AppModel runs on the real clock and calendar, so this fixture uses them too.
        let realCalendar = Calendar.current
        let realNow = Date()
        func realKey(_ daysAgo: Int) -> String {
            let date = realCalendar.date(byAdding: .day, value: -daysAgo, to: realNow) ?? realNow
            return Engine.dayKey(date, calendar: realCalendar)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomodoro-retention-\(UUID().uuidString)")
        let store = Store(directory: directory)
        var oversized = PomodoroState()
        oversized.settings.historyRetentionDays = 30
        for daysAgo in [0, 5, 100, 400] {
            var stats = DayStats()
            stats.completedWork = 1
            oversized.history[realKey(daysAgo)] = stats
        }
        store.save(oversized)
        let model = AppModel(store: store, notifier: Notifier())
        check("启动时按上限裁剪内存状态", model.engine.state.history.count == 2, "实际 \(model.engine.state.history.count)")
        check("裁剪结果已写回磁盘", store.load().state.history.count == 2)
        check("启动提示包含裁剪信息", model.statusNote?.contains("清理") == true, model.statusNote ?? "无提示")
        try? FileManager.default.removeItem(at: directory)
        print("")
    }

    private mutating func testInstanceGuard() {
        print("单实例守卫")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomodoro-pid-\(UUID().uuidString)")
        let store = Store(directory: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        check("没有 pid 文件时认为没有实例在跑", store.runningGUIPid() == nil)

        store.writeGUIPid()
        check("写入 pid 后能认出自己", store.runningGUIPid() == getpid())

        // A second instance must not clear the running instance's marker.
        try? "1".write(to: store.pidURL, atomically: true, encoding: .utf8)
        store.clearGUIPid()
        check("不删除别的实例的 pid 文件", FileManager.default.fileExists(atPath: store.pidURL.path))

        store.writeGUIPid()
        store.clearGUIPid()
        check("删除自己的 pid 文件", !FileManager.default.fileExists(atPath: store.pidURL.path))

        // A crashed instance leaves a stale pid behind; that must not block a restart.
        try? "999999".write(to: store.pidURL, atomically: true, encoding: .utf8)
        check("死 pid 不算实例在跑", store.runningGUIPid() == nil)

        try? FileManager.default.removeItem(at: directory)
        print("")
    }

    private mutating func testPersistence() {
        print("持久化模型")
        var state = PomodoroState()
        state.settings.workMinutes = 50
        state.settings.notifyChannel = .script
        state.settings.autoNextWork = true
        state.cycleWork = 3
        state.history["2026-10-04"] = DayStats()
        state.history["2026-10-04"]?.completedWork = 3
        state.history["2026-10-04"]?.focusMinutes = 75
        state.phase = Phase(
            kind: .work,
            minutes: 50,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            endsAt: Date(timeIntervalSince1970: 1_800_003_000),
            label: "重构",
            pausedRemaining: nil
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let data = try encoder.encode(state)
            let restored = try decoder.decode(PomodoroState.self, from: data)
            check("JSON 往返一致", restored == state)
            check("设置项保留", restored.settings.workMinutes == 50 && restored.settings.notifyChannel == .script)
            check("阶段保留", restored.phase?.label == "重构")
        } catch {
            check("JSON 往返一致", false, "\(error)")
        }

        // Missing fields fall back to defaults instead of failing the whole file.
        let partial = Data(#"{"version":1,"settings":{"workMinutes":30}}"#.utf8)
        do {
            let restored = try decoder.decode(PomodoroState.self, from: partial)
            check("缺字段用默认值补齐", restored.settings.workMinutes == 30 && restored.settings.shortBreakMinutes == 5)
            check("缺失历史为空", restored.history.isEmpty)
            check("缺失阶段为空闲", restored.phase == nil)
            check("浮窗提醒默认开启", restored.settings.onscreen)
        } catch {
            check("缺字段用默认值补齐", false, "\(error)")
        }
        print("")
    }

    private mutating func testStore() {
        print("持久化文件")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomodoro-selftest-\(UUID().uuidString)")
        let store = Store(directory: directory)

        var state = PomodoroState()
        state.settings.workMinutes = 30
        state.history["2026-10-04"] = DayStats()
        state.history["2026-10-04"]?.completedWork = 2
        let now = Date()
        state.phase = Phase(
            kind: .work,
            minutes: 30,
            startedAt: now,
            endsAt: now.addingTimeInterval(1800),
            label: nil,
            pausedRemaining: nil
        )

        check("没有文件时返回默认状态", store.load().state.settings.workMinutes == 25)
        check("保存无错误", store.save(state) == nil)

        let loaded = store.load()
        check("重新读取设置一致", loaded.state.settings.workMinutes == 30)
        check("重新读取历史一致", loaded.state.history["2026-10-04"]?.completedWork == 2)
        if let phase = loaded.state.phase {
            check("时间精度保留到毫秒", abs(phase.endsAt.timeIntervalSince(now.addingTimeInterval(1800))) < 0.002)
        } else {
            check("时间精度保留到毫秒", false, "阶段丢失")
        }

        // A corrupt file must be moved aside instead of crashing or silently resetting.
        try? Data("{ this is not json".utf8).write(to: store.stateURL)
        let broken = store.load()
        check("损坏文件回退默认", broken.state.settings.workMinutes == 25)
        check("损坏文件给出提示", broken.note != nil)
        let backups = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasPrefix("state.json.bak-") } ?? []
        check("损坏文件已备份", backups.count == 1, "备份数 \(backups.count)")

        try? FileManager.default.removeItem(at: directory)
        print("")
    }

    /// One phase transition must produce exactly one notification. Two banners, two
    /// cards and two sounds per pomodoro was a real bug that no test caught.
    private mutating func testNotificationCount() {
        print("通知：一次转换只发一条")
        clock = TestClock()
        var engine = makeEngine()
        _ = engine.startWork(minutes: 25)
        clock.advance(25 * 60 + 1)
        let events = engine.tick()
        let notes = events.compactMap { $0.notification }
        check("完成一个番茄只产生一条通知", notes.count == 1, "实际 \(notes.count) 条")
        check("自动开始的休息是静默事件", events.contains { event in
            if case .phaseAutoStarted = event { return true }
            return false
        })
        check("休息确实开始了", engine.state.phase?.kind == .shortBreak)
        check("完成通知仍然存在", notes.first?.title == "🍅 番茄完成")

        clock = TestClock()
        var skipping = makeEngine()
        _ = skipping.startWork(minutes: 25)
        let skipEvents = skipping.skip()
        check("跳过也只产生一条通知", skipEvents.compactMap { $0.notification }.count == 1)

        // 关闭自动休息时不应凭空多出事件
        clock = TestClock()
        var manual = PomodoroState()
        manual.settings.autoBreak = false
        var manualEngine = makeEngine(manual)
        _ = manualEngine.startWork(minutes: 25)
        clock.advance(25 * 60 + 1)
        let manualEvents = manualEngine.tick()
        check("关闭自动休息时只有完成事件", manualEvents.count == 1)
        check("关闭自动休息后确实空闲", manualEngine.isIdle)
        print("")
    }

    /// A phase that ran out while the app was closed belongs to the day it ended, not to
    /// the day the app happened to be reopened.
    private mutating func testDayAttribution() {
        print("统计：阶段归属到真正结束的那天")
        // 23:25 开始、23:50 结束，第二天早上才重新打开应用。
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 23, minute: 25))!
        clock = TestClock(start)
        var engine = makeEngine()
        _ = engine.startWork(minutes: 25)
        clock.now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 9))!
        let events = engine.reconcile()
        check("跨夜阶段被判定为已结束", events.count == 1)
        check("记在结束日 2026-10-03",
              engine.state.history["2026-10-03"]?.endedWhileAway == 1,
              "实际 \(engine.state.history.keys.sorted())")
        check("没有记到重新启动的那天", engine.state.history["2026-10-04"] == nil)
        check("专注分钟记在结束日", engine.state.history["2026-10-03"]?.focusMinutes == 25)

        // 结束于次日 00:15 的阶段属于 10-04 —— 也就是它真正结束的那一天。
        clock = TestClock(calendar.date(from: DateComponents(year: 2026, month: 10, day: 3, hour: 23, minute: 50))!)
        var late = makeEngine()
        _ = late.startWork(minutes: 25)
        clock.now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 4, hour: 9))!
        _ = late.reconcile()
        check("结束于次日 00:15 的阶段记在 10-04",
              late.state.history["2026-10-04"]?.endedWhileAway == 1,
              "实际 \(late.state.history.keys.sorted())")
        print("")
    }

    /// A backwards clock jump must not inflate a countdown.
    private mutating func testClockRollback() {
        print("时间：时钟回拨不会让剩余时间变长")
        clock = TestClock()
        var engine = makeEngine()
        _ = engine.startWork(minutes: 25)
        clock.advance(10 * 60)
        check("前进 10 分钟后剩余 900 秒", abs((engine.remaining() ?? 0) - 900) < 0.001)
        clock.now = clock.now.addingTimeInterval(-60 * 60)
        check("回拨 1 小时后剩余不超过计划时长",
              (engine.remaining() ?? 0) <= 25 * 60 + 0.001,
              "实际 \(engine.remaining() ?? -1)")
        check("回拨后显示为完整的 25 分钟", abs((engine.remaining() ?? 0) - 25 * 60) < 0.001)
        print("")
    }

    /// Pausing at or after the deadline used to freeze the phase at 00:00 forever.
    private mutating func testPauseAtDeadline() {
        print("状态机：截止后暂停不再卡死")
        // 关闭自动休息，这样"阶段是否结束"一眼可见。
        var manual = PomodoroState()
        manual.settings.autoBreak = false
        clock = TestClock()
        var engine = makeEngine(manual)
        _ = engine.startWork(minutes: 25)
        clock.advance(25 * 60 + 5)                 // 已过期，但 tick 还没跑
        let events = engine.pause()
        check("过期后暂停直接结束该阶段", engine.state.phase == nil)
        check("计入一次完成",
              engine.state.history[Engine.dayKey(clock.now, calendar: calendar)]?.completedWork == 1)
        check("产生完成通知", events.first?.notification?.title == "🍅 番茄完成")
        check("不会留下 00:00 的僵尸阶段", engine.remaining() == nil)

        // 默认设置下，过期暂停会结束专注并自动开始休息。
        clock = TestClock()
        var auto = makeEngine()
        _ = auto.startWork(minutes: 25)
        clock.advance(25 * 60 + 5)
        _ = auto.pause()
        check("默认设置下自动开始休息", auto.state.phase?.kind == .shortBreak)

        clock = TestClock()
        var normal = makeEngine()
        _ = normal.startWork(minutes: 25)
        clock.advance(5 * 60)
        _ = normal.pause()
        check("正常暂停仍然生效", normal.isPaused)
        clock.advance(60 * 60)
        check("暂停期间剩余时间不变", abs((normal.remaining() ?? 0) - 20 * 60) < 0.001)
        check("暂停阶段不会被 tick 结束", normal.tick().isEmpty)
        print("")
    }

    /// Impossible values in a hand-edited file are repaired instead of acted on.
    private mutating func testLoadedStateRepair() {
        print("载入：异常数值被修正")
        var state = PomodoroState()
        state.settings.workMinutes = -5
        state.settings.longBreakEvery = 0
        state.settings.workMinutes = .nan
        state.cycleWork = -3
        state.phase = Phase(kind: .work, minutes: -25,
                            startedAt: clock.now,
                            endsAt: clock.now.addingTimeInterval(60),
                            label: nil, pausedRemaining: nil)
        state.history["2026-10-01"] = DayStats()
        state.history["不是日期"] = DayStats()
        var engine = Engine(state: state, calendar: calendar, now: { [clock] in clock.now })
        check("检测到需要修正", engine.sanitizeLoadedState())
        check("NaN 时长回落默认 25", engine.state.settings.workMinutes == 25,
              "实际 \(engine.state.settings.workMinutes)")
        check("长休间隔被夹到 1", engine.state.settings.longBreakEvery == 1)
        check("周期计数归零", engine.state.cycleWork == 0)
        check("负数阶段被丢弃", engine.state.phase == nil)
        check("非法日期键被清理", engine.state.history.keys.sorted() == ["2026-10-01"])

        var healthy = PomodoroState()
        healthy.history["2026-10-01"] = DayStats()
        var clean = Engine(state: healthy, calendar: calendar, now: { [clock] in clock.now })
        check("正常状态不报告修正", !clean.sanitizeLoadedState())
        print("")
    }

    /// The silent-data-loss regression: one unreadable field must cost one field only.
    private mutating func testPartialCorruption() {
        print("持久化：单个坏字段不再丢整段数据")
        let json = """
        {
          "version": 1,
          "settings": {"workMinutes": "坏数据", "shortBreakMinutes": 7},
          "history": {
            "2026-10-01": {"completedWork": 3, "focusMinutes": 75},
            "2026-10-02": {"completedWork": "坏数据"}
          },
          "cycleWork": 2
        }
        """
        let state = try? Store.makeDecoder().decode(PomodoroState.self, from: Data(json.utf8))
        check("整份状态仍能解码（不再静默丢段）", state != nil)
        check("合法的那天完整保留", state?.history["2026-10-01"]?.completedWork == 3)
        check("合法那天的分钟保留", state?.history["2026-10-01"]?.focusMinutes == 75)
        check("坏字段那天仍然存在", state?.history["2026-10-02"] != nil)
        check("坏字段回落为 0", state?.history["2026-10-02"]?.completedWork == 0)
        check("同段其它设置保留", state?.settings.shortBreakMinutes == 7)
        check("坏设置字段回落默认", state?.settings.workMinutes == 25)
        check("周期计数保留", state?.cycleWork == 2)
        print("")
    }

    /// A structurally broken file is still backed up and salvaged.
    private mutating func testCorruptFileSalvage() {
        print("持久化：结构性损坏会备份并尽力恢复")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomodoro-selftest-salvage-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = Store(directory: directory)
        let json = #"{"version":1,"settings":{"workMinutes":40},"history":[1,2,3],"cycleWork":1}"#
        try? Data(json.utf8).write(to: store.stateURL)
        let loaded = store.load()
        check("给出损坏提示", loaded.note != nil)
        check("提示里点名了备份文件", loaded.note?.contains("state.json.bak-") == true)
        check("原文件已备份", Self.backups(in: directory).count == 1)
        check("抢救回设置", loaded.state.settings.workMinutes == 40)
        check("抢救回周期计数", loaded.state.cycleWork == 1)
        check("无法解析的历史为空", loaded.state.history.isEmpty)
        try? FileManager.default.removeItem(at: directory)

        // 某一天是字符串而不是对象。JSONSerialization 对非容器顶层值会抛出
        // Objective-C 异常（Swift 无法捕获，直接 abort），所以这一天必须被跳过。
        let mixed = #"{"version":1,"settings":{"workMinutes":40},"history":{"2026-10-01":{"completedWork":5,"focusMinutes":125,"skipped":0,"interrupted":0,"endedWhileAway":0},"2026-10-02":"彻底坏掉"},"cycleWork":3}"#
        let recovered = PomodoroState.salvaging(Data(mixed.utf8))
        check("部分可救时不会崩溃", recovered != nil)
        check("可读的那天被保留", recovered?.history["2026-10-01"]?.completedWork == 5)
        check("可读那天的分钟被保留", recovered?.history["2026-10-01"]?.focusMinutes == 125)
        check("坏掉的那天被跳过", recovered?.history["2026-10-02"] == nil)
        check("设置同时被抢救", recovered?.settings.workMinutes == 40)
        check("周期计数同时被抢救", recovered?.cycleWork == 3)
        print("")
    }

    /// Two corruptions inside the same second must both leave a backup.
    private mutating func testBackupCollision() {
        print("持久化：同一秒内的两次损坏都留有备份")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomodoro-selftest-collision-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = Store(directory: directory)
        try? Data("bad one".utf8).write(to: store.stateURL)
        _ = store.load()
        try? Data("bad two".utf8).write(to: store.stateURL)
        _ = store.load()
        let backups = Self.backups(in: directory)
        check("两次损坏都留下了备份", backups.count == 2, "实际 \(backups.count)")
        check("备份文件名互不覆盖", Set(backups).count == backups.count)
        try? FileManager.default.removeItem(at: directory)
        print("")
    }

    private static func backups(in directory: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasPrefix("state.json.bak-") }
    }

    /// A malformed custom range must never be accepted, and must never delete anything.
    private mutating func testMalformedRange() {
        print("统计：畸形范围不会被接受")
        check("非日期范围解析失败", StatsPeriod.parse("zzzzzzzzzz:0000000000") == nil)
        check("月/日越界被拒", StatsPeriod.parse("2026-13-01:2026-13-31") == nil)
        check("半截范围被拒", StatsPeriod.parse("2026-01-01:") == nil)
        check("真实日期范围解析成功", StatsPeriod.parse("2026-01-01:2026-01-31") != nil)
        check("全量关键字仍然有效", StatsPeriod.parse("all") != nil)

        var engine = makeEngine()
        engine.state.history["2026-10-01"] = DayStats()
        engine.state.history["2026-10-02"] = DayStats()
        let malformed = engine.clearHistory(in: .custom(from: "zzzzzzzzzz", to: "0000000000"))
        check("畸形范围不删除任何记录", malformed == 0, "删除了 \(malformed) 天")
        check("历史原封不动", engine.state.history.count == 2)
        // 顺序颠倒但合法的区间是既有的便利行为：按命名的那两天处理，不额外扩大范围。
        let reversed = engine.clearHistory(in: .custom(from: "2026-10-02", to: "2026-10-01"))
        check("颠倒但合法的区间仍按这两天处理", reversed == 2, "删除了 \(reversed) 天")
        check("没有误删范围外的记录", engine.state.history.isEmpty)
        print("")
    }

    /// CLI parsing must reject durations that used to crash or hang the process, and must
    /// report the rejection with a non-zero status.
    private mutating func testCLIBounds() {
        print("CLI：越界时长与未知参数")
        func isInvalid(_ arguments: [String]) -> Bool {
            guard let mode = CLI.parse(arguments) else { return false }
            if case .invalidUsage = mode { return true }
            return false
        }
        func isHelp(_ arguments: [String]) -> Bool {
            guard let mode = CLI.parse(arguments) else { return false }
            if case .help = mode { return true }
            return false
        }
        check("--once 1e20 被拒", isInvalid(["--once", "1e20"]))
        check("--once inf 被拒", isInvalid(["--once", "inf"]))
        check("--once nan 被拒", isInvalid(["--once", "nan"]))
        check("--once 0 被拒", isInvalid(["--once", "0"]))
        check("--once -5 被拒", isInvalid(["--once", "-5"]))
        check("--once 601 被拒", isInvalid(["--once", "601"]))
        check("--once 25 通过", !isInvalid(["--once", "25"]))
        check("--once 0.1 通过", !isInvalid(["--once", "0.1"]))
        check("未知参数判为用法错误而不是启动 GUI", isInvalid(["stat"]))
        check("--help 仍然正常", isHelp(["--help"]))
        check("非法统计范围判为用法错误", isInvalid(["--stats", "zzzzzzzzzz:0000000000"]))
        check("无参数仍然启动菜单栏", CLI.parse([]) == nil)
        check("用法错误的退出码非零", CLI.run(.invalidUsage) == 2)
        print("")
    }

    /// The child-process helper must not leak descriptors, mis-time a chatty child,
    /// or leave a SIGTERM-ignoring child running.
    private mutating func testProcessHelper() {
        print("子进程：不泄漏 fd、不误判超时、不留孤儿")
        let before = Self.openFileDescriptors()
        for _ in 0..<40 { _ = Notifier.runProcess("/bin/echo", arguments: ["hi"], timeout: 5) }
        let after = Self.openFileDescriptors()
        check("40 次调用后 fd 不增长", after - before <= 0, "净增 \(after - before)")

        let big = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomodoro-selftest-big-\(UUID().uuidString).txt")
        try? Data(repeating: 0x41, count: 300_000).write(to: big)
        // Write the 300KB to *stderr* — the stream that used to be an undrained pipe.
        // Sending it to stdout (now /dev/null) would make this check vacuous.
        let started = Date()
        let chatty = Notifier.runProcess(
            "/bin/sh",
            arguments: ["-c", "cat '\(big.path)' >&2"],
            timeout: 5
        )
        let elapsed = Date().timeIntervalSince(started)
        check("向 stderr 写 300KB 的子进程正常结束",
              chatty.code == 0 && !chatty.timedOut,
              "code=\(chatty.code) timedOut=\(chatty.timedOut)")
        check("且没有白白耗尽超时", elapsed < 2, "耗时 \(String(format: "%.2f", elapsed))s")
        check("stderr 内容被完整收集", chatty.stderr.count >= 300_000, "只收到 \(chatty.stderr.count) 字节")
        try? FileManager.default.removeItem(at: big)

        let marker = "POMODORO_SELFTEST_STUBBORN_MARKER"
        let stubborn = Notifier.runProcess(
            "/bin/sh",
            arguments: ["-c", "trap '' TERM; sleep 30 # \(marker)"],
            timeout: 0.3
        )
        check("忽略 SIGTERM 的子进程被判为超时", stubborn.timedOut)
        check("忽略 SIGTERM 的子进程已被清理", !Self.processExists(matching: marker))
        print("")
    }

    private static func openFileDescriptors() -> Int {
        let bytes = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
        return Int(bytes) / MemoryLayout<proc_fdinfo>.size
    }

    private static func processExists(matching marker: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", marker]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Formatters must saturate instead of trapping on absurd input.
    private mutating func testFormattingHardening() {
        print("格式化：越界输入不再崩溃")
        check("极大分钟不崩溃", !Format.minutes(1e20).isEmpty)
        check("极大分钟被夹住", Format.minutes(1e20) == Format.minutes(1e15))
        check("无穷分钟不崩溃", Format.minutes(.infinity) == "∞")
        check("负无穷分钟归零", Format.minutes(-.infinity) == "0")
        check("NaN 分钟不崩溃", Format.minutes(.nan) == "0")
        check("极大秒数不崩溃", !Format.clock(1e20).isEmpty)
        check("无穷秒数不崩溃", !Format.clock(.infinity).isEmpty)
        check("NaN 秒数归零", Format.clock(.nan) == "00:00")
        // %d truncated the 64-bit hour count into a negative number.
        check("极大小时数不出现负数", !Format.clock(1e15).contains("-"), Format.clock(1e15))
        check("正常值不受影响", Format.minutes(25) == "25" && Format.clock(1500) == "25:00")
        print("")
    }

    /// A corrupt counter reached `+= 1` and report totals and trapped the process.
    private mutating func testCorruptCounters() {
        print("统计：损坏的计数器不会溢出崩溃")
        clock = TestClock()
        let key = Engine.dayKey(clock.now, calendar: calendar)
        var state = PomodoroState()
        state.history[key] = DayStats()
        state.history[key]?.completedWork = .max
        state.history[key]?.focusMinutes = .greatestFiniteMagnitude
        state.cycleWork = .max

        var engine = Engine(state: state, calendar: calendar, now: { [clock] in clock.now })
        check("载入体检检测到需要修正", engine.sanitizeLoadedState())
        check("计数器被夹到上限", engine.state.history[key]?.completedWork == Engine.counterLimit)
        check("专注分钟被夹住", engine.state.history[key]?.focusMinutes == Engine.focusMinuteLimit)
        check("周期计数被夹住", engine.state.cycleWork == Engine.counterLimit)

        // 未经 sanitize 的路径也必须安全：`+= 1` 曾经在这里 SIGTRAP。
        var raw = Engine(state: state, calendar: calendar, now: { [clock] in clock.now })
        _ = raw.startWork(minutes: 25)
        clock.advance(25 * 60 + 1)
        let events = raw.tick()
        check("未修正的计数器也能安全完成", !events.isEmpty)
        check("完成后计数没有溢出",
              raw.state.history.values.allSatisfy { $0.completedWork >= 0 && $0.completedWork <= Engine.counterLimit })

        // 报表合计曾经在 reduce 里溢出。
        let report = StatsReport.text(raw, period: .all, now: clock.now)
        check("报表在损坏计数器下仍可渲染", report.contains("合计"))

        var two = PomodoroState()
        two.history["2026-10-01"] = DayStats()
        two.history["2026-10-02"] = DayStats()
        two.history["2026-10-01"]?.completedWork = .max
        two.history["2026-10-02"]?.completedWork = .max
        let twoEngine = Engine(state: two, calendar: calendar, now: { [clock] in clock.now })
        check("两天都是 Int.max 也能渲染报表",
              StatsReport.text(twoEngine, period: .all, now: clock.now).contains("合计"))
        print("")
    }

    /// An absurd retention saturated the cutoff date into the far future, so every day
    /// counted as "older than the window" and the whole history was deleted.
    private mutating func testHugeRetention() {
        print("统计：异常保留天数不会删光历史")
        clock = TestClock()
        var state = PomodoroState()
        state.settings.historyRetentionDays = .max
        state.history["2026-10-01"] = DayStats()
        state.history["2026-10-02"] = DayStats()
        state.history["2026-10-03"] = DayStats()
        var engine = Engine(state: state, calendar: calendar, now: { [clock] in clock.now })

        let removed = engine.pruneHistory()
        check("未修正的保留天数不会删记录", removed == 0, "删除了 \(removed) 天")
        check("历史完好无损", engine.state.history.count == 3)

        check("载入体检会夹住保留天数", engine.sanitizeLoadedState())
        check("保留天数被夹到 3650", engine.state.settings.historyRetentionDays == 3650)
        check("夹住之后依然不误删", engine.pruneHistory() == 0)
        print("")
    }

    /// `salvaging` used a bare JSONDecoder, so the ISO-8601 date strategy was missing and
    /// `phase` — the only section carrying dates — could never be recovered.
    private mutating func testSalvagePhase() {
        print("持久化：抢救时也能恢复阶段")
        let json = #"{"version":1,"settings":{"workMinutes":25},"history":[1,2],"phase":{"kind":"work","minutes":25,"startedAt":"2026-10-04T01:00:00Z","endsAt":"2026-10-04T01:25:00Z","label":"抢救","pausedRemaining":null},"cycleWork":1}"#
        let recovered = PomodoroState.salvaging(Data(json.utf8))
        check("抢救成功", recovered != nil)
        check("阶段被恢复", recovered?.phase != nil, "阶段仍然丢失")
        check("阶段标签保留", recovered?.phase?.label == "抢救")
        check("阶段时长保留", recovered?.phase?.minutes == 25)
        check("阶段日期被正确解析（相隔 25 分钟）",
              recovered.map { abs($0.phase!.endsAt.timeIntervalSince($0.phase!.startedAt) - 25 * 60) < 1 } ?? false)
        check("坏掉的历史仍为空", recovered?.history.isEmpty == true)
        check("周期计数保留", recovered?.cycleWork == 1)
        print("")
    }

    /// Surplus and unknown arguments used to be skipped silently, which is how
    /// `--once 25 --bogus --help` started a real 25-minute timer.
    private mutating func testStrictArguments() {
        print("CLI：多余参数不再被静默忽略")
        func isInvalid(_ arguments: [String]) -> Bool {
            guard let mode = CLI.parse(arguments) else { return false }
            if case .invalidUsage = mode { return true }
            return false
        }
        check("--once 25 --bogus 被拒", isInvalid(["--once", "25", "--bogus"]))
        check("--once 25 --help 被拒", isInvalid(["--once", "25", "--help"]))
        check("--once 25 --label 缺值被拒", isInvalid(["--once", "25", "--label"]))
        check("--once 25 --label x --force 通过", !isInvalid(["--once", "25", "--label", "x", "--force"]))
        check("--once 0.001 被拒（低于引擎下限）", isInvalid(["--once", "0.001"]))
        check("--once 0.01 通过", !isInvalid(["--once", "0.01"]))
        check("--stats 14 extra 被拒", isInvalid(["--stats", "14", "extra"]))
        check("--stats 14 通过", !isInvalid(["--stats", "14"]))
        check("--status extra 被拒", isInvalid(["--status", "extra"]))
        check("--status 通过", !isInvalid(["--status"]))
        check("--reset-stats all --yes 通过", !isInvalid(["--reset-stats", "all", "--yes"]))
        check("--reset-stats all --nope 被拒", isInvalid(["--reset-stats", "all", "--nope"]))
        check("--login-item 无参数被拒", isInvalid(["--login-item"]))
        check("--login-item bogus 被拒", isInvalid(["--login-item", "bogus"]))
        check("--login-item status 通过", !isInvalid(["--login-item", "status"]))
        check("--help extra 被拒", isInvalid(["--help", "extra"]))
        print("")
    }

    /// Shape-only validation accepted days that do not exist.
    private mutating func testDayKeyValidation() {
        print("统计：日期必须是真实存在的日子")
        check("2026-02-31 被拒", !Engine.isDayKey("2026-02-31"))
        check("2026-02-28 接受", Engine.isDayKey("2026-02-28"))
        check("2026-13-01 被拒", !Engine.isDayKey("2026-13-01"))
        check("2026-00-10 被拒", !Engine.isDayKey("2026-00-10"))
        check("闰年 2024-02-29 接受", Engine.isDayKey("2024-02-29"))
        check("平年 2026-02-29 被拒", !Engine.isDayKey("2026-02-29"))
        check("all 下界 0001-01-01 接受", Engine.isDayKey("0001-01-01"))
        check("all 上界 9999-12-31 接受", Engine.isDayKey("9999-12-31"))
        check("不存在的日期范围解析被拒", StatsPeriod.parse("2026-02-31:2026-03-01") == nil)
        print("")
    }

    /// An inverted phase finishes instantly and would be recorded as a completed pomodoro.
    private mutating func testInvertedPhase() {
        print("载入：时间倒置的阶段被丢弃")
        var state = PomodoroState()
        state.phase = Phase(kind: .work, minutes: 25,
                            startedAt: clock.now,
                            endsAt: clock.now.addingTimeInterval(-60),
                            label: nil, pausedRemaining: nil)
        var engine = Engine(state: state, calendar: calendar, now: { [clock] in clock.now })
        check("倒置阶段被检测到", engine.sanitizeLoadedState())
        check("倒置阶段被丢弃", engine.state.phase == nil)
        print("")
    }

    /// A successful save used to wipe the corruption warning along with the write error.
    private mutating func testLoadNoteSurvivesSave() {
        print("持久化：损坏提示不会被一次成功写盘抹掉")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomodoro-selftest-note-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = Store(directory: directory)
        try? Data("{ broken".utf8).write(to: store.stateURL)
        let model = AppModel(store: store, notifier: Notifier())
        check("载入后有损坏提示", model.statusNote?.contains("损坏") == true, model.statusNote ?? "无提示")
        model.commit()
        check("成功写盘后损坏提示仍在",
              model.statusNote?.contains("损坏") == true,
              model.statusNote ?? "提示被抹掉了")
        try? FileManager.default.removeItem(at: directory)
        print("")
    }

    private mutating func testFormatting() {
        print("格式化与转义")
        check("分钟取整", Format.minutes(25) == "25")
        check("分钟保留小数", Format.minutes(0.1) == "0.1")
        check("分钟去掉尾零", Format.minutes(2.50) == "2.5")
        check("时钟补零", Format.clock(65) == "01:05")
        check("时钟跨小时", Format.clock(3725) == "1:02:05")
        check("负数归零", Format.clock(-5) == "00:00")

        check("转义引号", Format.escapeAppleScript("say \"hi\"") == "say \\\"hi\\\"")
        check("转义反斜杠", Format.escapeAppleScript("a\\b") == "a\\\\b")
        check("换行转空格", Format.escapeAppleScript("a\nb") == "a b")
        check("中文保留", Format.escapeAppleScript("写方案") == "写方案")

        let script = Format.notificationScript(title: "标题", body: "正文 \"x\"", sound: true)
        check("脚本含标题", script.contains("with title \"标题\""))
        check("脚本含声音", script.contains("sound name \"Glass\""))
        check("关闭声音时无 sound", !Format.notificationScript(title: "t", body: "b", sound: false).contains("sound name"))

        let dayKey = Engine.dayKey(Date(timeIntervalSince1970: 1_800_000_000), calendar: calendar)
        check("日期键格式", dayKey.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil, dayKey)
        print("")
    }
}
