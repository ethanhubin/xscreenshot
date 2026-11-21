import AppKit
import Testing
@testable import XScreenshot

@Test
@MainActor
func cropAndMarkupShareRetinaCoordinates() throws {
    let width = 80
    let height = 60
    var pixels: [UInt8] = []
    for y in 0..<height {
        for x in 0..<width {
            pixels += [UInt8(x), UInt8(y), 0, 255]
        }
    }
    let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                     bytesPerRow: width * 4, space: colorSpace,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                     provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let snapshot = DisplaySnapshot(image: image, size: CGSize(width: 40, height: 30))
    let region = CGRect(x: 8, y: 5, width: 22, height: 18)
    let line = Markup(tool: .line, color: .red, points: [CGPoint(x: 4, y: 8), CGPoint(x: 18, y: 8)])

    let crop = NSBitmapImageRep(cgImage: try snapshot.export(region: region, markup: []))
    let marked = NSBitmapImageRep(cgImage: try snapshot.export(region: region, markup: [line]))
    #expect(marked.pixelsWide == 44)
    #expect(marked.pixelsHigh == 36)
    let corner = try #require(crop.colorAt(x: 0, y: 0))
    #expect(abs(corner.redComponent * 255 - 16) < 1)
    #expect(abs(corner.greenComponent * 255 - 10) < 1)
    #expect(try #require(marked.colorAt(x: 1, y: 6)).redComponent > 0.95)
    #expect(try #require(marked.colorAt(x: 8, y: 6)).redComponent > 0.95)
    #expect(try #require(marked.colorAt(x: 8, y: 29)).redComponent < 0.2)

    let preview = SelectionPreview(snapshot: snapshot)
    preview.updateRegion(region, showHandles: false)
    #expect(resolutionText(in: preview) == "\(marked.pixelsWide) × \(marked.pixelsHigh)")
    let resized = CGRect(x: 8.25, y: 5.25, width: 12, height: 10)
    preview.updateRegion(resized, showHandles: true)
    let resizedImage = try snapshot.export(region: resized, markup: [])
    #expect(resolutionText(in: preview) == "\(resizedImage.width) × \(resizedImage.height)")
    preview.updateRegion(.zero, showHandles: false)
    #expect(preview.resolutionFrame.isNull)

    let text = Markup(tool: .text, color: .white, points: [CGPoint(x: 10, y: 5)], text: "X")
    let labelled = NSBitmapImageRep(cgImage: try snapshot.export(region: region, markup: [text]))
    var hasWhiteGlyph = false
    for y in 0..<labelled.pixelsHigh {
        for x in 0..<labelled.pixelsWide {
            if (labelled.colorAt(x: x, y: y)?.blueComponent ?? 0) > 0.9 { hasWhiteGlyph = true }
        }
    }
    #expect(hasWhiteGlyph)
}

@Test
func movingAndResizingKeepTheRegionInsideTheDisplay() {
    let bounds = CGRect(x: 0, y: 0, width: 500, height: 300)
    let region = CGRect(x: 20, y: 30, width: 200, height: 100)
    #expect(region.moved(from: .zero, to: CGPoint(x: 700, y: -80), within: bounds) ==
            CGRect(x: 300, y: 0, width: 200, height: 100))

    let topLeft = ResizeHandle(x: 0, y: 0)
    #expect(topLeft.resize(region, from: CGPoint(x: 20, y: 30), to: CGPoint(x: 600, y: -20), within: bounds) ==
            CGRect(x: 218, y: 0, width: 2, height: 130))

    let rightEdge = ResizeHandle(x: 1, y: 0.5)
    #expect(rightEdge.resize(region, from: CGPoint(x: 220, y: 80), to: CGPoint(x: 340, y: 350), within: bounds) ==
            CGRect(x: 20, y: 30, width: 320, height: 100))
}

@Test
func shortcutSurvivesSavingAndFallsBackWhenMissing() throws {
    let shortcut = Shortcut(keyCode: 12, modifiers: 4352, key: "Q")
    let data = try JSONEncoder().encode(shortcut)
    #expect(Shortcut.restored(from: data) == shortcut)
    #expect(Shortcut.restored(from: nil) == .standard)
    #expect(Shortcut.restored(from: Data([0])) == .standard)
    #expect(Shortcut.standard.displayName == "⌃⇧4")
}

@Test
@MainActor
func selectionShowsTheEditorBeforeItCanConfirm() throws {
    let context = try #require(CGContext(data: nil, width: 640, height: 460, bitsPerComponent: 8, bytesPerRow: 0,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor.white)
    context.fill(CGRect(x: 0, y: 0, width: 640, height: 460))
    context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
    context.fill(CGRect(x: 25, y: 430, width: 16, height: 16))
    let image = try #require(context.makeImage())
    let snapshot = DisplaySnapshot(image: image, size: CGSize(width: 640, height: 460))
    let view = SelectionView(snapshot: snapshot)
    let toolbar = try #require(view.subviews.compactMap { $0 as? EditorToolbar }.first)
    for tool in EditorTool.allCases {
        #expect(NSImage(systemSymbolName: tool.icon, accessibilityDescription: nil) != nil, "\(tool.icon)")
    }
    var confirmed: CGRect?
    var confirmedMarkup: [Markup] = []
    view.onConfirm = { region, markup in
        confirmed = region
        confirmedMarkup = markup
    }

    func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: 1))
    }

    view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100)))
    view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 430, y: 225)))
    #expect(toolbar.isHidden)
    #expect(view.cursor(at: CGPoint(x: 430, y: 225)) === NSCursor.crosshair)
    view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 430, y: 225)))
    #expect(!toolbar.isHidden)
    #expect(toolbar.frame.minY > 225)
    #expect(confirmed == nil)

    #expect(view.cursor(at: CGPoint(x: 200, y: 150)) === NSCursor.openHand)
    #expect(view.cursor(at: CGPoint(x: 90, y: 90)) === NSCursor.crosshair)
    #expect(view.cursor(at: CGPoint(x: toolbar.frame.midX, y: toolbar.frame.midY)) === NSCursor.arrow)
    if #available(macOS 15.0, *) {
        let handles: [(CGPoint, NSCursor.FrameResizePosition)] = [
            (CGPoint(x: 96, y: 96), .topLeft),
            (CGPoint(x: 265, y: 100), .top),
            (CGPoint(x: 430, y: 100), .topRight),
            (CGPoint(x: 100, y: 162.5), .left),
            (CGPoint(x: 430, y: 162.5), .right),
            (CGPoint(x: 100, y: 225), .bottomLeft),
            (CGPoint(x: 265, y: 225), .bottom),
            (CGPoint(x: 430, y: 225), .bottomRight)
        ]
        for (point, position) in handles {
            let expected = NSCursor.frameResize(position: position, directions: .all)
            #expect(view.cursor(at: point) == expected)
        }
    } else {
        #expect(view.cursor(at: CGPoint(x: 265, y: 100)) === NSCursor.resizeUpDown)
        #expect(view.cursor(at: CGPoint(x: 100, y: 162.5)) === NSCursor.resizeLeftRight)
        let topLeft = view.cursor(at: CGPoint(x: 100, y: 100))
        let topRight = view.cursor(at: CGPoint(x: 430, y: 100))
        #expect(topLeft !== topRight)
        #expect(topLeft === view.cursor(at: CGPoint(x: 430, y: 225)))
        #expect(topRight === view.cursor(at: CGPoint(x: 100, y: 225)))
    }

    view.layoutSubtreeIfNeeded()
    let toolsPanel = try #require(toolbar.subviews.first)
    let palettePanel = try #require(toolbar.subviews.last)
    let tools = try #require(toolsPanel.subviews.first as? NSStackView)
    let palette = try #require(palettePanel.subviews.first as? NSStackView)
    let toolButtons = tools.arrangedSubviews.compactMap { $0 as? NSButton }
    #expect(toolButtons.count == EditorTool.allCases.count + 3)
    let penButton = try #require(toolButtons.first { $0.toolTip?.hasPrefix(EditorTool.pen.title) == true })
    let pencil = try #require(penButton.image)
    #expect(pencil.isTemplate && pencil.size == CGSize(width: 18, height: 18))
    #expect(toolbar.bounds.width == 350)
    #expect(toolbar.bounds.height == toolsPanel.frame.height)
    #expect(palettePanel.isHidden)
    let lineButton = try #require(toolButtons.first { $0.toolTip == EditorTool.line.title })
    func hoverEvent(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                           windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0,
                                           userData: nil))
    }
    #expect(lineButton.layer?.backgroundColor == nil)
    lineButton.mouseEntered(with: try hoverEvent(.mouseEntered))
    let hover = try #require(lineButton.layer?.backgroundColor)
    #expect((0.01...0.29).contains(hover.alpha))
    #expect((lineButton.layer?.cornerRadius ?? 0) > 0)
    lineButton.mouseExited(with: try hoverEvent(.mouseExited))
    #expect(lineButton.layer?.backgroundColor == nil)

    lineButton.performClick(nil)
    view.layoutSubtreeIfNeeded()
    #expect(!palettePanel.isHidden)
    #expect(toolbar.bounds.height == palettePanel.frame.maxY)
    #expect(palettePanel.frame.minY > toolsPanel.frame.maxY)
    #expect(palette.arrangedSubviews.count == MarkupColor.allCases.count)
    #expect(palette.arrangedSubviews.allSatisfy { $0 is NSButton })
    for (panel, row) in [(toolsPanel, tools), (palettePanel, palette)] {
        #expect(row.convert(row.bounds, to: panel) == panel.bounds.insetBy(dx: 7, dy: 7))
        let frames = row.arrangedSubviews.map { $0.convert($0.bounds, to: toolbar) }
            .sorted { $0.minX < $1.minX }
        #expect(frames.allSatisfy {
            $0.size == CGSize(width: 30, height: 30) && toolbar.bounds.contains($0)
        })
        for (left, right) in zip(frames, frames.dropFirst()) {
            #expect(abs(right.minX - left.maxX - 4) < 0.01)
        }
    }
    let red = try #require(palette.arrangedSubviews.compactMap { $0 as? NSButton }.first)
    #expect(toolbar.hitTest(red.convert(CGPoint(x: red.bounds.midX, y: red.bounds.midY), to: view)) === red)
    let unusedSpace = CGPoint(x: palettePanel.frame.maxX + 10, y: palettePanel.frame.midY)
    #expect(toolbar.hitTest(toolbar.convert(unusedSpace, to: view)) == nil)

    let paletteOutline = try #require(palettePanel.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
    func expectPalettePointer(at button: NSButton) throws {
        let path = try #require(paletteOutline.path)
        let center = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
        let anchor = button.convert(center, to: palettePanel).x
        let y = palettePanel.bounds.maxY + 3.5
        #expect(path.contains(CGPoint(x: anchor, y: y)))
        #expect(!path.contains(CGPoint(x: anchor + 2, y: y)))
        #expect(toolbar.bounds.contains(palettePanel.frame))
    }
    let linePaletteX = palettePanel.frame.minX
    try expectPalettePointer(at: lineButton)
    let textIndex = try #require(EditorTool.allCases.firstIndex(of: .text))
    let textButton = toolButtons[textIndex]
    textButton.performClick(nil)
    #expect(palettePanel.frame.minX > linePaletteX)
    try expectPalettePointer(at: textButton)

    try #require(toolButtons.first).performClick(nil)
    #expect(palettePanel.isHidden)

    let selectionPreview = try #require(view.subviews.compactMap { $0 as? SelectionPreview }.first)
    #expect(resolutionText(in: selectionPreview) == "330 × 125")
    #expect(selectionPreview.resolutionFrame.minX == 100)
    #expect(selectionPreview.resolutionFrame.maxY < 100)

    let preview = try renderPreview(of: view)
    let shade = try #require(preview.colorAt(x: 20, y: 20))
    let revealed = try #require(preview.colorAt(x: 150, y: 150))
    #expect((0.48...0.57).contains(shade.redComponent))
    #expect(revealed.redComponent > 0.95)
    #expect(try #require(preview.colorAt(x: 28, y: 20)).redComponent < 0.05)
    let edgeColors = (99...101).compactMap { preview.colorAt(x: 180, y: $0) }
    #expect(edgeColors.contains { $0.blueComponent - $0.redComponent > 0.32 })

    toolbar.onConfirm?()
    #expect(confirmed == CGRect(x: 100, y: 100, width: 330, height: 125))

    toolbar.onTool?(.line)
    view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 130, y: 140)))
    view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 300, y: 140)))
    view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 300, y: 140)))
    let marked = try renderPreview(of: view)
    #expect(try #require(marked.colorAt(x: 160, y: 140)).greenComponent < 0.3)

    toolbar.onTool?(.select)
    view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 220, y: 175)))
    view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 260, y: 190)))
    let dragging = try renderPreview(of: view)
    #expect(try #require(dragging.colorAt(x: 320, y: 155)).greenComponent < 0.3)
    #expect(try #require(dragging.colorAt(x: 155, y: 140)).greenComponent > 0.95)
    view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 320, y: 195)))
    toolbar.onConfirm?()
    #expect(confirmed == CGRect(x: 200, y: 120, width: 330, height: 125))
    #expect(confirmedMarkup.first?.points == [CGPoint(x: 230, y: 160), CGPoint(x: 400, y: 160)])
    let moved = try renderPreview(of: view)
    #expect((0.48...0.57).contains(try #require(moved.colorAt(x: 160, y: 140)).greenComponent))
    #expect(try #require(moved.colorAt(x: 250, y: 160)).greenComponent < 0.3)
    #expect(try #require(moved.colorAt(x: 250, y: 140)).greenComponent > 0.95)
    let exported = NSBitmapImageRep(cgImage: try snapshot.export(region: #require(confirmed), markup: confirmedMarkup))
    #expect(try #require(exported.colorAt(x: 50, y: 40)).greenComponent < 0.3)

    toolbar.onUndo?()
    let restored = try renderPreview(of: view)
    #expect(try #require(restored.colorAt(x: 160, y: 140)).greenComponent < 0.3)
    #expect(try #require(restored.colorAt(x: 250, y: 160)).greenComponent > 0.95)
}

@Test
@MainActor
func editingOverlappingShapesTargetsTheTopmostStrokeAndKeepsUndoOrder() throws {
    let (view, toolbar, snapshot) = try makeAnnotationCapture(tool: .rectangle)
    let start = CGPoint(x: 48, y: 60)
    let corner = CGPoint(x: 130, y: 115)
    try clickOrDrag(in: view, from: corner, to: start)
    toolbar.onTool?(.arrow)
    toolbar.onColor?(.blue)
    let end = CGPoint(x: 130, y: 60)
    try clickOrDrag(in: view, from: start, to: end)

    var region = CGRect.zero
    var annotations: [Markup] = []
    view.onConfirm = { confirmedRegion, markup in
        region = confirmedRegion
        annotations = markup
    }
    toolbar.onConfirm?()
    let original = annotations
    let originalRegion = region
    #expect(original.map(\.tool) == [.rectangle, .arrow])

    toolbar.onTool?(.select)
    try clickOrDrag(in: view, from: CGPoint(x: 90, y: 60), to: CGPoint(x: 115, y: 95))
    toolbar.onColor?(.green)
    let movedEnd = CGPoint(x: 155, y: 95)
    let resizedEnd = CGPoint(x: 190, y: 130)
    try clickOrDrag(in: view, from: movedEnd, to: resizedEnd)
    toolbar.onConfirm?()
    let edited = try #require(annotations.last)
    let movedStart = CGPoint(x: 73, y: 95)
    #expect(annotations.count == 2)
    #expect(annotations.first == original.first)
    #expect(edited.points == [movedStart, resizedEnd])
    #expect(edited.color == .green)
    #expect(region == originalRegion)

    let preview = try renderPreview(of: view)
    let handle = try #require(preview.colorAt(x: 193, y: 130))
    #expect(min(handle.redComponent, handle.greenComponent, handle.blueComponent) < 0.95)
    let exported = NSBitmapImageRep(cgImage: try snapshot.export(region: region, markup: annotations))
    let exportedPixel = try #require(exported.colorAt(x: 193 - Int(region.minX), y: 130 - Int(region.minY)))
    #expect(min(exportedPixel.redComponent, exportedPixel.greenComponent, exportedPixel.blueComponent) > 0.95)

    view.keyDown(with: try key("\u{7F}", code: 51))
    toolbar.onConfirm?()
    #expect(annotations.count == 1)
    #expect(annotations.first == original.first)
    view.keyDown(with: try key("z", code: 6, modifiers: .command))
    toolbar.onConfirm?()
    #expect(annotations.last == edited)
    toolbar.onUndo?()
    toolbar.onConfirm?()
    #expect(annotations.last?.points == [movedStart, movedEnd])
    toolbar.onUndo?()
    toolbar.onConfirm?()
    #expect(annotations.last?.color == .blue)
    toolbar.onUndo?()
    toolbar.onConfirm?()
    #expect(annotations == original)

    let edge = CGPoint(x: corner.x, y: 95)
    try clickOrDrag(in: view, from: edge, to: edge)
    let resizedCorner = CGPoint(x: 160, y: 135)
    try clickOrDrag(in: view, from: corner, to: resizedCorner)
    toolbar.onConfirm?()
    #expect(annotations.first?.points == [resizedCorner, start])
    toolbar.onUndo?()

    let interior = CGPoint(x: 92, y: 90)
    #expect(view.cursor(at: interior) === NSCursor.arrow)
    try clickOrDrag(in: view, from: interior, to: CGPoint(x: 100, y: 90))
    #expect(toolbar.bounds.height > (toolbar.subviews.first?.frame.height ?? 0))
    toolbar.onConfirm?()
    #expect(region == originalRegion)
    #expect(annotations.first?.points == [CGPoint(x: 138, y: 115), CGPoint(x: 56, y: 60)])
    #expect(annotations.last == original.last)

    let blank = CGPoint(x: 220, y: 160)
    #expect(view.cursor(at: blank) === NSCursor.openHand)
    #expect(view.cursor(at: CGPoint(x: originalRegion.minX - 2, y: blank.y)) === NSCursor.openHand)
    try clickOrDrag(in: view, from: blank, to: CGPoint(x: 240, y: 170))
    toolbar.onConfirm?()
    #expect(region == originalRegion.offsetBy(dx: 20, dy: 10))
    #expect(annotations.first?.points == [CGPoint(x: 158, y: 125), CGPoint(x: 76, y: 70)])
    #expect(annotations.last?.points == [CGPoint(x: 68, y: 70), CGPoint(x: 150, y: 70)])

    toolbar.onUndo?()
    toolbar.onUndo?()
    toolbar.onConfirm?()
    #expect(region == originalRegion)
    #expect(annotations == original)
}

@Test
@MainActor
func closedShapesCanBeSelectedFromTheirInteriorsAndStrokes() {
    let bounds = [CGPoint(x: 20, y: 20), CGPoint(x: 110, y: 110)]
    let rectangle = Markup(tool: .rectangle, color: .red, points: bounds)
    let ellipse = Markup(tool: .ellipse, color: .red, points: bounds)
    #expect(rectangle.hitTest(CGPoint(x: 65, y: 24)) == .content)
    #expect(rectangle.hitTest(CGPoint(x: 65, y: 65)) == .interior)
    #expect(ellipse.hitTest(CGPoint(x: 65, y: 20)) == .content)
    #expect(ellipse.hitTest(CGPoint(x: 65, y: 65)) == .interior)
    #expect(ellipse.hitTest(bounds[0]) == nil)

    let pen = Markup(tool: .pen, color: .red, points: [
        CGPoint(x: 20, y: 30), CGPoint(x: 40, y: 10), CGPoint(x: 60, y: 30)
    ])
    #expect(pen.hitTest(CGPoint(x: 40, y: 9)) == .content)
    #expect(pen.hitTest(CGPoint(x: 40, y: 25)) == nil)

    let arrow = Markup(tool: .arrow, color: .red, points: [CGPoint(x: 20, y: 50), CGPoint(x: 90, y: 50)])
    #expect(arrow.hitTest(CGPoint(x: 77, y: 58)) == .content)
}

@Test
@MainActor
func draggingAMarkToTheCropEdgeKeepsTheStrokeReachable() {
    let bounds = CGRect(x: 10, y: 10, width: 100, height: 80)
    let line = Markup(tool: .line, color: .red, points: [CGPoint(x: 30, y: 50), CGPoint(x: 65, y: 50)])
    let grabPoint = CGPoint(x: 46, y: 55)
    let moved = line.moved(from: grabPoint, to: CGPoint(x: 46, y: -10), within: bounds)
    #expect(moved.drawingBounds.minY == bounds.minY)
    #expect(moved.hitTest(CGPoint(x: 46, y: 12)) == .content)

    let clipped = Markup(tool: .line, color: .red, points: [CGPoint(x: 4, y: 50), CGPoint(x: 65, y: 50)])
    let nudged = clipped.moved(from: grabPoint, to: CGPoint(x: 47, y: 55), within: bounds)
    #expect(nudged.points.first == CGPoint(x: 5, y: 50))
}

@Test
@MainActor
func scrollingResizesTheBrushCursorAndEachNewStroke() throws {
    let (view, toolbar, snapshot) = try makeAnnotationCapture(tool: .pen)
    func scroll(_ delta: Int32) throws {
        let event = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                         wheel1: delta, wheel2: 0, wheel3: 0))
        view.scrollWheel(with: try #require(NSEvent(cgEvent: event)))
    }

    let start = CGPoint(x: 60, y: 80)
    let defaultCursor = view.cursor(at: start)
    #expect(defaultCursor !== NSCursor.crosshair)
    try scroll(16)
    let wideCursor = view.cursor(at: start)
    #expect(wideCursor.image.size.width > defaultCursor.image.size.width)
    #expect(wideCursor.hotSpot == CGPoint(x: wideCursor.image.size.width / 2, y: wideCursor.image.size.height / 2))
    try clickOrDrag(in: view, from: start, to: CGPoint(x: 170, y: start.y))

    try scroll(-100)
    let fineCursor = view.cursor(at: start)
    #expect(fineCursor.image.size.width < wideCursor.image.size.width)
    try clickOrDrag(in: view, from: CGPoint(x: 60, y: 125), to: CGPoint(x: 170, y: 125))
    toolbar.onTool?(.line)
    #expect(view.cursor(at: start) === NSCursor.crosshair)
    try clickOrDrag(in: view, from: CGPoint(x: 60, y: 170), to: CGPoint(x: 170, y: 170))

    var annotations: [Markup] = []
    var region = CGRect.zero
    view.onConfirm = { rect, markup in
        region = rect
        annotations = markup
    }
    toolbar.onConfirm?()
    #expect(annotations.map(\.lineWidth) == [19, 1, Markup.defaultLineWidth])
    let wideStroke = try #require(annotations.first)
    #expect(wideStroke.hitTest(CGPoint(x: 110, y: 94)) == .content)
    #expect(wideStroke.hitTest(CGPoint(x: 110, y: 98)) == nil)

    let cursorData = try #require(wideCursor.image.tiffRepresentation)
    let ring = try #require(NSBitmapImageRep(data: cursorData))
    let centerX = ring.pixelsWide / 2
    let centerY = ring.pixelsHigh / 2
    let radius = Int(wideStroke.lineWidth / 2 * CGFloat(ring.pixelsWide) / wideCursor.image.size.width)
    #expect(try #require(ring.colorAt(x: centerX, y: centerY)).alphaComponent < 0.1)
    #expect(try #require(ring.colorAt(x: centerX + radius, y: centerY)).alphaComponent > 0.7)

    let preview = try renderPreview(of: view)
    #expect(try #require(preview.colorAt(x: 110, y: 87)).greenComponent < 0.3)
    #expect(try #require(preview.colorAt(x: 110, y: 132)).greenComponent > 0.95)
    let exported = NSBitmapImageRep(cgImage: try snapshot.export(region: region, markup: annotations))
    #expect(try #require(exported.colorAt(x: 110 - Int(region.minX), y: 87 - Int(region.minY))).greenComponent < 0.3)
}

@MainActor
private func resolutionText(in preview: SelectionPreview) -> String? {
    let children = preview.layer?.sublayers?.flatMap { $0.sublayers ?? [] } ?? []
    let layer = children.compactMap { $0 as? CATextLayer }.first
    return (layer?.string as? NSAttributedString)?.string
}

@MainActor
private func renderPreview(of view: SelectionView) throws -> NSBitmapImageRep {
    let layer = try #require(view.subviews.compactMap { $0 as? SelectionPreview }.first?.layer)
    let context = try #require(CGContext(data: nil, width: Int(view.bounds.width), height: Int(view.bounds.height),
                                        bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    func display(_ layer: CALayer) {
        layer.displayIfNeeded()
        layer.sublayers?.forEach { display($0) }
    }
    display(layer)
    layer.render(in: context)
    return NSBitmapImageRep(cgImage: try #require(context.makeImage()))
}
