import AppKit

@MainActor
enum ShortcutSettings {
    static func choose(current: Shortcut) -> Shortcut? {
        let alert = NSAlert()
        alert.messageText = "截图快捷键"
        alert.informativeText = "按下新的组合键，至少包含 ⌘、⌃ 或 ⌥ 中的一项。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        alert.addButton(withTitle: "恢复默认")

        let label = NSTextField(labelWithString: current.displayName)
        label.font = .monospacedSystemFont(ofSize: 22, weight: .medium)
        label.alignment = .center
        label.frame = NSRect(x: 0, y: 0, width: 260, height: 30)
        alert.accessoryView = label

        var candidate = current
        let window = alert.window
        let monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === window else { return event }
            let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
            if flags.isEmpty, ["\r", "\u{1b}", "\t"].contains(event.charactersIgnoringModifiers ?? "") {
                return event
            }
            if let shortcut = Shortcut.recorded(from: event) {
                candidate = shortcut
                label.stringValue = shortcut.displayName
                label.textColor = .labelColor
                alert.buttons[0].isEnabled = true
            } else {
                label.stringValue = "请按组合键"
                label.textColor = .secondaryLabelColor
                alert.buttons[0].isEnabled = false
            }
            return nil
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }

        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: return candidate
        case .alertThirdButtonReturn: return .standard
        default: return nil
        }
    }
}
