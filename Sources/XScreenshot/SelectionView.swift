import AppKit
import QuartzCore

@MainActor
final class SelectionView: NSView {
    var onRegionSelected: (() -> Void)?
    var onCancel: (() -> Void)?
    var onConfirm: ((CGRect, [Markup]) -> Void)?
    var allowsEditing = true

    private enum Drag {
        case select(CGPoint)
        case move(CGPoint, CGRect)
        case resize(CGPoint, CGRect, ResizeHandle)
        case draw
        case text(CGPoint)
    }

    private enum Edit {
        case region(CGRect)
        case markup
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
    private var textInput: TextAnnotationEditor?
    private var dragDisplayLink: CADisplayLink?

    init(snapshot: DisplaySnapshot) {
        preview = SelectionPreview(snapshot: snapshot)
        super.init(frame: CGRect(origin: .zero, size: snapshot.size))
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved, .cursorUpdate],
                                       owner: self, userInfo: nil))
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
                drag = .text(point)
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
        case .draw, .text, nil:
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
        let point = convert(event.locationInWindow, from: nil)
        updateDrag(at: point)
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
        case let .text(start):
            beginText(at: start, in: textBox(from: start, to: point))
        }
        refresh()
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func scrollWheel(with event: NSEvent) {
        if let textInput {
            textInput.adjustFont(with: event)
        } else {
            super.scrollWheel(with: event)
        }
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
            textInput.markupColor = color
            window?.makeFirstResponder(textInput)
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
        case let .text(start):
            preview.updateTextBox(textBox(from: start, to: point))
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

    func cursor(at point: CGPoint) -> NSCursor {
        if case let .resize(_, _, handle) = drag { return handle.cursor }
        if case .move = drag { return .openHand }
        if case .text = drag { return .crosshair }
        if !toolbar.isHidden, toolbar.frame.contains(point) { return .arrow }
        if let textInput, textInput.frame.contains(point) { return .iBeam }
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
        if let window, window.isKeyWindow {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            if bounds.contains(point) { cursor(at: point).set() }
        }
    }

    private func textBox(from start: CGPoint, to point: CGPoint) -> CGRect? {
        let box = CGRect.spanning(start, region.clamping(point))
        return box.width >= 8 && box.height >= 8 ? box : nil
    }

    private func beginText(at point: CGPoint, in box: CGRect?) {
        let input = TextAnnotationEditor(at: point, in: box, color: color)
        if box == nil { input.maxSize = bounds.size }
        input.onFinish = { [weak self] discarding in
            self?.finishText(discarding: discarding)
            self?.refresh()
        }
        textInput = input
        addSubview(input, positioned: .below, relativeTo: toolbar)
        window?.makeFirstResponder(input)
    }

    private func finishText(discarding: Bool = false) {
        guard let input = textInput else { return }
        textInput = nil
        if window?.firstResponder === input { window?.makeFirstResponder(self) }
        let annotation = discarding ? nil : input.annotation
        input.removeFromSuperview()
        preview.updateTextBox(nil)
        if let annotation { addMarkup(annotation) }
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
