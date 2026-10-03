// AppDelegate — wires the model, the menu bar item, and the wake/terminate hooks.

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var model: AppModel?
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Only one menu bar instance may run: a second copy (for example the build output
        // inside the project folder) would show a duplicate 🍅 and both copies would
        // write the same state file. This must happen *before* AppModel is constructed,
        // because its init can prune the history and rewrite state.json.
        let store = Store.default()
        if let other = store.runningGUIPid(), other != getpid() {
            refuseSecondInstance(runningPid: other)
            return
        }
        if let other = store.claimGUIPid(), other != getpid() {
            refuseSecondInstance(runningPid: other)
            return
        }

        let model = AppModel(store: store)
        self.model = model

        if let note = model.statusNote {
            NSLog("Pomodoro: %@", note)
        }

        let menuBar = MenuBarController(model: model)
        self.menuBar = menuBar
        menuBar.start()

        model.notifier.requestAuthorizationIfNeeded { granted in
            NSLog("Pomodoro: notification authorization = %@", granted ? "granted" : "not granted")
        }
        model.reconcile()
    }

    /// Explain the clash and quit without touching the running instance's state.
    private func refuseSecondInstance(runningPid: pid_t) {
        let message = "番茄钟已经在运行了（pid \(runningPid)，菜单栏里的 🍅）。\n"
            + "请直接从菜单栏图标操作；如果要重新启动，先在菜单里选「退出」。"
        FileHandle.standardError.write(Data((message + "\n").utf8))

        // A terminal launch already printed the reason; a double-click needs a dialog.
        // The dialog must never outlive anyone's attention: with no user there to click
        // it, `runModal` blocks forever and leaves a hung process holding an invisible
        // window (a script or launchd launch does exactly that).
        if isatty(STDIN_FILENO) == 0 {
            let alert = NSAlert()
            alert.messageText = "番茄钟已在运行"
            alert.informativeText = message
            alert.addButton(withTitle: "好")
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.refusalDialogTimeout) {
                alert.window.orderOut(nil)
                NSApp.stopModal()
            }
            alert.runModal()
        }
        // Exit directly: NSApp.terminate is swallowed during launch, and the
        // terminate path would try to clear the running instance's pid file.
        exit(0)
    }

    /// How long the "already running" dialog may stay up without being dismissed.
    static let refusalDialogTimeout: TimeInterval = 15

    func applicationWillTerminate(_ notification: Notification) {
        menuBar?.stop()
        model?.store.clearGUIPid()
    }
}
