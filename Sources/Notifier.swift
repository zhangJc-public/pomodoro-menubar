// Notifier — macOS banners with a script fallback and a guaranteed sound cue.
//
// Channel order: the native UserNotifications banner when authorized, otherwise
// /usr/bin/osascript (no shell involved). Whenever sound is enabled the Glass
// system sound also plays, so a phase change is always perceptible even when
// banners are suppressed by Focus mode or notification settings.

import AppKit
import UserNotifications

struct NotifyResult {
    let channel: String
    let ok: Bool
    let detail: String

    var summary: String {
        "\(ok ? "成功" : "失败") · 通道 \(channel)\(detail.isEmpty ? "" : " · \(detail)")"
    }
}

final class Notifier {
    private let bundled: Bool

    init() {
        bundled = Bundle.main.bundleIdentifier != nil
    }

    // MARK: Authorization

    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        guard bundled else {
            completion(false)
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            completion(granted)
        }
    }

    /// Ask only when the user has not answered yet; re-asking on every launch
    /// produces a spurious error once a decision has been recorded.
    func requestAuthorizationIfNeeded(completion: @escaping (Bool) -> Void) {
        guard bundled else {
            completion(false)
            return
        }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                self.requestAuthorization(completion: completion)
            case .authorized, .provisional, .ephemeral:
                completion(true)
            default:
                completion(false)
            }
        }
    }

    /// Blocking read of the current authorization status, for headless commands.
    func authorizationStatus() -> UNAuthorizationStatus {
        guard bundled else { return .denied }
        let semaphore = DispatchSemaphore(value: 0)
        var status: UNAuthorizationStatus = .notDetermined
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            status = settings.authorizationStatus
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 3)
        return status
    }

    /// Deep link into System Settings › Notifications.
    static func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: Posting

    func post(title: String, body: String, channel: NotifyChannel, sound: Bool) -> NotifyResult {
        // Exactly one cue per event. The system sound is the guaranteed one — it plays
        // even when banners are suppressed by Focus — so the notification/script itself
        // must not also ring, which used to produce two overlapping sounds.
        if sound { playSound() }
        switch channel {
        case .soundOnly:
            return NotifyResult(channel: "声音", ok: true, detail: sound ? "已播放 Glass" : "声音已关闭")
        case .script:
            return postViaScript(title: title, body: body, sound: false)
        case .native:
            return postNative(title: title, body: body, sound: false)
        case .auto:
            let status = authorizationStatus()
            if status == .authorized || status == .provisional {
                let native = postNative(title: title, body: body, sound: false)
                if native.ok { return native }
                let script = postViaScript(title: title, body: body, sound: false)
                return NotifyResult(
                    channel: "原生→脚本",
                    ok: script.ok,
                    detail: "原生失败：\(native.detail)；脚本：\(script.detail)"
                )
            }
            let script = postViaScript(title: title, body: body, sound: false)
            return NotifyResult(
                channel: "脚本",
                ok: script.ok,
                detail: "原生授权状态 \(Self.describe(status))\(script.detail.isEmpty ? "" : "；\(script.detail)")"
            )
        }
    }

    static func describe(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized: return "已授权"
        case .denied: return "已拒绝"
        case .notDetermined: return "未询问"
        case .provisional: return "临时授权"
        case .ephemeral: return "临时会话"
        @unknown default: return "未知"
        }
    }

    private func postNative(title: String, body: String, sound: Bool) -> NotifyResult {
        guard bundled else {
            return NotifyResult(channel: "原生", ok: false, detail: "不在 App bundle 内运行")
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if sound { content.sound = .default }
        let request = UNNotificationRequest(
            identifier: "pomodoro-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        let semaphore = DispatchSemaphore(value: 0)
        var failure: String?
        UNUserNotificationCenter.current().add(request) { error in
            failure = error?.localizedDescription
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 5) == .timedOut {
            return NotifyResult(channel: "原生", ok: false, detail: "提交超时")
        }
        if let failure { return NotifyResult(channel: "原生", ok: false, detail: failure) }
        return NotifyResult(channel: "原生", ok: true, detail: "")
    }

    private func postViaScript(title: String, body: String, sound: Bool) -> NotifyResult {
        let script = Format.notificationScript(title: title, body: body, sound: sound)
        let result = Self.runProcess(
            "/usr/bin/osascript",
            arguments: ["-e", script],
            timeout: 5
        )
        if result.timedOut {
            return NotifyResult(channel: "脚本", ok: false, detail: "osascript 超时")
        }
        if result.code == 0 {
            return NotifyResult(channel: "脚本", ok: true, detail: "")
        }
        let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return NotifyResult(channel: "脚本", ok: false, detail: detail.isEmpty ? "退出码 \(result.code)" : detail)
    }

    func playSound() {
        guard let sound = NSSound(named: NSSound.Name("Glass")) else { return }
        sound.play()
    }

    // MARK: Process helper

    struct ProcessResult {
        let code: Int32
        let stderr: String
        let timedOut: Bool
    }

    /// Run one executable without a shell and collect its exit status.
    static func runProcess(_ path: String, arguments: [String], timeout: TimeInterval) -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        // Collect stderr in a file rather than a pipe. A pipe nobody drains blocks the
        // child once its 64KB buffer fills, which used to surface as a bogus timeout and
        // then got the healthy child SIGKILLed. A file has no such limit, so it needs
        // neither a drain thread nor EOF bookkeeping — and closing our end can never
        // strand the reader.
        let errorURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pomodoro-stderr-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: errorURL.path, contents: nil),
              let errorHandle = try? FileHandle(forWritingTo: errorURL) else {
            return ProcessResult(code: -1, stderr: "无法创建临时文件", timedOut: false)
        }
        process.standardError = errorHandle
        // `Process` keeps the FileHandle it was given, so it must be closed explicitly or
        // every spawn leaks a descriptor for good.
        defer {
            try? errorHandle.close()
            try? FileManager.default.removeItem(at: errorURL)
        }
        do {
            try process.run()
        } catch {
            return ProcessResult(code: -1, stderr: error.localizedDescription, timedOut: false)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
        if process.isRunning {
            process.terminate()
            // SIGTERM only. Give the child a moment, then make sure it is gone: a child
            // that ignores SIGTERM must not be left running behind the app.
            let grace = Date().addingTimeInterval(0.25)
            while process.isRunning && Date() < grace {
                usleep(20_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            return ProcessResult(code: -1, stderr: "超时", timedOut: true)
        }
        // The child has exited, so everything it wrote is already visible on disk.
        let errorData = (try? Data(contentsOf: errorURL)) ?? Data()
        let stderr = String(data: errorData, encoding: .utf8) ?? ""
        return ProcessResult(code: process.terminationStatus, stderr: stderr, timedOut: false)
    }
}
