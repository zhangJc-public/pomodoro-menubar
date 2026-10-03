// ReminderPanel — a transient floating card in the top-right corner.
//
// System notification banners need a validated code signature and a granted
// authorization; this card needs neither, so a phase change is always visible.

import AppKit

final class ReminderPanel {
    private static var current: ReminderPanel?

    private let panel: NSPanel
    private var closeTimer: Timer?
    private var onDismiss: (() -> Void)?

    /// Show a card, replacing any card already on screen.
    static func show(title: String, body: String, seconds: TimeInterval = 8) {
        current?.dismiss()
        let instance = ReminderPanel(title: title, body: body, seconds: seconds)
        current = instance
        instance.present()
    }

    private init(title: String, body: String, seconds: TimeInterval) {
        let width: CGFloat = 340
        let height: CGFloat = 92

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.alphaValue = 0
        self.panel = panel

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.masksToBounds = true

        let emoji = NSTextField(labelWithString: "🍅")
        emoji.font = NSFont.systemFont(ofSize: 26)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.boldSystemFont(ofSize: 14)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail

        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.font = NSFont.systemFont(ofSize: 12)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.preferredMaxLayoutWidth = width - 96

        let text = NSStackView(views: [titleLabel, bodyLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3

        let row = NSStackView(views: [emoji, text])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        row.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)

        effect.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            row.topAnchor.constraint(equalTo: effect.topAnchor),
            row.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        // Clicking the card dismisses it immediately.
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        effect.addGestureRecognizer(click)

        panel.contentView = effect

        // Place it under the menu bar in the top-right corner of the active screen.
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: width, height: height)
        panel.setFrameOrigin(NSPoint(x: screen.maxX - width - 16, y: screen.maxY - height - 12))

        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            self?.dismiss()
        }
        RunLoop.main.add(timer, forMode: .common)
        closeTimer = timer
    }

    private func present() {
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    @objc private func handleClick() {
        dismiss()
    }

    func dismiss() {
        closeTimer?.invalidate()
        closeTimer = nil
        guard panel.isVisible else {
            if ReminderPanel.current === self { ReminderPanel.current = nil }
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            self?.panel.orderOut(nil)
        })
        if ReminderPanel.current === self { ReminderPanel.current = nil }
    }
}
