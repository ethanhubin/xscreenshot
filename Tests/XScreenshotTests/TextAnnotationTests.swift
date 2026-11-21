import AppKit
import QuartzCore
import Testing
@testable import XScreenshot

@Test
@MainActor
func clickingAddsMultilineTextAtTheChosenFontSize() throws {
    let (view, toolbar, _) = try makeAnnotationCapture(tool: .text)
    let panel = NSPanel(contentRect: view.bounds, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
    panel.contentView = view
    defer { panel.contentView = nil }

    let point = CGPoint(x: 48, y: 60)
    try clickOrDrag(in: view, from: point, to: point)
    let editor = try #require(view.subviews.compactMap { $0 as? TextAnnotationEditor }.first)
    #expect(editor.box == nil)
    #expect(panel.firstResponder === editor)

    editor.insertText("First line", replacementRange: editor.selectedRange())
    editor.keyDown(with: try key("\r", code: 36, modifiers: .shift))
    editor.insertText("第二行", replacementRange: editor.selectedRange())
    #expect(editor.string == "First line\n第二行")
    let originalSize = try #require(editor.font?.pointSize)

    let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                     wheel1: 2, wheel2: 0, wheel3: 0))
    editor.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
    let resized = try #require(editor.font?.pointSize)
    #expect(resized > originalSize)

    let container = try #require(editor.textContainer)
    editor.layoutManager?.ensureLayout(for: container)
    let frame = editor.frame
    let preview = try #require(view.bitmapImageRepForCachingDisplay(in: frame))
    view.cacheDisplay(in: frame, to: preview)
    let inkRows = (0..<preview.pixelsHigh).filter { y in
        (0..<preview.pixelsWide).contains { x in
            (preview.colorAt(x: x, y: y)?.greenComponent ?? 1) < 0.5
        }
    }
    #expect(inkRows.contains { $0 < preview.pixelsHigh / 2 })
    #expect(inkRows.contains { $0 > preview.pixelsHigh / 2 })

    editor.keyDown(with: try key("\r", code: 36))
    #expect(editor.superview == nil)

    try clickOrDrag(in: view, from: point, to: point)
    let discarded = try #require(view.subviews.compactMap { $0 as? TextAnnotationEditor }.first)
    #expect(discarded.string == "First line\n第二行")
    let (outline, _) = try textOutline(in: view)
    #expect(outline.frame.size == discarded.frame.size)
    discarded.insertText("Discard this", replacementRange: discarded.selectedRange())
    discarded.keyDown(with: try key("\u{1B}", code: 53))
    #expect(discarded.superview == nil)
    #expect(outline.animation(forKey: "opacity") == nil)
    #expect(outline.isHidden)

    var annotations: [Markup] = []
    view.onConfirm = { _, markup in annotations = markup }
    toolbar.onConfirm?()
    let annotation = try #require(annotations.first)
    #expect(annotations.count == 1)
    #expect(annotation.text == "First line\n第二行")
    #expect(annotation.points == [point])
    #expect(annotation.fontSize == resized)
    #expect(annotation.textBoxSize == nil)
}

@Test
@MainActor
func clickingInsideAnExistingTextBoxEditsItInTextMode() throws {
    let (view, toolbar, _) = try makeAnnotationCapture(tool: .text)
    let panel = NSPanel(contentRect: view.bounds, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
    panel.contentView = view
    defer { panel.contentView = nil }

    let box = CGRect(x: 48, y: 60, width: 146, height: 84)
    try clickOrDrag(in: view, from: box.origin, to: CGPoint(x: box.maxX, y: box.maxY))
    let input = try #require(view.subviews.compactMap { $0 as? TextAnnotationEditor }.first)
    toolbar.onColor?(.blue)
    input.insertText("Original text", replacementRange: input.selectedRange())
    let original = try #require(input.annotation)
    input.keyDown(with: try key("\r", code: 36))

    let click = CGPoint(x: box.minX + 1, y: box.minY + 8)
    try clickOrDrag(in: view, from: click, to: click)
    let editor = try #require(view.subviews.compactMap { $0 as? TextAnnotationEditor }.first)
    #expect(panel.firstResponder === editor)
    #expect(editor.box == box)
    #expect(editor.annotation == original)
    #expect(editor.selectedRange() == NSRange(location: 0, length: 0))
    let (outline, highlight) = try textOutline(in: view)
    #expect(outline.frame == CGRect(x: box.minX, y: view.bounds.height - box.maxY,
                                    width: box.width, height: box.height))
    #expect(!outline.isHidden)
    #expect(outline.opacity == 0)
    let opacity = try #require(highlight.values as? [Double])
    let peak = try #require(opacity.max())
    #expect(opacity.count == 3)
    #expect(opacity.first == 0 && opacity.last == 0)
    #expect(peak > 0 && peak < 0.6)
    editor.insertText("!", replacementRange: editor.selectedRange())
    editor.keyDown(with: try key("\r", code: 36))
    #expect(outline.animation(forKey: "opacity") == nil)
    #expect(outline.isHidden)

    var annotations: [Markup] = []
    view.onConfirm = { _, markup in annotations = markup }
    toolbar.onConfirm?()
    #expect(annotations.count == 1)
    #expect(annotations.first?.text == "!Original text")
    #expect(annotations.first?.points == original.points)
    #expect(annotations.first?.textBoxSize == original.textBoxSize)
    #expect(annotations.first?.color == .blue)
    toolbar.onUndo?()
    toolbar.onConfirm?()
    #expect(annotations == [original])
}

@Test
@MainActor
func draggingFitsWrappedTextAndExportsOnlyTheGlyphs() throws {
    let (view, toolbar, snapshot) = try makeAnnotationCapture(tool: .text)
    let box = CGRect(x: 48, y: 60, width: 106, height: 88)
    try clickOrDrag(in: view, from: CGPoint(x: box.maxX, y: box.maxY), to: box.origin)
    let editor = try #require(view.subviews.compactMap { $0 as? TextAnnotationEditor }.first)
    #expect(editor.box == box)
    toolbar.onColor?(.black)

    editor.insertText("W", replacementRange: editor.selectedRange())
    let singleGlyphSize = try #require(editor.font?.pointSize)
    let text = "Wrapped words and 中文文字, followed by another sentence."
    editor.insertText(text, replacementRange: NSRange(location: 0, length: 1))
    let font = try #require(editor.font)
    let manager = try #require(editor.layoutManager)
    let container = try #require(editor.textContainer)
    manager.ensureLayout(for: container)
    let used = manager.usedRect(for: container)
    #expect(font.pointSize < singleGlyphSize)
    #expect(used.height > manager.defaultLineHeight(for: font))
    #expect(used.height <= box.height - 6)

    let narrowSize = CGSize(width: 16, height: 100)
    let fitted = TextLayout.fittingFontSize(for: "W", in: narrowSize)
    #expect(TextLayout("W", fontSize: fitted, color: .black, width: nil).bounds.width <= narrowSize.width)

    var region = CGRect.zero
    var annotations: [Markup] = []
    view.onConfirm = { rect, markup in
        region = rect
        annotations = markup
    }
    toolbar.onConfirm?()
    let annotation = try #require(annotations.first)
    #expect(annotation.text == text)
    #expect(annotation.color == .black)
    #expect(annotation.fontSize == font.pointSize)
    let bitmap = NSBitmapImageRep(cgImage: try snapshot.export(region: region, markup: annotations))
    var inkRows: Set<Int> = []
    for y in 0..<bitmap.pixelsHigh {
        for x in 0..<bitmap.pixelsWide where (bitmap.colorAt(x: x, y: y)?.redComponent ?? 1) < 0.3 {
            let point = CGPoint(x: region.minX + CGFloat(x), y: region.minY + CGFloat(y))
            #expect(box.insetBy(dx: 2, dy: 2).contains(point))
            inkRows.insert(y)
        }
    }
    #expect(inkRows.filter { !inkRows.contains($0 - 1) }.count > 1)
}

@Test
@MainActor
func reopeningMovedTextKeepsItsStyleAndEditsTheSameAnnotation() throws {
    let (view, toolbar, _) = try makeAnnotationCapture(tool: .text)
    let panel = NSPanel(contentRect: view.bounds, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
    panel.contentView = view
    defer { panel.contentView = nil }

    let origin = CGPoint(x: 48, y: 60)
    try clickOrDrag(in: view, from: origin, to: origin)
    let input = try #require(view.subviews.compactMap { $0 as? TextAnnotationEditor }.first)
    input.insertText("原文字", replacementRange: input.selectedRange())
    toolbar.onColor?(.black)
    let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                     wheel1: 2, wheel2: 0, wheel3: 0))
    input.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
    input.keyDown(with: try key("\r", code: 36))

    toolbar.onTool?(.line)
    try clickOrDrag(in: view, from: CGPoint(x: 186, y: 110), to: CGPoint(x: 286, y: 110))
    toolbar.onTool?(.rectangle)
    try clickOrDrag(in: view, from: CGPoint(x: 35, y: 45), to: CGPoint(x: 166, y: 155))
    toolbar.onTool?(.select)
    let hit = CGPoint(x: 56, y: 68)
    let movedHit = CGPoint(x: 86, y: 95)
    try clickOrDrag(in: view, from: hit, to: movedHit)

    var annotations: [Markup] = []
    view.onConfirm = { _, markup in annotations = markup }
    toolbar.onConfirm?()
    let moved = try #require(annotations.first)
    #expect(annotations.map(\.tool) == [.text, .line, .rectangle])
    #expect(moved.points == [CGPoint(x: 78, y: 87)])

    func reopen() throws -> TextAnnotationEditor {
        try clickOrDrag(in: view, from: movedHit, to: movedHit, clickCount: 2)
        return try #require(view.subviews.compactMap { $0 as? TextAnnotationEditor }.first)
    }

    let editor = try reopen()
    #expect(panel.firstResponder === editor)
    _ = try textOutline(in: view)
    #expect(editor.string == "原文字")
    #expect(editor.font?.pointSize == moved.fontSize)
    #expect(editor.markupColor == .black)
    #expect(editor.annotation == moved)
    let preview = try #require(view.subviews.compactMap { $0 as? SelectionPreview }.first)
    #expect(preview.markupForDisplay?().committed.map(\.tool) == [.line, .rectangle])
    editor.insertText("改好的文字", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
    editor.keyDown(with: try key("\r", code: 36))
    toolbar.onConfirm?()
    let edited = try #require(annotations.first)
    #expect(annotations.map(\.tool) == [.text, .line, .rectangle])
    #expect(edited.text == "改好的文字")
    #expect(edited.points == moved.points)
    #expect(edited.fontSize == moved.fontSize)
    #expect(edited.color == .black)

    let discarded = try reopen()
    discarded.insertText("！", replacementRange: discarded.selectedRange())
    toolbar.onColor?(.green)
    discarded.keyDown(with: try key("\u{1B}", code: 53))
    toolbar.onConfirm?()
    #expect(annotations.first == edited)

    try reopen().keyDown(with: key("\r", code: 36))
    view.keyDown(with: try key("z", code: 6, modifiers: .command))
    toolbar.onConfirm?()
    #expect(annotations.first == moved)
    toolbar.onUndo?()
    toolbar.onConfirm?()
    #expect(annotations.first?.points == [origin])
}

@Test
@MainActor
func resizingAndEditingACommittedTextBoxRefitsTheFont() throws {
    let (view, toolbar, _) = try makeAnnotationCapture(tool: .text)
    try clickOrDrag(in: view, from: CGPoint(x: 48, y: 60), to: CGPoint(x: 200, y: 145))
    let input = try #require(view.subviews.compactMap { $0 as? TextAnnotationEditor }.first)
    let text = "Wrapped words and 中文文字, followed by another sentence."
    input.insertText(text, replacementRange: input.selectedRange())
    var annotations: [Markup] = []
    view.onConfirm = { _, markup in annotations = markup }
    toolbar.onConfirm?()
    let original = try #require(annotations.first)

    toolbar.onTool?(.select)
    let center = CGPoint(x: 92, y: 85)
    try clickOrDrag(in: view, from: center, to: center)
    try clickOrDrag(in: view, from: CGPoint(x: 197, y: 142), to: CGPoint(x: 143, y: 117))
    toolbar.onConfirm?()
    let resized = try #require(annotations.first)
    #expect(resized.text == original.text)
    #expect(resized.points == original.points)
    #expect(resized.textBoxSize == CGSize(width: 92, height: 54))
    #expect(resized.fontSize < original.fontSize)

    try clickOrDrag(in: view, from: center, to: center, clickCount: 2)
    let editor = try #require(view.subviews.compactMap { $0 as? TextAnnotationEditor }.first)
    #expect(editor.annotation == resized)
    editor.insertText("X", replacementRange: NSRange(location: 0, length: text.utf16.count))
    editor.keyDown(with: try key("\r", code: 36))
    toolbar.onConfirm?()
    let edited = try #require(annotations.first)
    #expect(edited.text == "X")
    #expect(edited.textBoxSize == resized.textBoxSize)
    #expect(edited.fontSize > resized.fontSize)

    toolbar.onUndo?()
    toolbar.onConfirm?()
    #expect(annotations == [resized])
    toolbar.onUndo?()
    toolbar.onConfirm?()
    #expect(annotations == [original])
}

@MainActor
private func textOutline(in view: SelectionView) throws -> (CALayer, CAKeyframeAnimation) {
    let preview = try #require(view.subviews.compactMap { $0 as? SelectionPreview }.first)
    let outline = try #require(preview.layer?.sublayers?.first { $0.animation(forKey: "opacity") != nil })
    let highlight = try #require(outline.animation(forKey: "opacity") as? CAKeyframeAnimation)
    return (outline, highlight)
}

@MainActor
func makeAnnotationCapture(tool: EditorTool) throws -> (SelectionView, EditorToolbar, DisplaySnapshot) {
    _ = NSApplication.shared
    let context = try #require(CGContext(data: nil, width: 380, height: 310, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor.white)
    context.fill(CGRect(x: 0, y: 0, width: 380, height: 310))
    let snapshot = DisplaySnapshot(image: try #require(context.makeImage()), size: CGSize(width: 380, height: 310))
    let view = SelectionView(snapshot: snapshot)
    let toolbar = try #require(view.subviews.compactMap { $0 as? EditorToolbar }.first)
    try clickOrDrag(in: view, from: CGPoint(x: 24, y: 34), to: CGPoint(x: 356, y: 215))
    toolbar.onTool?(tool)
    return (view, toolbar, snapshot)
}

@MainActor
func clickOrDrag(in view: SelectionView, from start: CGPoint, to end: CGPoint, clickCount: Int = 1) throws {
    func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                       clickCount: clickCount, pressure: 1))
    }
    view.mouseDown(with: try event(.leftMouseDown, start))
    if start != end { view.mouseDragged(with: try event(.leftMouseDragged, end)) }
    view.mouseUp(with: try event(.leftMouseUp, end))
}

func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                  windowNumber: 0, context: nil, characters: characters,
                                  charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
}
