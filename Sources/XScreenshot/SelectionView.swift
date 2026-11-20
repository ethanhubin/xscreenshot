import AppKit
import QuartzCore

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

    private let preview: SelectionPreview
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
    private var dragDisplayLink: CADisplayLink?

    init(snapshot: DisplaySnapshot) {
        preview = SelectionPreview(snapshot: snapshot)
        super.init(frame: CGRect(origin: .zero, size: snapshot.size))
        preview.markupForDisplay = { [weak self] in (self?.markup ?? [], self?.draft) }
        addSubview(preview)
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

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        stopDragUpdates()
        super.viewWillMove(toWindow: newWindow)
    }

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
        switch drag {
        case .select, .move, .resize:
            guard window != nil, dragDisplayLink == nil else { return }
            let link = displayLink(target: self, selector: #selector(displayFrame(_:)))
            dragDisplayLink = link
            link.add(to: .main, forMode: .common)
        case .draw, nil:
            break
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag else { return }
        updateDrag(at: convert(event.locationInWindow, from: nil))
        if case .draw = drag {
            preview.updateMarkup()
        } else if dragDisplayLink == nil {
            presentRegion()
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let drag else { return }
        stopDragUpdates()
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
            let finalDraft = draft
            draft = nil
            if let finalDraft, let first = finalDraft.points.first,
               finalDraft.points.contains(where: { hypot($0.x - first.x, $0.y - first.y) >= 1 }) {
                addMarkup(finalDraft)
            } else {
                preview.updateMarkup()
            }
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

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
        if isEditing, tool == .select {
            addCursorRect(region, cursor: .openHand)
            for handle in ResizeHandle.all {
                let cursor: NSCursor = handle.x == 0.5 ? .resizeUpDown : handle.y == 0.5 ? .resizeLeftRight : .crosshair
                addCursorRect(handleRect(at: handle.point(in: region), size: 14).intersection(bounds), cursor: cursor)
            }
        } else if isEditing, tool == .text {
            addCursorRect(region, cursor: .iBeam)
        }
        if !toolbar.isHidden { addCursorRect(toolbar.frame, cursor: .arrow) }
    }

    func stopDragUpdates() {
        dragDisplayLink?.invalidate()
        dragDisplayLink = nil
    }

    @objc private func displayFrame(_ link: CADisplayLink) {
        presentRegion()
    }

    private func presentRegion() {
        preview.updateRegion(region, showHandles: isEditing && tool == .select)
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
        preview.updateMarkup()
    }

    private func undo() {
        finishText()
        guard drag == nil, let edit = history.popLast() else { return }
        switch edit {
        case let .region(previous): region = previous
        case .markup:
            markup.removeLast()
            preview.updateMarkup()
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

    private func handleRect(at point: CGPoint, size: CGFloat) -> CGRect {
        CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
    }

    private func refresh() {
        presentRegion()
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
        window?.invalidateCursorRects(for: self)
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
