// Windows — the two auxiliary windows: a read-only stats report and a settings form.

import AppKit

final class StatsWindowController: NSObject {
    private let model: AppModel
    private var window: NSWindow?
    private var textView: NSTextView?
    private var observerToken: UUID?

    private let periodPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fromPicker = NSDatePicker()
    private let toPicker = NSDatePicker()
    private let customRow = NSStackView()
    private let resetCycleBox = NSButton(checkboxWithTitle: "同时重置番茄周期计数", target: nil, action: nil)

    /// Index of the "自定义…" entry, which sits after the presets.
    private let customIndex = StatsPeriod.presets.count

    private var period: StatsPeriod = .lastDays(14)

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func show() {
        _ = buildIfNeeded()
        refresh()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Build the window on first use. Exposed so `--ui-selftest` can construct
    /// both windows without showing them.
    @discardableResult
    func buildIfNeeded() -> NSWindow? {
        if window == nil { build() }
        return window
    }

    private func build() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "番茄钟统计"
        window.isReleasedWhenClosed = false
        window.center()

        // Range selector.
        for preset in StatsPeriod.presets {
            periodPopup.addItem(withTitle: preset.displayName)
        }
        periodPopup.addItem(withTitle: "自定义…")
        periodPopup.target = self
        periodPopup.action = #selector(periodChanged)
        periodPopup.selectItem(at: 2) // 最近 14 天

        for picker in [fromPicker, toPicker] {
            picker.datePickerStyle = .textFieldAndStepper
            picker.datePickerElements = [.yearMonthDay]
            picker.target = self
            picker.action = #selector(customDatesChanged)
            picker.isHidden = true
        }
        fromPicker.dateValue = Calendar.current.date(byAdding: .day, value: -13, to: Date()) ?? Date()
        toPicker.dateValue = Date()

        let rangeLabel = NSTextField(labelWithString: "统计范围：")
        let toLabel = NSTextField(labelWithString: "至")
        toLabel.isHidden = true
        customRow.orientation = .horizontal
        customRow.spacing = 6
        customRow.addArrangedSubview(toLabel)
        customRow.addArrangedSubview(toPicker)
        customRow.isHidden = true
        self.toLabel = toLabel

        let refreshButton = NSButton(title: "刷新", target: self, action: #selector(refreshTapped))
        let copyButton = NSButton(title: "复制报告", target: self, action: #selector(copyReport))
        let resetButton = NSButton(title: "重置统计…", target: self, action: #selector(resetStats))

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let controls = NSStackView(views: [rangeLabel, periodPopup, fromPicker, customRow, spacer, refreshButton, copyButton, resetButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.translatesAutoresizingMaskIntoConstraints = false

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainerInset = NSSize(width: 12, height: 12)
        scroll.documentView = textView

        resetCycleBox.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(controls)
        content.addSubview(scroll)
        content.addSubview(resetCycleBox)
        NSLayoutConstraint.activate([
            controls.topAnchor.constraint(equalTo: content.topAnchor, constant: 14),
            controls.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            resetCycleBox.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            resetCycleBox.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            resetCycleBox.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
        ])
        window.contentView = content

        self.window = window
        self.textView = textView

        // Keep the report live while pomodoros complete.
        observerToken = model.observe { [weak self] in
            guard let self, self.window?.isVisible == true else { return }
            self.refresh()
        }
    }

    private var toLabel: NSTextField?

    // MARK: Actions

    @objc private func periodChanged() {
        let index = periodPopup.indexOfSelectedItem
        let isCustom = index == customIndex
        fromPicker.isHidden = !isCustom
        customRow.isHidden = !isCustom
        toLabel?.isHidden = !isCustom
        if isCustom {
            period = .custom(from: dayKey(fromPicker.dateValue), to: dayKey(toPicker.dateValue))
        } else if index >= 0, index < StatsPeriod.presets.count {
            period = StatsPeriod.presets[index]
        }
        refresh()
    }

    @objc private func customDatesChanged() {
        period = .custom(from: dayKey(fromPicker.dateValue), to: dayKey(toPicker.dateValue))
        refresh()
    }

    @objc private func refreshTapped() {
        refresh()
    }

    @objc private func copyReport() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(textView?.string ?? "", forType: .string)
    }

    @objc private func resetStats() {
        let calendar = model.engine.calendar
        let scope = period.describedRange(now: Date(), calendar: calendar)
        let affected = model.engine.history(in: period).count
        let resetCycle = resetCycleBox.state == .on

        let alert = NSAlert()
        alert.messageText = "重置统计"
        alert.informativeText = """
        将要删除的统计记录：\(scope)
        命中 \(affected) 天的记录\(resetCycle ? "，并把番茄周期计数归零" : "")。
        设置与当前计时不受影响，删除后无法恢复。
        """
        alert.addButton(withTitle: "删除所选时间段")
        alert.addButton(withTitle: "清空全部记录")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }

        let target: StatsPeriod = response == .alertSecondButtonReturn ? .all : period
        let removed = model.engine.clearHistory(in: target)
        if resetCycle { model.engine.resetCycle() }
        model.commit()
        refresh()

        let done = NSAlert()
        done.messageText = "统计已重置"
        done.informativeText = "已删除 \(removed) 天的记录（\(target.describedRange(now: Date(), calendar: calendar))）。"
        done.addButton(withTitle: "好")
        done.runModal()
    }

    // MARK: Rendering

    func refresh() {
        var text = StatsReport.text(model.engine, period: period)
        text += "\n\n数据文件：\(model.store.stateURL.path)"
        if let note = model.statusNote { text += "\n提示：\(note)" }
        textView?.string = text
    }

    private func dayKey(_ date: Date) -> String {
        Engine.dayKey(date, calendar: model.engine.calendar)
    }
}

final class SettingsWindowController: NSObject {
    private let model: AppModel
    private var window: NSWindow?

    private let workField = NSTextField(string: "")
    private let shortField = NSTextField(string: "")
    private let longField = NSTextField(string: "")
    private let everyField = NSTextField(string: "")
    private let retentionField = NSTextField(string: "")
    private let autoBreakBox = NSButton(checkboxWithTitle: "专注结束后自动开始休息", target: nil, action: nil)
    private let autoNextBox = NSButton(checkboxWithTitle: "休息结束后自动开始下一个番茄", target: nil, action: nil)
    private let soundBox = NSButton(checkboxWithTitle: "提醒时播放系统提示音", target: nil, action: nil)
    private let onscreenBox = NSButton(checkboxWithTitle: "到点时在屏幕右上角弹出浮窗提醒", target: nil, action: nil)
    private let channelPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func show() {
        _ = buildIfNeeded()
        load()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Build the window on first use. Exposed so `--ui-selftest` can construct
    /// both windows without showing them.
    @discardableResult
    func buildIfNeeded() -> NSWindow? {
        if window == nil { build() }
        return window
    }

    private func build() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 410),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "番茄钟设置"
        window.isReleasedWhenClosed = false
        window.center()

        for field in [workField, shortField, longField, everyField, retentionField] {
            field.alignment = .right
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 90).isActive = true
        }
        channelPopup.translatesAutoresizingMaskIntoConstraints = false
        for channel in NotifyChannel.allCases {
            channelPopup.addItem(withTitle: channel.displayName)
            channelPopup.lastItem?.representedObject = channel.rawValue
        }

        let grid = NSGridView(views: [
            [label("专注时长（分钟）"), workField],
            [label("短休息（分钟）"), shortField],
            [label("长休息（分钟）"), longField],
            [label("每几个番茄长休息"), everyField],
            [label("统计保留天数"), retentionField],
            [label("通知方式"), channelPopup],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false

        let retentionHint = NSTextField(wrappingLabelWithString: "统计保留天数：只保留最近这些天的记录，超出后自动覆盖最早的记录；填 0 表示不限。")
        retentionHint.font = NSFont.systemFont(ofSize: 11)
        retentionHint.textColor = .secondaryLabelColor
        retentionHint.preferredMaxLayoutWidth = 430

        let stack = NSStackView(views: [grid, retentionHint, onscreenBox, autoBreakBox, autoNextBox, soundBox])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        let saveButton = NSButton(title: "保存", target: self, action: #selector(save))
        saveButton.keyEquivalent = "\r"
        let cancelButton = NSButton(title: "取消", target: self, action: #selector(cancel))
        let notifButton = NSButton(title: "打开系统通知设置", target: self, action: #selector(openNotificationSettings))
        let buttons = NSStackView(views: [notifButton, cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        content.addSubview(buttons)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])
        window.contentView = content
        self.window = window
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.alignment = .right
        return field
    }

    private func load() {
        let settings = model.engine.state.settings
        workField.stringValue = Format.minutes(settings.workMinutes)
        shortField.stringValue = Format.minutes(settings.shortBreakMinutes)
        longField.stringValue = Format.minutes(settings.longBreakMinutes)
        everyField.stringValue = String(settings.longBreakEvery)
        retentionField.stringValue = String(settings.historyRetentionDays)
        autoBreakBox.state = settings.autoBreak ? .on : .off
        autoNextBox.state = settings.autoNextWork ? .on : .off
        soundBox.state = settings.sound ? .on : .off
        onscreenBox.state = settings.onscreen ? .on : .off
        if let index = NotifyChannel.allCases.firstIndex(of: settings.notifyChannel) {
            channelPopup.selectItem(at: index)
        }
    }

    @objc private func save() {
        var settings = model.engine.state.settings
        guard let work = Double(workField.stringValue.trimmingCharacters(in: .whitespaces)),
              let short = Double(shortField.stringValue.trimmingCharacters(in: .whitespaces)),
              let long = Double(longField.stringValue.trimmingCharacters(in: .whitespaces)),
              let every = Int(everyField.stringValue.trimmingCharacters(in: .whitespaces)),
              let retention = Int(retentionField.stringValue.trimmingCharacters(in: .whitespaces)),
              // isFinite matters: Double("inf") > 0 is true, and the value would then be
              // silently replaced by the default instead of being reported as invalid.
              work.isFinite, short.isFinite, long.isFinite,
              work > 0, short > 0, long > 0, every > 0, retention >= 0 else {
            let alert = NSAlert()
            alert.messageText = "设置无效"
            alert.informativeText = "时长需要是大于 0 的数字，长休息间隔需要是大于 0 的整数，统计保留天数需要是 0（不限）或更大的整数。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }
        settings.workMinutes = work
        settings.shortBreakMinutes = short
        settings.longBreakMinutes = long
        settings.longBreakEvery = every
        settings.historyRetentionDays = retention
        settings.autoBreak = autoBreakBox.state == .on
        settings.autoNextWork = autoNextBox.state == .on
        settings.sound = soundBox.state == .on
        settings.onscreen = onscreenBox.state == .on
        if let raw = channelPopup.selectedItem?.representedObject as? String,
           let channel = NotifyChannel(rawValue: raw) {
            settings.notifyChannel = channel
        }
        settings.sanitize()

        model.engine.state.settings = settings
        // Shortening the window takes effect immediately, not just on the next record.
        let pruned = model.engine.pruneHistory()
        model.commit()
        window?.close()

        if pruned > 0 {
            let alert = NSAlert()
            alert.messageText = "已按新的保留上限清理历史"
            alert.informativeText = "删除了 \(pruned) 天的旧记录。"
            alert.addButton(withTitle: "好")
            alert.runModal()
        }
    }

    @objc private func cancel() {
        window?.close()
    }

    @objc private func openNotificationSettings() {
        Notifier.openNotificationSettings()
    }
}
