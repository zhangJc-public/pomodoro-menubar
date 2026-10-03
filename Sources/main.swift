// Pomodoro — a standalone macOS menu bar pomodoro timer.
//
// No arguments      -> menu bar application.
// --selftest        -> headless engine/format/persistence checks.
// --notify-test     -> post one test notification and report the channel used.
// --status          -> print the persisted status without a UI.
// --once <minutes>  -> run one work phase headlessly, then notify and exit.
// --stats [days]    -> print the recent-days report.
// --help / --version

import AppKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())

// Anything the CLI recognises runs headlessly; otherwise the menu bar app starts.
if let mode = CLI.parse(arguments) {
    exit(CLI.run(mode))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
