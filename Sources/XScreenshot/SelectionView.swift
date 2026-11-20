import AppKit

@MainActor
final class SelectionView: NSView, NSTextFieldDelegate {
    var onRegionSelected: (() -> Void)?
    var onCancel: (() -> Void)?
    var onConfirm: ((CGRect, [Markup]) -> Void)?
    var allowsEditing = true

    private enum Drag {
        case select(CGPoint)
        case move(CGPoint, CGRect)
        case resize(CGPoint, CGRect, ResizeHandle)
        case draw
    }

    private enum Edit {
        case region(CGRect)
        case markup
    }

    private struct TextInput {
        let field: NSTextField
        let origin: CGPoint
        let color: MarkupColor
    }

    private let image: NSImage
    private let toolbar = EditorToolbar()
    private var region = CGRect.zero
    private var isEditing = false
    private var tool = EditorTool.select
    private var color = MarkupColor.red
    private var drag: Drag?
    private var markup: [Markup] = []
    private var draft: Markup?
    private var history: [Edit] = []
    private var textInput: TextInput?

    init(snapshot: DisplaySnapshot) {
        image = NSImage(cgImage: snapshot.image, size: snapshot.size)
        super.init(frame: CGRect(origin: .zero, size: snapshot.size))
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved, .cursorUpdate],
                                       owner: self, userInfo: nil))
        addSubview(toolbar)
        toolbar.isHidden = true
        toolbar.onTool = { [weak self] in self?.chooseTool($0) }
        toolbar.onColor = { [weak self] in self?.chooseColor($0) }
        toolbar.onUndo = { [weak self] in self?.undo() }
        toolbar.onCancel = { [weak self] in self?.onCancel?() }
        toolbar.onConfirm = { [weak self] in self?.confirm() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // Matches the image crop and markup coordinate system.
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard allowsEditing else { return }
        window?.makeKey()
        finishText()
        window?.makeFirstResponder(self)
        let point = bounds.clamping(convert(event.locationInWindow, from: nil))

        if !isEditing {
            drag = .select(point)
        } else if let handle = resizeHandle(at: point) {
            drag = .resize(point, region, handle)
        } else if region.contains(point) {
            switch tool {
            case .select:
                drag = .move(point, region)
            case .text:
                beginText(at: point)
            default:
                drag = .draw
                draft = Markup(tool: tool, color: color, points: [point, point])
            }
        }
        refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        guard drag != nil else { return }
        updateDrag(at: convert(event.locationInWindow, from: nil))
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        updateDrag(at: convert(event.locationInWindow, from: nil))
        self.drag = nil
        switch drag {
        case .select:
            if region.width >= 2, region.height >= 2 {
                isEditing = true
                onRegionSelected?()
            } else {
                region = .zero
            }
        case let .move(_, previous), let .resize(_, previous, _):
            if region != previous { history.append(.region(previous)) }
        case .draw:
            if let draft, let first = draft.points.first,
               draft.points.contains(where: { hypot($0.x - first.x, $0.y - first.y) >= 1 }) {
                addMarkup(draft)
            }
            draft = nil
        }
        refresh()
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "\u{1B}": onCancel?()
        case "\r", "\u{3}": confirm()
        case "z" where event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.shift): undo()
        default: super.keyDown(with: event)
        }
    }

    override func mouseMoved(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)

        let shade = NSBezierPath(rect: bounds)
        shade.windingRule = .evenOdd
        if !region.isEmpty { shade.appendRect(region) }
        NSColor.black.withAlphaComponent(0.48).setFill()
        shade.fill()

        guard !region.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.clip(to: region)
        for annotation in markup { annotation.draw(in: context) }
        draft?.draw(in: context)
        context.restoreGState()

        NSColor.black.withAlphaComponent(0.65).setStroke()
        NSBezierPath.stroke(region.insetBy(dx: -1, dy: -1))
        NSColor.white.setStroke()
        NSBezierPath.stroke(region)
        if isEditing, tool == .select {
            for handle in ResizeHandle.all {
                let dot = NSBezierPath(roundedRect: handleRect(at: handle.point(in: region), size: 7),
                                       xRadius: 2, yRadius: 2)
                NSColor.white.setFill()
                dot.fill()
                NSColor.black.withAlphaComponent(0.55).setStroke()
                dot.stroke()
            }
        }
    }

    private func chooseTool(_ tool: EditorTool) {
        finishText()
        self.tool = tool
        window?.makeFirstResponder(self)
        refresh()
    }

    private func chooseColor(_ color: MarkupColor) {
        self.color = color
        if let textInput {
            textInput.field.textColor = color.color
            textInput.field.backgroundColor = color == .black ? .white : .black
            (textInput.field.currentEditor() as? NSTextView)?.textColor = color.color
            self.textInput = TextInput(field: textInput.field, origin: textInput.origin, color: color)
        } else {
            window?.makeFirstResponder(self)
        }
        refresh()
    }

    private func updateDrag(at point: CGPoint) {
        switch drag {
        case let .select(start):
            region = CGRect.spanning(start, bounds.clamping(point))
        case let .move(start, previous):
            region = previous.moved(from: start, to: point, within: bounds)
        case let .resize(start, previous, handle):
            region = handle.resize(previous, from: start, to: point, within: bounds)
        case .draw:
            let end = region.clamping(point)
            if draft?.tool == .pen {
                if draft?.points.last != end { draft?.points.append(end) }
            } else {
                draft?.points[1] = end
            }
        case nil:
            break
        }
    }

    private func addMarkup(_ annotation: Markup) {
        markup.append(annotation)
        history.append(.markup)
    }

    private func undo() {
        finishText()
        guard drag == nil, let edit = history.popLast() else { return }
        switch edit {
        case let .region(previous): region = previous
        case .markup: markup.removeLast()
        }
        window?.makeFirstResponder(self)
        refresh()
    }

    private func confirm() {
        guard isEditing, drag == nil else { return }
        finishText()
        onConfirm?(region, markup)
    }

    private func resizeHandle(at point: CGPoint) -> ResizeHandle? {
        guard tool == .select else { return nil }
        return ResizeHandle.all.filter { handleRect(at: $0.point(in: region), size: 14).contains(point) }
            .min { lhs, rhs in
                let a = lhs.point(in: region)
                let b = rhs.point(in: region)
                return hypot(a.x - point.x, a.y - point.y) < hypot(b.x - point.x, b.y - point.y)
            }
    }

    func cursor(at point: CGPoint) -> NSCursor {
        if case let .resize(_, _, handle) = drag { return handle.cursor }
        if case .move = drag { return .openHand }
        if !toolbar.isHidden, toolbar.frame.contains(point) { return .arrow }
        if let textInput, textInput.field.frame.contains(point) { return .iBeam }
        guard isEditing else { return .crosshair }
        if let handle = resizeHandle(at: point) { return handle.cursor }
        guard region.contains(point) else { return .crosshair }
        switch tool {
        case .select: return .openHand
        case .text: return .iBeam
        default: return .crosshair
        }
    }

    private func handleRect(at point: CGPoint, size: CGFloat) -> CGRect {
        CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
    }

    private func refresh() {
        toolbar.isHidden = !isEditing || drag != nil
        if !toolbar.isHidden {
            let size = EditorToolbar.preferredSize
            let gap: CGFloat = 10
            let below = region.maxY + gap
            let above = region.minY - gap - size.height
            let y = below + size.height <= bounds.maxY - gap ? below : max(gap, above)
            let x = max(gap, min(region.maxX - size.width, bounds.maxX - gap - size.width))
            toolbar.frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            toolbar.update(tool: tool, color: color, canUndo: !history.isEmpty)
        }
        if let window, window.isKeyWindow {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(point) { cursor(at: point).set() }
        }
        needsDisplay = true
    }

    private func beginText(at point: CGPoint) {
        let width: CGFloat = 190
        let height: CGFloat = 31
        let origin = CGPoint(x: min(point.x, bounds.maxX - width), y: min(point.y, bounds.maxY - height))
        let field = NSTextField(frame: CGRect(origin: origin, size: CGSize(width: width, height: height)))
        field.font = .systemFont(ofSize: 22, weight: .semibold)
        field.placeholderString = "输入文字"
        field.maximumNumberOfLines = 1
        field.usesSingleLineMode = true
        field.textColor = color.color
        field.backgroundColor = color == .black ? .white : .black
        field.delegate = self
        textInput = TextInput(field: field, origin: point, color: color)
        addSubview(field, positioned: .above, relativeTo: toolbar)
        window?.makeFirstResponder(field)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch NSStringFromSelector(selector) {
        case "insertNewline:", "insertTab:":
            finishText()
        case "cancelOperation:":
            finishText(discarding: true)
        default:
            return false
        }
        window?.makeFirstResponder(self)
        refresh()
        return true
    }

    private func finishText(discarding: Bool = false) {
        guard let input = textInput else { return }
        textInput = nil
        let value = (input.field.currentEditor()?.string ?? input.field.stringValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        input.field.removeFromSuperview()
        if !discarding, !value.isEmpty {
            addMarkup(Markup(tool: .text, color: input.color, points: [input.origin], text: value))
        }
    }
}

private extension ResizeHandle {
    @MainActor
    var cursor: NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch (x, y) {
            case (0, 0): position = .topLeft
            case (0.5, 0): position = .top
            case (1, 0): position = .topRight
            case (0, 0.5): position = .left
            case (1, 0.5): position = .right
            case (0, 1): position = .bottomLeft
            case (0.5, 1): position = .bottom
            default: position = .bottomRight
            }
            return .frameResize(position: position, directions: .all)
        }

        if x == 0.5 { return .resizeUpDown }
        if y == 0.5 { return .resizeLeftRight }
        return x == y ? Self.topLeftCursor : Self.topRightCursor
    }

    @MainActor private static let topLeftCursor = diagonalCursor(rotatedBy: -.pi / 4)
    @MainActor private static let topRightCursor = diagonalCursor(rotatedBy: .pi / 4)

    @MainActor
    private static func diagonalCursor(rotatedBy angle: CGFloat) -> NSCursor {
        let source = NSCursor.resizeLeftRight
        let image = source.image
        let hotSpot = source.hotSpot
        let side = ceil(hypot(image.size.width, image.size.height))
        let center = CGPoint(x: side / 2, y: side / 2)
        let rotated = NSImage(size: CGSize(width: side, height: side), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: angle)
            image.draw(at: CGPoint(x: -hotSpot.x, y: hotSpot.y - image.size.height),
                       from: .zero, operation: .copy, fraction: 1)
            return true
        }
        return NSCursor(image: rotated, hotSpot: center)
    }
}
