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
    let view = SelectionView(snapshot: DisplaySnapshot(image: image, size: CGSize(width: 640, height: 460)))
    let toolbar = try #require(view.subviews.compactMap { $0 as? EditorToolbar }.first)
    for tool in EditorTool.allCases {
        #expect(NSImage(systemSymbolName: tool.icon, accessibilityDescription: nil) != nil, "\(tool.icon)")
    }
    var confirmed: CGRect?
    view.onConfirm = { region, _ in confirmed = region }

    func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                       timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0,
                                       clickCount: 1, pressure: 1))
    }

    view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 100, y: 100)))
    view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 430, y: 225)))
    #expect(toolbar.isHidden)
    view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 430, y: 225)))
    #expect(!toolbar.isHidden)
    #expect(toolbar.frame.minY > 225)
    #expect(confirmed == nil)

    func buttons(in parent: NSView) -> [NSButton] {
        parent.subviews.flatMap { child in (child as? NSButton).map { [$0] } ?? buttons(in: child) }
    }
    view.layoutSubtreeIfNeeded()
    let controls = buttons(in: toolbar)
    #expect(controls.count == EditorTool.allCases.count + MarkupColor.allCases.count + 3)
    #expect(controls.allSatisfy { !$0.bounds.isEmpty && toolbar.bounds.contains($0.convert($0.bounds, to: toolbar)) })

    let previewLayer = try #require(view.subviews.compactMap { $0 as? SelectionPreview }.first?.layer)
    func display(_ layer: CALayer) {
        layer.displayIfNeeded()
        layer.sublayers?.forEach { display($0) }
    }
    func renderPreview() throws -> NSBitmapImageRep {
        display(previewLayer)
        previewLayer.render(in: context)
        return NSBitmapImageRep(cgImage: try #require(context.makeImage()))
    }
    let preview = try renderPreview()
    let shade = try #require(preview.colorAt(x: 20, y: 20))
    let revealed = try #require(preview.colorAt(x: 150, y: 150))
    #expect((0.48...0.57).contains(shade.redComponent))
    #expect(revealed.redComponent > 0.95)
    #expect(try #require(preview.colorAt(x: 28, y: 20)).redComponent < 0.05)

    toolbar.onConfirm?()
    #expect(confirmed == CGRect(x: 100, y: 100, width: 330, height: 125))

    toolbar.onTool?(.line)
    view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 130, y: 140)))
    view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 300, y: 140)))
    view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 300, y: 140)))
    let marked = try renderPreview()
    #expect(try #require(marked.colorAt(x: 160, y: 140)).greenComponent < 0.3)

    toolbar.onTool?(.select)
    view.mouseDown(with: try mouse(.leftMouseDown, at: CGPoint(x: 220, y: 175)))
    view.mouseDragged(with: try mouse(.leftMouseDragged, at: CGPoint(x: 260, y: 175)))
    view.mouseUp(with: try mouse(.leftMouseUp, at: CGPoint(x: 320, y: 175)))
    toolbar.onConfirm?()
    #expect(confirmed == CGRect(x: 200, y: 100, width: 330, height: 125))
    let moved = try renderPreview()
    #expect((0.48...0.57).contains(try #require(moved.colorAt(x: 160, y: 140)).greenComponent))
    #expect(try #require(moved.colorAt(x: 250, y: 140)).greenComponent < 0.3)
    #expect(try #require(moved.colorAt(x: 480, y: 140)).greenComponent > 0.95)

    toolbar.onUndo?()
    let restored = try renderPreview()
    #expect(try #require(restored.colorAt(x: 160, y: 140)).greenComponent < 0.3)
}
