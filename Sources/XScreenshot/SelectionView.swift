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
        case markup(index: Int, start: CGPoint, original: Markup, handle: Markup.Handle?)
        case draw
        case text(CGPoint)
    }

    private enum Edit {
        case region(previous: CGRect, markup: [Markup]?)
        case addedMarkup
        case changedMarkup(Int, Markup)
        case removedMarkup(Int, Markup)
    }

    private enum SelectionTarget {
        case markup(Int, Markup.Handle?)
        case region(ResizeHandle?)
    }

    private struct TextInput {
        let editor: TextAnnotationEditor
        let markupIndex: Int?
    }

    private let preview: SelectionPreview
    private let toolbar = EditorToolbar()
    private var region = CGRect.zero
    private var isEditing = false
    private var tool = EditorTool.select
    private var color = MarkupColor.red
    private var brushWidth = Markup.defaultLineWidth
    private lazy var brushCursor = NSCursor.brush(diameter: brushWidth.rounded())
    private var drag: Drag?
    private var markup: [Markup] = []
    private var selectedMarkupIndex: Int?
    private var draft: Markup?
    private var history: [Edit] = []
    private var textInput: TextInput?
    private var dragDisplayLink: CADisplayLink?

    init(snapshot: DisplaySnapshot) {
        preview = SelectionPreview(snapshot: snapshot)
        super.init(frame: CGRect(origin: .zero, size: snapshot.size))
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.inVisibleRect, .activeInKeyWindow, .mouseMoved, .cursorUpdate],
                                       owner: self, userInfo: nil))
        preview.markupForDisplay = { [weak self] in
            guard let self else { return ([], nil) }
            var visible = markup
            if let index = textInput?.markupIndex { visible.remove(at: index) }
            return (visible, draft)
        }
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
        } else if tool == .select {
            beginSelectionDrag(at: point, clickCount: event.clickCount)
        } else if region.contains(point) {
            if tool == .text {
                drag = .text(point)
            } else {
                drag = .draw
                let lineWidth = tool == .pen ? brushWidth.rounded() : Markup.defaultLineWidth
                draft = Markup(tool: tool, color: color, points: [point, point], lineWidth: lineWidth)
            }
        }
        refresh()
        switch drag {
        case .select, .move, .resize:
            guard window != nil, dragDisplayLink == nil else { return }
            let link = displayLink(target: self, selector: #selector(displayFrame(_:)))
            dragDisplayLink = link
            link.add(to: .main, forMode: .common)
        case .markup, .draw, .text, nil:
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
        let markupOffset = regionMoveOffset
        self.drag = nil
        switch drag {
        case .select:
            if region.width >= 2, region.height >= 2 {
                isEditing = true
                onRegionSelected?()
            } else {
                region = .zero
            }
        case let .move(_, previous):
            if region != previous {
                history.append(.region(previous: previous, markup: markup))
                markup = markup.map { $0.offsetBy(dx: markupOffset.x, dy: markupOffset.y) }
                preview.updateMarkup()
            }
        case let .resize(_, previous, _):
            if region != previous { history.append(.region(previous: previous, markup: nil)) }
        case let .markup(index, _, original, _):
            if markup[index] != original { history.append(.changedMarkup(index, original)) }
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
            let box = textBox(from: start, to: point)
            if box == nil, let index = markup.lastIndex(where: { $0.tool == .text && $0.hitTest(start) != nil }) {
                reopenText(at: index, caretAt: start)
            } else {
                beginText(TextAnnotationEditor(at: start, in: box, color: color))
            }
        }
        refresh()
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func scrollWheel(with event: NSEvent) {
        if let input = textInput?.editor {
            input.adjustFont(with: event)
        } else if tool == .pen {
            adjustBrush(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    private func adjustBrush(with event: NSEvent) {
        guard event.momentumPhase.isEmpty, event.scrollingDeltaY != 0 else { return }
        let previousWidth = brushWidth.rounded()
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 0.2 : 1
        brushWidth = min(64, max(1, brushWidth + step * event.scrollingDeltaY))
        let width = brushWidth.rounded()
        guard width != previousWidth else { return }
        brushCursor = .brush(diameter: width)
        if draft?.tool == .pen {
            draft?.lineWidth = width
            preview.updateMarkup()
        }
        if window?.isKeyWindow == true {
            cursor(at: convert(event.locationInWindow, from: nil)).set()
        }
    }

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers {
        case "\u{1B}": onCancel?()
        case "\r", "\u{3}": confirm()
        case "z" where event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.shift): undo()
        case "\u{7F}", "\u{08}", "\u{F728}": deleteSelectedMarkup()
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

    private var regionMoveOffset: CGPoint {
        guard case let .move(_, original) = drag else { return .zero }
        return CGPoint(x: region.minX - original.minX, y: region.minY - original.minY)
    }

    private func presentRegion() {
        preview.updateRegion(region, showHandles: isEditing && tool == .select, markupOffset: regionMoveOffset)
    }

    private func presentMarkupSelection() {
        guard let index = selectedMarkupIndex, textInput == nil else {
            preview.updateMarkupSelection(nil, handles: [])
            return
        }
        let annotation = markup[index]
        let positions = visibleHandles(for: annotation).map(\.position)
        preview.updateMarkupSelection(annotation.selectionPath, handles: positions)
    }

    private func chooseTool(_ tool: EditorTool) {
        finishText()
        self.tool = tool
        if tool != .select { selectedMarkupIndex = nil }
        window?.makeFirstResponder(self)
        refresh()
    }

    private func chooseColor(_ color: MarkupColor) {
        if let textInput {
            textInput.editor.markupColor = color
            if textInput.markupIndex == nil { self.color = color }
            window?.makeFirstResponder(textInput.editor)
        } else if let index = selectedMarkupIndex {
            var annotation = markup[index]
            annotation.color = color
            changeMarkup(at: index, to: annotation)
            preview.updateMarkup()
            window?.makeFirstResponder(self)
        } else {
            self.color = color
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
        case let .markup(index, start, original, handle):
            let updated: Markup
            if let handle {
                updated = original.resized(by: handle, from: start, to: point, within: region)
            } else {
                updated = original.moved(from: start, to: point, within: region)
            }
            if updated != markup[index] {
                markup[index] = updated
                preview.updateMarkup()
                presentMarkupSelection()
            }
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
        history.append(.addedMarkup)
        preview.updateMarkup()
    }

    private func beginSelectionDrag(at point: CGPoint, clickCount: Int) {
        switch selectionTarget(at: point) {
        case let .markup(index, handle):
            selectedMarkupIndex = index
            let annotation = markup[index]
            if handle == nil, clickCount == 2, annotation.tool == .text {
                reopenText(at: index)
            } else {
                drag = .markup(index: index, start: point, original: annotation, handle: handle)
            }
        case let .region(handle):
            selectedMarkupIndex = nil
            if let handle {
                drag = .resize(point, region, handle)
            } else {
                drag = .move(point, region)
            }
        case nil:
            selectedMarkupIndex = nil
        }
    }

    private func changeMarkup(at index: Int, to replacement: Markup?) {
        let original = markup[index]
        if let replacement {
            guard replacement != original else { return }
            history.append(.changedMarkup(index, original))
            markup[index] = replacement
        } else {
            history.append(.removedMarkup(index, original))
            markup.remove(at: index)
            selectedMarkupIndex = nil
        }
    }

    private func deleteSelectedMarkup() {
        guard drag == nil, textInput == nil, let index = selectedMarkupIndex else { return }
        changeMarkup(at: index, to: nil)
        preview.updateMarkup()
        refresh()
    }

    private func undo() {
        guard drag == nil else { return }
        finishText()
        guard let edit = history.popLast() else { return }
        switch edit {
        case let .region(previous, previousMarkup):
            region = previous
            if let previousMarkup {
                markup = previousMarkup
                preview.updateMarkup()
            }
        case .addedMarkup:
            if selectedMarkupIndex == markup.indices.last { selectedMarkupIndex = nil }
            markup.removeLast()
            preview.updateMarkup()
        case let .changedMarkup(index, previous):
            markup[index] = previous
            selectedMarkupIndex = tool == .select ? index : nil
            preview.updateMarkup()
        case let .removedMarkup(index, previous):
            markup.insert(previous, at: index)
            selectedMarkupIndex = tool == .select ? index : nil
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

    private func selectionTarget(at point: CGPoint) -> SelectionTarget? {
        if let control = markupHandle(at: point) { return .markup(control.index, control.handle) }
        if let handle = resizeHandle(at: point) { return .region(handle) }
        if region.contains(point), let index = markupIndex(at: point) { return .markup(index, nil) }
        if region.insetBy(dx: -4, dy: -4).contains(point) { return .region(nil) }
        return nil
    }

    private func markupIndex(at point: CGPoint) -> Int? {
        // Prefer a visible stroke or text over the empty interior of an overlapping shape.
        var interiorIndex: Int?
        for index in markup.indices.reversed() {
            switch markup[index].hitTest(point) {
            case .content: return index
            case .interior: interiorIndex = interiorIndex ?? index
            case nil: break
            }
        }
        return interiorIndex
    }

    private func resizeHandle(at point: CGPoint) -> ResizeHandle? {
        return ResizeHandle.all.filter { handleRect(at: $0.point(in: region), size: 14).contains(point) }
            .min { lhs, rhs in
                let a = lhs.point(in: region)
                let b = rhs.point(in: region)
                return hypot(a.x - point.x, a.y - point.y) < hypot(b.x - point.x, b.y - point.y)
            }
    }

    private func visibleHandles(for annotation: Markup) -> [(handle: Markup.Handle, position: CGPoint)] {
        annotation.handles.filter { region.clamping($0.position) == $0.position }
    }

    private func markupHandle(at point: CGPoint) -> (index: Int, handle: Markup.Handle)? {
        guard let index = selectedMarkupIndex, textInput == nil else { return nil }
        let nearest = visibleHandles(for: markup[index])
            .filter { handleRect(at: $0.position, size: 14).contains(point) }
            .min {
                hypot($0.position.x - point.x, $0.position.y - point.y) <
                    hypot($1.position.x - point.x, $1.position.y - point.y)
            }
        return nearest.map { (index, $0.handle) }
    }

    func cursor(at point: CGPoint) -> NSCursor {
        if case let .resize(_, _, handle) = drag { return handle.cursor }
        if case let .markup(_, _, _, handle) = drag { return handle?.cursor ?? .closedHand }
        if case .move = drag { return .openHand }
        if case .text = drag { return .crosshair }
        if !toolbar.isHidden, toolbar.containsPanel(at: toolbar.convert(point, from: self)) { return .arrow }
        if let input = textInput?.editor, input.frame.contains(point) { return .iBeam }
        guard isEditing else { return .crosshair }
        switch tool {
        case .select:
            switch selectionTarget(at: point) {
            case let .markup(_, handle): return handle?.cursor ?? .arrow
            case let .region(handle): return handle?.cursor ?? .openHand
            case nil: return .crosshair
            }
        case .pen where region.contains(point): return brushCursor
        case .text where region.contains(point): return .iBeam
        default: return .crosshair
        }
    }

    private func handleRect(at point: CGPoint, size: CGFloat) -> CGRect {
        CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
    }

    private func refresh() {
        presentRegion()
        presentMarkupSelection()
        toolbar.isHidden = !isEditing || drag != nil
        if !toolbar.isHidden {
            let currentColor = textInput?.editor.markupColor ?? selectedMarkupIndex.map { markup[$0].color } ?? color
            toolbar.update(tool: tool, color: currentColor, canUndo: !history.isEmpty,
                           showsPalette: tool != .select || selectedMarkupIndex != nil)
            let size = toolbar.preferredSize
            let gap: CGFloat = 10
            let bottom = max(gap, bounds.maxY - size.height - 4)
            let below = min(region.maxY + gap, max(bottom, region.maxY + 1))
            let above = region.minY - gap - size.height
            let y = below + size.height <= bounds.maxY ? below : max(gap, above)
            let x = max(gap, min(region.maxX - size.width, bounds.maxX - gap - size.width))
            var frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
            let badge = preview.resolutionFrame
            if frame.intersects(badge) {
                let aboveBadge = badge.minY - gap - size.height
                let belowBadge = min(badge.maxY + gap, bottom)
                frame.origin.y = aboveBadge >= gap ? aboveBadge : max(gap, belowBadge)
            }
            toolbar.frame = frame
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

    private func reopenText(at index: Int, caretAt point: CGPoint? = nil) {
        let annotation = markup[index]
        guard let origin = annotation.points.first else { return }
        let input = TextAnnotationEditor(editing: annotation, at: origin)
        beginText(input, replacing: index)
        if let point {
            let location = input.characterIndexForInsertion(at: input.convert(point, from: self))
            if (0...input.string.utf16.count).contains(location) {
                input.setSelectedRange(NSRange(location: location, length: 0))
            }
        }
    }

    private func beginText(_ input: TextAnnotationEditor, replacing index: Int? = nil) {
        if input.box == nil { input.maxSize = bounds.size }
        input.onFinish = { [weak self] discarding in
            self?.finishText(discarding: discarding)
            self?.refresh()
        }
        textInput = TextInput(editor: input, markupIndex: index)
        addSubview(input, positioned: .below, relativeTo: toolbar)
        if index != nil {
            if input.box == nil { input.sizeToFit() }
            preview.updateTextBox(input.frame, animated: true)
            preview.updateMarkup()
        } else {
            preview.updateTextBox(input.box)
        }
        window?.makeFirstResponder(input)
    }

    private func finishText(discarding: Bool = false) {
        guard let input = textInput else { return }
        textInput = nil
        if window?.firstResponder === input.editor { window?.makeFirstResponder(self) }
        let annotation = discarding ? nil : input.editor.annotation
        input.editor.removeFromSuperview()
        preview.updateTextBox(nil)
        if let index = input.markupIndex {
            if !discarding { changeMarkup(at: index, to: annotation) }
            preview.updateMarkup()
        } else if let annotation {
            addMarkup(annotation)
        }
    }
}

private extension NSCursor {
    @MainActor
    static func brush(diameter: CGFloat) -> NSCursor {
        let radius = diameter / 2
        let tickStart = max(radius + 3, 5)
        let tickEnd = tickStart + 2
        let halfSize = ceil(tickEnd + 2)
        let center = CGPoint(x: halfSize, y: halfSize)
        let size = CGSize(width: 2 * halfSize, height: 2 * halfSize)
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: diameter, height: diameter))
        let directions: [(CGFloat, CGFloat)] = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        for (x, y) in directions {
            path.move(to: CGPoint(x: center.x + x * tickStart, y: center.y + y * tickStart))
            path.addLine(to: CGPoint(x: center.x + x * tickEnd, y: center.y + y * tickEnd))
        }

        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.setLineCap(.round)
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.9))
            context.setLineWidth(2.5)
            context.addPath(path)
            context.strokePath()
            context.setStrokeColor(CGColor.white)
            context.setLineWidth(1)
            context.addPath(path)
            context.strokePath()
            return true
        }
        return NSCursor(image: image, hotSpot: center)
    }
}

private extension Markup.Handle {
    @MainActor
    var cursor: NSCursor {
        switch self {
        case .endpoint: .crosshair
        case let .corner(handle): handle.cursor
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
