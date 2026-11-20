import AppKit

@MainActor
final class AreaSelection {
    private var panels: [SelectionPanel] = []

    var isActive: Bool { !panels.isEmpty }

    static func displaySizes() -> [CGDirectDisplayID: CGSize] {
        var sizes: [CGDirectDisplayID: CGSize] = [:]
        for screen in NSScreen.screens {
            if let id = screen.captureDisplayID { sizes[id] = screen.frame.size }
        }
        return sizes
    }

    func begin(snapshots: [CGDirectDisplayID: DisplaySnapshot],
               onConfirm: @escaping (DisplaySnapshot, CGRect, [Markup]) -> Void) {
        for screen in NSScreen.screens {
            guard let id = screen.captureDisplayID, let snapshot = snapshots[id] else { continue }
            let panel = SelectionPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                                       backing: .buffered, defer: false)
            panel.setFrame(screen.frame, display: false)
            panel.level = .screenSaver
            panel.backgroundColor = .black
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

            let view = SelectionView(snapshot: snapshot)
            view.onCancel = { [weak self] in self?.cancel() }
            view.onRegionSelected = { [weak self, weak panel] in
                for other in self?.panels ?? [] where other !== panel {
                    other.allowsEditing = false
                    (other.contentView as? SelectionView)?.allowsEditing = false
                }
            }
            view.onConfirm = { [weak self] region, markup in
                self?.cancel()
                onConfirm(snapshot, region, markup)
            }
            panel.contentView = view
            panel.makeFirstResponder(view)
            panels.append(panel)
            panel.orderFrontRegardless()
        }

        let pointer = NSEvent.mouseLocation
        let panel = panels.first { $0.frame.contains(pointer) } ?? panels.first
        panel?.makeKeyAndOrderFront(nil)
    }

    func cancel() {
        panels.forEach { $0.orderOut(nil) }
        panels.removeAll()
    }
}

private extension NSScreen {
    var captureDisplayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }
}

private final class SelectionPanel: NSPanel {
    var allowsEditing = true
    override var canBecomeKey: Bool { allowsEditing }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}
