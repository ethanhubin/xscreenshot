import AppKit
import Testing
@testable import XScreenshot

@Test
@MainActor
func clickingAddsMultilineTextAtTheChosenFontSize() throws {
    let (view, toolbar, _) = try makeTextCapture()
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
    discarded.insertText("Discard this", replacementRange: discarded.selectedRange())
    discarded.keyDown(with: try key("\u{1B}", code: 53))
    #expect(discarded.superview == nil)

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
func draggingFitsWrappedTextAndExportsOnlyTheGlyphs() throws {
    let (view, toolbar, snapshot) = try makeTextCapture()
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

@MainActor
private func makeTextCapture() throws -> (SelectionView, EditorToolbar, DisplaySnapshot) {
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
    toolbar.onTool?(.text)
    return (view, toolbar, snapshot)
}

@MainActor
private func clickOrDrag(in view: SelectionView, from start: CGPoint, to end: CGPoint) throws {
    func event(_ type: NSEvent.EventType, _ point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: 1))
    }
    view.mouseDown(with: try event(.leftMouseDown, start))
    if start != end { view.mouseDragged(with: try event(.leftMouseDragged, end)) }
    view.mouseUp(with: try event(.leftMouseUp, end))
}

private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                  windowNumber: 0, context: nil, characters: characters,
                                  charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
}
