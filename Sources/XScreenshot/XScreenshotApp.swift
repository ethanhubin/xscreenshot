import AppKit
import CoreGraphics
import ServiceManagement

@main
@MainActor
struct XScreenshotApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let hotKey = GlobalHotKey()
    private let selection = AreaSelection()
    private let launchService = SMAppService.mainApp
    private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let captureItem = NSMenuItem(title: "区域截图", action: #selector(beginSelection), keyEquivalent: "")
    private let launchItem = NSMenuItem(title: "登录时自动启动", action: nil, keyEquivalent: "")
    private let loginSettingsItem = NSMenuItem(title: "打开系统登录项…", action: #selector(openLoginSettings), keyEquivalent: "")
    private var isPreparing = false
    private var hasRequestedPermission = false
    private var displayGeneration = 0

    private var savedShortcut: Shortcut {
        Shortcut.restored(from: UserDefaults.standard.data(forKey: Shortcut.storageKey))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMenu()
        let shortcut = savedShortcut
        let status = registerShortcut(shortcut)
        if status != noErr {
            showAlert(
                title: "无法注册截图快捷键",
                message: "\(shortcut.displayName) 可能已被系统或其他应用占用。你可以从菜单栏更换快捷键。（\(status)）"
            )
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKey.unregister()
    }

    func applicationDidChangeScreenParameters(_ notification: Notification) {
        displayGeneration += 1
        selection.cancel()
    }

    private func configureMenu() {
        let menu = NSMenu()
        menu.delegate = self
        let shortcutItem = NSMenuItem(title: "设置截图快捷键…", action: #selector(editShortcut), keyEquivalent: "")
        for item in [captureItem, shortcutItem, launchItem, loginSettingsItem] {
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "退出 XScreenshot", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.target = NSApp
        menu.addItem(quitItem)

        statusItem.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "XScreenshot")
        statusItem.button?.setAccessibilityLabel("XScreenshot")
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        hotKey.beginMenuTracking(menu)
    }

    func menuDidClose(_ menu: NSMenu) {
        hotKey.endMenuTracking()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        captureItem.title = "区域截图  \(savedShortcut.displayName)"

        let status = launchService.status
        loginSettingsItem.isHidden = status != .requiresApproval
        launchItem.action = #selector(toggleLaunchAtLogin)
        switch status {
        case .enabled:
            launchItem.state = .on
            launchItem.title = "登录时自动启动（已开启）"
        // macOS can return .notFound before the first registration.
        case .notRegistered, .notFound:
            launchItem.state = .off
            launchItem.title = "登录时自动启动（已关闭）"
        case .requiresApproval:
            launchItem.state = .mixed
            launchItem.title = "登录时自动启动（待批准）"
        @unknown default:
            launchItem.state = .off
            launchItem.title = "登录时自动启动（不可用）"
            launchItem.action = nil
        }
    }

    @objc private func editShortcut() {
        guard !isPreparing, !selection.isActive, NSApp.modalWindow == nil else { return }
        guard let shortcut = ShortcutSettings.choose(current: savedShortcut),
              let data = try? JSONEncoder().encode(shortcut) else { return }
        let status = registerShortcut(shortcut)
        if status == noErr {
            UserDefaults.standard.set(data, forKey: Shortcut.storageKey)
        } else {
            showAlert(title: "无法使用该快捷键",
                      message: "\(shortcut.displayName) 可能已被系统或其他应用占用，请换一个组合键。（\(status)）")
        }
    }

    @objc private func toggleLaunchAtLogin() {
        guard !isPreparing, !selection.isActive, NSApp.modalWindow == nil else { return }

        let status = launchService.status
        let shouldRegister = status == .notRegistered || status == .notFound
        guard shouldRegister || status == .enabled || status == .requiresApproval else { return }

        do {
            if shouldRegister {
                try launchService.register()
            } else {
                try launchService.unregister()
            }
        } catch {
            guard shouldRegister, launchService.status == .requiresApproval else {
                showAlert(title: "无法更改自动启动设置", message: error.localizedDescription)
                return
            }
        }

        if shouldRegister, launchService.status == .requiresApproval {
            let approval = NSAlert()
            approval.messageText = "自动启动等待批准"
            approval.informativeText = "请在系统设置的「登录项」中允许 XScreenshot 自动启动。"
            approval.addButton(withTitle: "打开系统设置")
            approval.addButton(withTitle: "稍后").keyEquivalent = "\u{1b}"
            NSApp.activate()
            if approval.runModal() == .alertFirstButtonReturn {
                openLoginSettings()
            }
        }
    }

    @objc private func openLoginSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func registerShortcut(_ shortcut: Shortcut) -> OSStatus {
        hotKey.register(shortcut) { [weak self] in self?.beginSelection() }
    }

    @objc private func beginSelection() {
        guard !isPreparing, !selection.isActive, NSApp.modalWindow == nil else { return }
        guard hasScreenCapturePermission() else { return }
        isPreparing = true
        let generation = displayGeneration
        Task {
            defer { isPreparing = false }
            do {
                let snapshots = try await ScreenCapture.snapshots(for: AreaSelection.displaySizes())
                guard generation == displayGeneration else { return }
                selection.begin(snapshots: snapshots) { [weak self] snapshot, rect, markup in
                    self?.copy(snapshot: snapshot, rect: rect, markup: markup)
                }
            } catch {
                guard generation == displayGeneration else { return }
                if CGPreflightScreenCaptureAccess() {
                    showAlert(title: "截图失败", message: error.localizedDescription)
                } else {
                    showPermissionAlert()
                }
            }
        }
    }

    private func copy(snapshot: DisplaySnapshot, rect: CGRect, markup: [Markup]) {
        do {
            let image = try snapshot.export(region: rect, markup: markup)
            try ScreenCapture.copyToClipboard(image)
        } catch {
            showAlert(title: "无法复制截图", message: error.localizedDescription)
        }
    }

    private func hasScreenCapturePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if !hasRequestedPermission {
            hasRequestedPermission = true
            return CGRequestScreenCaptureAccess()
        }

        showPermissionAlert()
        return false
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "需要屏幕录制权限"
        alert.informativeText = "在系统设置的「隐私与安全性」中允许 XScreenshot 录制屏幕，然后退出并重新打开应用。"
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "取消")
        NSApp.activate()

        if alert.runModal() == .alertFirstButtonReturn,
           let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(settings)
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "好")
        NSApp.activate()
        alert.runModal()
    }
}
