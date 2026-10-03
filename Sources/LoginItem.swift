// LoginItem — "start at login" through SMAppService, with a LaunchAgent fallback.
// The fallback matters because an ad-hoc signed bundle may be refused by SMAppService.

import Foundation
import ServiceManagement

enum LoginItem {
    static let agentLabel = "local.pomodoro"

    static var agentPlistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(agentLabel).plist")
    }

    static func isEnabled() -> Bool {
        if #available(macOS 13.0, *), SMAppService.mainApp.status == .enabled {
            return true
        }
        return FileManager.default.fileExists(atPath: agentPlistURL.path)
    }

    /// Enable or disable login start. Returns nil on success, or an error description.
    static func setEnabled(_ enabled: Bool) -> String? {
        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    if SMAppService.mainApp.status != .enabled {
                        try SMAppService.mainApp.register()
                    }
                } else if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
                if enabled == (SMAppService.mainApp.status == .enabled) {
                    // Disabling must still tear down the LaunchAgent fallback: SMAppService
                    // knows nothing about it, so returning here would leave a loaded agent
                    // running for the rest of the session.
                    if !enabled { return setAgentEnabled(false) }
                    return nil
                }
            } catch {
                // Fall through to the LaunchAgent path.
            }
        }
        return setAgentEnabled(enabled)
    }

    private static func setAgentEnabled(_ enabled: Bool) -> String? {
        let url = agentPlistURL
        if enabled {
            guard let executable = Bundle.main.executablePath else {
                return "无法定位可执行文件路径"
            }
            let plist: [String: Any] = [
                "Label": agentLabel,
                "ProgramArguments": [executable],
                "RunAtLoad": true,
                "KeepAlive": false,
            ]
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
                try data.write(to: url, options: .atomic)
            } catch {
                return "写入登录项失败：\(error.localizedDescription)"
            }
            let result = Notifier.runProcess(
                "/bin/launchctl",
                arguments: ["bootstrap", "gui/\(getuid())", url.path],
                timeout: 5
            )
            // Report the real outcome instead of claiming success for a failed load.
            guard result.code == 0 else {
                let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                try? FileManager.default.removeItem(at: url)
                return "launchctl bootstrap 失败\(detail.isEmpty ? "（退出码 \(result.code)）" : "：\(detail)")"
            }
            return nil
        }
        let result = Notifier.runProcess(
            "/bin/launchctl",
            arguments: ["bootout", "gui/\(getuid())/\(agentLabel)"],
            timeout: 5
        )
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            return "移除登录项失败：\(error.localizedDescription)"
        }
        // A bootout failure is only worth reporting when the agent was actually loaded.
        if result.code != 0, !result.timedOut {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if detail.contains("Could not find service") || detail.contains("No such process") {
                return nil
            }
            return "launchctl bootout 失败\(detail.isEmpty ? "（退出码 \(result.code)）" : "：\(detail)")"
        }
        return nil
    }
}
