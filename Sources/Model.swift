// AppModel — shared state owner for the menu bar UI: persistence, notifications,
// and the one-second deadline check.

import Foundation

final class AppModel {
    let store: Store
    let notifier: Notifier
    var engine: Engine
    /// Remark from loading (corruption, repairs, pruning). Kept until the app restarts.
    private var loadNote: String?
    /// Last failed write. Cleared by the next successful one.
    private var saveError: String?

    /// Everything worth showing in the menu: the load remark plus any current write error.
    /// Keeping them apart means a later successful save cannot erase the warning that the
    /// state file was damaged or repaired.
    var statusNote: String? {
        let parts = [loadNote, saveError].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: "；")
    }

    private var observers: [UUID: () -> Void] = [:]

    init(store: Store = .default(), notifier: Notifier = Notifier()) {
        self.store = store
        self.notifier = notifier
        let loaded = store.load()
        self.engine = Engine(state: loaded.state)
        var notes: [String] = []
        if let note = loaded.note { notes.append(note) }
        // Repair impossible values a hand-edited or salvaged file could carry before
        // anything acts on them.
        if self.engine.sanitizeLoadedState() {
            notes.append("已修正状态文件中的异常数值")
        }
        // Trim an over-long history left by an earlier, larger retention window.
        let pruned = self.engine.pruneHistory()
        if pruned > 0 {
            notes.append("已按保留上限清理 \(pruned) 天的旧记录")
        }
        if self.engine.state != loaded.state { persist() }
        self.loadNote = notes.isEmpty ? nil : notes.joined(separator: "；")
    }

    // MARK: Change notification

    /// Register a refresh callback (menu bar, stats window, settings window).
    @discardableResult
    func observe(_ block: @escaping () -> Void) -> UUID {
        let id = UUID()
        observers[id] = block
        return id
    }

    func unobserve(_ id: UUID) {
        observers.removeValue(forKey: id)
    }

    private func notifyObservers() {
        for block in observers.values { block() }
    }

    /// Persist the current state and refresh every observer.
    func commit() {
        persist()
        notifyObservers()
    }

    var channel: NotifyChannel { engine.state.settings.notifyChannel }

    func persist() {
        if let error = store.save(engine.state) {
            saveError = error
        } else {
            // A transient write failure must not leave a permanent warning; the load
            // remark, if any, is preserved because it is still true.
            saveError = nil
        }
    }

    /// Run one engine mutation, deliver its notifications, persist, and refresh.
    func mutate(_ body: (inout Engine) -> [EngineEvent]) {
        let events = body(&engine)
        deliver(events)
        commit()
    }

    func deliver(_ events: [EngineEvent]) {
        for event in events {
            guard let note = event.notification else { continue }
            // The on-screen card needs no permission, so it always reflects the
            // phase change; banners and sound follow the user's settings.
            if engine.state.settings.onscreen {
                ReminderPanel.show(title: note.title, body: note.body)
            }
            _ = notifier.post(
                title: note.title,
                body: note.body,
                channel: channel,
                sound: engine.state.settings.sound
            )
        }
    }

    /// Resolve a phase left over from a previous run, announcing what happened.
    /// - Parameter announceResumed: false for a wake-up, where nothing actually changed
    ///   and a "番茄钟已恢复" banner every time the lid opens is pure noise.
    func reconcile(announceResumed: Bool = true) {
        let before = engine.state
        let events = engine.reconcile()
        for event in events {
            switch event {
            case .phaseResumed(let phase, let remaining):
                guard announceResumed else { break }
                // A paused phase is not "resumed": say what actually happened.
                let body = phase.isPaused
                    ? "已暂停，剩余 \(Format.clock(remaining))"
                    : "剩余 \(Format.clock(remaining))"
                if engine.state.settings.onscreen {
                    ReminderPanel.show(title: "番茄钟已恢复", body: body)
                }
                _ = notifier.post(
                    title: "番茄钟已恢复",
                    body: body,
                    channel: channel,
                    sound: false
                )
            case .phaseEndedWhileAway:
                if engine.state.settings.onscreen {
                    ReminderPanel.show(title: "番茄钟已结束", body: "应用未运行期间，该阶段已结束。")
                }
                _ = notifier.post(
                    title: "番茄钟已结束",
                    body: "应用未运行期间，该阶段已结束。",
                    channel: channel,
                    sound: engine.state.settings.sound
                )
            default:
                break
            }
        }
        // Only touch the disk when reconciling actually changed something.
        if engine.state != before { commit() }
    }

    /// Advance a deadline that has passed. Called every second and after wake.
    func tick() {
        let events = engine.tick()
        guard !events.isEmpty else { return }
        deliver(events)
        commit()
    }
}
