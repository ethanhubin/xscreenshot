import AppKit
import CoreGraphics
import ServiceManagement
import SwiftUI

@main
struct XScreenshotApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @AppStorage(Shortcut.storageKey) private var shortcutData = Data()

    var body: some Scene {
        MenuBarExtra("XScreenshot", systemImage: "viewfinder") {
            Button("区域截图  \(Shortcut.restored(from: shortcutData).displayName)") {
                appDelegate.beginSelection()
            }
            Button("设置截图快捷键…") {
                appDelegate.editShortcut()
            }
            Button("设置自动启动…") {
                appDelegate.editLaunchAtLogin()
            }
            Divider()
            Button("退出 XScreenshot") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let hotKey = GlobalHotKey()
    private let selection = AreaSelection()
    private var isPreparing = false
    private var hasRequestedPermission = false
    private var displayGeneration = 0

    private var savedShortcut: Shortcut {
        Shortcut.restored(from: UserDefaults.standard.data(forKey: Shortcut.storageKey))
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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

    func editShortcut() {
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

    func editLaunchAtLogin() {
        guard !isPreparing, !selection.isActive, NSApp.modalWindow == nil else { return }

        let service = SMAppService.mainApp
        let status = service.status
        let isRegistered = status == .enabled || status == .requiresApproval
        let approvalMessage = "请在系统设置的「登录项」中允许 XScreenshot 自动启动。"
        let checkbox = NSButton(checkboxWithTitle: "登录 macOS 后自动打开 XScreenshot", target: nil, action: nil)
        checkbox.state = isRegistered ? .on : .off
        checkbox.sizeToFit()

        let alert = NSAlert()
        alert.messageText = "随系统自动启动"
        alert.accessoryView = checkbox
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消").keyEquivalent = "\u{1b}"
        if status == .requiresApproval {
            alert.informativeText = approvalMessage
            alert.addButton(withTitle: "打开系统设置")
        }

        NSApp.activate()
        let response = alert.runModal()
        if response == .alertThirdButtonReturn {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        let shouldRegister = checkbox.state == .on
        guard response == .alertFirstButtonReturn, shouldRegister != isRegistered else { return }

        do {
            if shouldRegister {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            guard shouldRegister, service.status == .requiresApproval else {
                showAlert(title: "无法更改自动启动设置", message: error.localizedDescription)
                return
            }
        }

        if shouldRegister, service.status == .requiresApproval {
            let approval = NSAlert()
            approval.messageText = "自动启动等待批准"
            approval.informativeText = approvalMessage
            approval.addButton(withTitle: "打开系统设置")
            approval.addButton(withTitle: "稍后").keyEquivalent = "\u{1b}"
            if approval.runModal() == .alertFirstButtonReturn {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }

    private func registerShortcut(_ shortcut: Shortcut) -> OSStatus {
        hotKey.register(shortcut) { [weak self] in self?.beginSelection() }
    }

    func beginSelection() {
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
