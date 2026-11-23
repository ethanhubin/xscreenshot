import AppKit
import Carbon

struct Shortcut: Codable, Equatable {
    static let storageKey = "CaptureShortcut"
    static let standard = Shortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: UInt32(controlKey | shiftKey), key: "4")

    let keyCode: UInt32
    let modifiers: UInt32
    let key: String

    var displayName: String {
        let symbols = [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
        return symbols.filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + key
    }

    static func restored(from data: Data?) -> Shortcut {
        guard let data else { return .standard }
        return (try? JSONDecoder().decode(Self.self, from: data)) ?? .standard
    }

    static func recorded(from event: NSEvent) -> Self? {
        let flags = event.modifierFlags
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }

        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }

        let code = UInt32(event.keyCode)
        let specialKeys = [kVK_Space: "空格", kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥",
                           kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "Esc", kVK_LeftArrow: "←",
                           kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖",
                           kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟"]
        let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
        let name: String
        if let special = specialKeys[Int(code)] {
            name = special
        } else if let index = functionKeys.firstIndex(of: Int(code)) {
            name = "F\(index + 1)"
        } else if let characters = event.charactersIgnoringModifiers, !characters.isEmpty,
                  characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            name = characters.uppercased()
        } else {
            return nil
        }

        return Shortcut(keyCode: code, modifiers: modifiers, key: name)
    }
}

@MainActor
final class GlobalHotKey {
    private static let signature: OSType = 0x58534352 // XSCR
    private static let menuTrackingMode = CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString)
    private var handler: EventHandlerRef?
    private var hotKey: EventHotKeyRef?
    private var menuTrackingObserver: CFRunLoopObserver?
    private var activeShortcut: Shortcut?
    private var activeID: UInt32 = 0
    private var action: (() -> Void)?

    func register(_ shortcut: Shortcut, action: @escaping () -> Void) -> OSStatus {
        if let activeShortcut, activeShortcut.keyCode == shortcut.keyCode,
           activeShortcut.modifiers == shortcut.modifiers {
            self.action = action
            return noErr
        }

        let target = GetApplicationEventTarget()
        if handler == nil {
            var kind = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(target, { _, event, context in
                MainActor.assumeIsolated {
                    guard let event, let context else { return OSStatus(eventNotHandledErr) }
                    return Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue().handle(event)
                }
            }, 1, &kind, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { return status }
        }

        let id = activeID &+ 1
        var replacement: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers,
                                         EventHotKeyID(signature: Self.signature, id: id), target,
                                         OptionBits(kEventHotKeyExclusive), &replacement)
        guard status == noErr else { return status }

        if let hotKey { UnregisterEventHotKey(hotKey) }
        activeID = id
        activeShortcut = shortcut
        hotKey = replacement
        self.action = action
        return noErr
    }

    func unregister() {
        endMenuTracking()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        activeShortcut = nil
        action = nil
    }

    func beginMenuTracking(onPress: @escaping @MainActor () -> Void) {
        guard hotKey != nil, menuTrackingObserver == nil else { return }
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeSources.rawValue, true, 0) { [weak self] _, _ in
            MainActor.assumeIsolated {
                // Consume the press here so AppKit does not deliver it again after tracking.
                guard self?.consumePendingPress() == true else { return }
                onPress()
            }
        }
        menuTrackingObserver = observer
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, Self.menuTrackingMode)
    }

    func endMenuTracking() {
        guard let menuTrackingObserver else { return }
        CFRunLoopRemoveObserver(CFRunLoopGetMain(), menuTrackingObserver, Self.menuTrackingMode)
        self.menuTrackingObserver = nil
    }

    private func consumePendingPress() -> Bool {
        let queue = GetMainEventQueue()
        let event = FindSpecificEventInQueue(queue, { event, context in
            MainActor.assumeIsolated {
                guard let event, let context else { return DarwinBoolean(false) }
                let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
                return DarwinBoolean(hotKey.isActivePress(event))
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        guard let event else { return false }
        return RemoveEventFromQueue(queue, event) == noErr
    }

    private func isActivePress(_ event: EventRef) -> Bool {
        guard GetEventClass(event) == OSType(kEventClassKeyboard),
              GetEventKind(event) == UInt32(kEventHotKeyPressed) else { return false }
        var id = EventHotKeyID()
        let status = GetEventParameter(event, OSType(kEventParamDirectObject), OSType(typeEventHotKeyID),
                                       nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
        return status == noErr && id.signature == Self.signature && id.id == activeID
    }

    private func handle(_ event: EventRef) -> OSStatus {
        guard isActivePress(event) else { return OSStatus(eventNotHandledErr) }
        action?()
        return noErr
    }
}
