// Store — the JSON state file under ~/Library/Application Support/Pomodoro.
// Foundation only: the CLI reads and writes the same file the menu bar app uses.

import AppKit
import Foundation

struct Store {
    let directory: URL

    var stateURL: URL { directory.appendingPathComponent("state.json") }
    var pidURL: URL { directory.appendingPathComponent("gui.pid") }

    static func `default`() -> Store {
        // POMODORO_HOME overrides the data directory (handy for tests or a portable setup).
        if let override = ProcessInfo.processInfo.environment["POMODORO_HOME"], !override.isEmpty {
            return Store(directory: URL(fileURLWithPath: override, isDirectory: true))
        }
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return Store(directory: base.appendingPathComponent("Pomodoro", isDirectory: true))
    }

    init(directory: URL) {
        self.directory = directory
    }

    // MARK: Coders

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Store.fractional.string(from: date))
        }
        return encoder
    }

    static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            if let date = Store.fractional.date(from: text) { return date }
            if let date = Store.plain.date(from: text) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "无法解析时间：\(text)")
        }
        return decoder
    }

    // MARK: Load / save

    /// Load the persisted state. A file that cannot be decoded is moved aside *first*, so
    /// nothing can silently overwrite it, and whatever is still readable is salvaged.
    func load() -> (state: PomodoroState, note: String?) {
        guard FileManager.default.fileExists(atPath: stateURL.path) else {
            return (PomodoroState(), nil)
        }
        do {
            let data = try Data(contentsOf: stateURL)
            let state = try Store.makeDecoder().decode(PomodoroState.self, from: data)
            return (state, nil)
        } catch {
            let raw = (try? Data(contentsOf: stateURL)) ?? Data()
            guard let backup = moveAsideStateFile() else {
                return (PomodoroState(), "状态文件无法解析，且备份失败（\(error.localizedDescription)）；原文件已保留在 \(stateURL.lastPathComponent)。")
            }
            let salvaged = PomodoroState.salvaging(raw)
            let recovered = salvaged.map { "已尽力恢复可读部分（保留 \($0.history.count) 天记录）。" } ?? ""
            return (
                salvaged ?? PomodoroState(),
                "状态文件损坏，原文件已备份为 \(backup.lastPathComponent)。\(recovered)原因：\(error.localizedDescription)"
            )
        }
    }

    /// Move the state file to a unique backup name, or return nil when the move failed.
    /// A counter is added when two backups land inside the same second, so the second
    /// corruption is never lost and the note never names a file that was not written.
    private func moveAsideStateFile() -> URL? {
        let stamp = Int(Date().timeIntervalSince1970)
        var candidate = directory.appendingPathComponent("state.json.bak-\(stamp)")
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("state.json.bak-\(stamp)-\(counter)")
            counter += 1
        }
        do {
            try FileManager.default.moveItem(at: stateURL, to: candidate)
            return candidate
        } catch {
            return nil
        }
    }

    /// Durably write the state. Returns an error description instead of throwing.
    @discardableResult
    func save(_ state: PomodoroState) -> String? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Store.makeEncoder().encode(state)
            try data.write(to: stateURL, options: .atomic)
            return nil
        } catch {
            return "无法写入状态文件：\(error.localizedDescription)"
        }
    }

    // MARK: Menu bar instance guard

    /// Atomically claim the pid file. Returns the pid of the instance that already owns
    /// it, or nil when this process became the owner. Creating the file with O_EXCL
    /// closes the race that a read-then-write guard leaves open.
    func claimGUIPid() -> pid_t? {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for attempt in 0..<2 {
            let fd = open(pidURL.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd >= 0 {
                let bytes = Array("\(getpid())\n".utf8)
                _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, bytes.count) }
                close(fd)
                return nil
            }
            guard errno == EEXIST else { return nil }  // cannot create: run without the guard
            if let other = runningGUIPid(), other != getpid() { return other }
            // The file exists but names no live Pomodoro instance: it is stale.
            if attempt == 0 { try? FileManager.default.removeItem(at: pidURL) }
        }
        return nil
    }

    /// Record this process as the menu bar instance.
    func writeGUIPid() {
        _ = claimGUIPid()
    }

    /// Remove the pid file, but only when it belongs to this process. A second
    /// instance that refused to start must not clear the running one's marker.
    func clearGUIPid() {
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            try? FileManager.default.removeItem(at: pidURL)
            return
        }
        guard pid == getpid() else { return }
        try? FileManager.default.removeItem(at: pidURL)
    }

    /// PID of a live menu bar instance, or nil when none is running.
    /// A recycled pid must not lock the app out, so the process is confirmed to actually
    /// be this app before it counts. Identification is by bundle identifier, which also
    /// catches a renamed or relocated copy of the app — matching a literal
    /// "Pomodoro.app/Contents/MacOS/" path would miss `Pomodoro 2.app` and let a second
    /// instance start. When the bundle id cannot be read, the executable path decides.
    func runningGUIPid() -> pid_t? {
        guard let text = try? String(contentsOf: pidURL, encoding: .utf8),
              let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return nil }
        if pid == getpid() { return pid }
        guard kill(pid, 0) == 0 || errno == EPERM else { return nil }
        if let identity = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
            return identity == Bundle.main.bundleIdentifier ? pid : nil
        }
        guard let path = Store.executablePath(of: pid) else { return pid }
        return path.contains(".app/Contents/MacOS/") ? pid : nil
    }

    /// Executable path of a running process, or nil when it cannot be determined.
    static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
