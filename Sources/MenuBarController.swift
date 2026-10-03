// MenuBarController — the menu bar item, its menu, and the one-second refresh loop.

import AppKit

final class MenuBarController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    private let statusLine = NSMenuItem()
    private let todayItem = NSMenuItem()
    private let pauseResumeItem = NSMenuItem()
    private let skipItem = NSMenuItem()
    private let stopItem = NSMenuItem()
    private let loginToggleItem = NSMenuItem()

    private var statsWindow: StatsWindowController?
    private var settingsWindow: SettingsWindowController?
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    /// Cached login-item state. Refreshed when the menu opens, not every second.
    private var loginItemEnabled = false

    init(model: AppModel) {
        self.model = model
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
    }

    func start() {
        statusItem.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        buildMenu()
        statusItem.menu = menu

        // A common-mode timer keeps the countdown live even while the menu is open.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.model.tick()
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // A wake only needs to resolve a deadline that passed while asleep; nothing
            // changed for a phase that is still running, so stay quiet about it.
            self?.model.reconcile(announceResumed: false)
            self?.refresh()
        }

        model.observe { [weak self] in self?.refresh() }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    // MARK: Menu construction

    private func buildMenu() {
        menu.autoenablesItems = false
        menu.delegate = self

        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())

        let defaultMinutes = model.engine.state.settings.workMinutes
        addItem("开始 \(Format.minutes(defaultMinutes)) 分钟", #selector(startDefault))
        addItem("开始 50 分钟", #selector(startFifty))
        addItem("自定义时长…", #selector(startCustom))
        menu.addItem(.separator())

        addItem("暂停", #selector(togglePause), key: "p")
        addItem("跳过当前阶段", #selector(skipPhase))
        addItem("停止", #selector(stopPhase))
        menu.addItem(.separator())

        todayItem.isEnabled = false
        menu.addItem(todayItem)
        addItem("统计…", #selector(showStats))
        addItem("测试通知", #selector(testNotification))
        menu.addItem(.separator())

        loginToggleItem.target = self
        loginToggleItem.action = #selector(toggleLoginItem)
        menu.addItem(loginToggleItem)
        addItem("设置…", #selector(showSettings), key: ",")
        menu.addItem(.separator())
        addItem("退出番茄钟", #selector(quit), key: "q")
    }

    @discardableResult
    private func addItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: Refresh

    func menuWillOpen(_ menu: NSMenu) {
        // Querying SMAppService is a synchronous round-trip to `smd`, so do it when the
        // menu is actually opened instead of once per second in the timer.
        loginItemEnabled = LoginItem.isEnabled()
        refresh()
    }

    func refresh() {
        let title = Format.menuTitle(model.engine)
        if statusItem.button?.title != title {
            statusItem.button?.title = title
        }
        statusItem.button?.toolTip = Format.phaseLine(model.engine)

        let stats = model.engine.todayStats()
        var status = Format.phaseLine(model.engine)
        if let note = model.statusNote { status += " · ⚠︎ \(note)" }
        statusLine.title = status

        todayItem.title = "今日：\(stats.completedWork) 个番茄 · \(Format.minutes(stats.focusMinutes)) 分钟专注"

        let running = !model.engine.isIdle
        let paused = model.engine.isPaused
        pauseResumeItem.title = paused ? "继续" : "暂停"
        pauseResumeItem.isEnabled = running
        skipItem.isEnabled = running
        stopItem.isEnabled = running

        loginToggleItem.title = "开机自启"
        loginToggleItem.state = loginItemEnabled ? .on : .off

        // Keep the first start item in sync with the configured work length.
        if let startDefault = menu.items.first(where: { $0.action == #selector(startDefault) }) {
            startDefault.title = "开始 \(Format.minutes(model.engine.state.settings.workMinutes)) 分钟"
        }
    }

    // MARK: Actions

    @objc private func startDefault() {
        model.mutate { $0.startWork() }
    }

    @objc private func startFifty() {
        model.mutate { $0.startWork(minutes: 50) }
    }

    @objc private func startCustom() {
        let alert = NSAlert()
        alert.messageText = "自定义专注时长"
        alert.informativeText = "输入分钟数，支持小数（例如 0.1 分钟用于快速测试）。"
        alert.addButton(withTitle: "开始")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = Format.minutes(model.engine.state.settings.workMinutes)
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Bound the value here: an out-of-range number used to reach the formatter and
        // trap the whole app.
        guard let minutes = Double(field.stringValue.trimmingCharacters(in: .whitespaces)),
              minutes.isFinite, minutes > 0, minutes <= 600 else {
            presentInfo("时长无效", "请输入大于 0 且不超过 600 的分钟数（支持小数，例如 0.1）。")
            return
        }
        model.mutate { $0.startWork(minutes: minutes) }
    }

    @objc private func togglePause() {
        model.mutate { $0.isPaused ? $0.resume() : $0.pause() }
    }

    @objc private func skipPhase() {
        model.mutate { $0.skip() }
    }

    @objc private func stopPhase() {
        model.mutate { $0.stop() }
    }

    @objc private func showStats() {
        if statsWindow == nil { statsWindow = StatsWindowController(model: model) }
        statsWindow?.show()
    }

    @objc private func showSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindowController(model: model) }
        settingsWindow?.show()
    }

    @objc private func testNotification() {
        let result = model.notifier.post(
            title: "番茄钟测试通知",
            body: "看到这条横幅、听到提示音，就说明提醒通道正常。",
            channel: model.channel,
            sound: model.engine.state.settings.sound
        )
        ReminderPanel.show(
            title: "浮窗提醒测试",
            body: "这个浮窗不需要任何系统权限，到点时一定会出现。"
        )
        var message = "系统横幅：\(result.summary)"
        if model.notifier.authorizationStatus() == .denied {
            message += "\n\n系统里本应用的通知权限为「已拒绝」。可在「系统设置 › 通知」中允许 Pomodoro，"
            message += "或在「设置…」里把通知方式改成「仅提示音」／「仅 osascript 脚本」。"
        }
        presentInfo("测试通知", message)
    }

    @objc private func toggleLoginItem() {
        let enable = !loginItemEnabled
        if let error = LoginItem.setEnabled(enable) {
            presentInfo("开机自启设置失败", error)
        }
        // Trust what the system reports, not what was requested.
        loginItemEnabled = LoginItem.isEnabled()
        refresh()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func presentInfo(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
