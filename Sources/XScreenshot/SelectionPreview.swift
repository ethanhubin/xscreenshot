import AppKit
import QuartzCore

@MainActor
final class SelectionPreview: NSView, @preconcurrency CALayerDelegate {
    var markupForDisplay: (() -> (committed: [Markup], draft: Markup?))?

    private let scene = CALayer()
    private let shades = (0..<4).map { _ in CALayer() }
    private let annotationClip = CALayer()
    private let annotations = CALayer()
    private let outline = CALayer()
    private let border = CALayer()
    private let textBox = CALayer()
    private let handles = ResizeHandle.all.map { _ in CALayer() }
    private var renderedRegion: CGRect?
    private var renderedHandles = false

    init(snapshot: DisplaySnapshot) {
        super.init(frame: CGRect(origin: .zero, size: snapshot.size))
        scene.frame = bounds
        scene.contents = snapshot.image
        scene.isOpaque = true
        for shade in shades {
            shade.backgroundColor = CGColor(gray: 0, alpha: 0.48)
            scene.addSublayer(shade)
        }
        annotationClip.masksToBounds = true
        annotations.delegate = self
        annotationClip.addSublayer(annotations)
        scene.addSublayer(annotationClip)

        outline.borderColor = CGColor(gray: 0, alpha: 0.65)
        outline.borderWidth = 1
        border.borderColor = CGColor.white
        border.borderWidth = 1
        scene.addSublayer(outline)
        scene.addSublayer(border)
        textBox.isHidden = true
        textBox.borderColor = NSColor.controlAccentColor.cgColor
        textBox.borderWidth = 1.5
        textBox.shadowColor = CGColor(gray: 0, alpha: 1)
        textBox.shadowOpacity = 0.8
        textBox.shadowOffset = .zero
        textBox.shadowRadius = 1.5
        scene.addSublayer(textBox)
        for handle in handles {
            handle.bounds.size = CGSize(width: 7, height: 7)
            handle.backgroundColor = CGColor.white
            handle.borderColor = CGColor(gray: 0, alpha: 0.55)
            handle.borderWidth = 1
            handle.cornerRadius = 2
            scene.addSublayer(handle)
        }

        // Only this leaf view hosts custom layers. Controls remain AppKit subviews.
        layer = scene
        wantsLayer = true
        updateRegion(.zero, showHandles: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateMarkup()
    }

    func updateRegion(_ region: CGRect, showHandles: Bool) {
        guard renderedRegion != region || renderedHandles != showHandles else { return }
        renderedRegion = region
        renderedHandles = showHandles

        let hole = region.isEmpty ? .zero : layerRect(for: region)
        let strips = [
            CGRect(x: 0, y: 0, width: bounds.width, height: hole.minY),
            CGRect(x: 0, y: hole.maxY, width: bounds.width, height: bounds.height - hole.maxY),
            CGRect(x: 0, y: hole.minY, width: hole.minX, height: hole.height),
            CGRect(x: hole.maxX, y: hole.minY, width: bounds.width - hole.maxX, height: hole.height)
        ]

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (shade, strip) in zip(shades, strips) { shade.frame = strip }
        // Keep annotation coordinates fixed to the screenshot while moving the clip.
        annotationClip.position = CGPoint(x: hole.midX, y: hole.midY)
        annotationClip.bounds = hole
        outline.isHidden = hole.isEmpty
        border.isHidden = hole.isEmpty
        if !hole.isEmpty {
            outline.frame = hole.insetBy(dx: -1.5, dy: -1.5)
            border.frame = hole.insetBy(dx: -0.5, dy: -0.5)
        }
        for (layer, handle) in zip(handles, ResizeHandle.all) {
            layer.isHidden = !showHandles || hole.isEmpty
            if !layer.isHidden {
                let point = handle.point(in: region)
                layer.position = CGPoint(x: point.x, y: bounds.height - point.y)
            }
        }
    }

    func updateMarkup() {
        guard let markup = markupForDisplay?() else { return }
        let markupBounds = markup.committed.reduce(markup.draft?.drawingBounds ?? .null) { $0.union($1.drawingBounds) }
            .integral.intersection(bounds)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if markupBounds.isEmpty {
            annotations.isHidden = true
            annotations.contents = nil
        } else {
            annotations.isHidden = false
            annotations.frame = layerRect(for: markupBounds)
            annotations.contentsScale = window?.backingScaleFactor ?? 1
            annotations.setNeedsDisplay()
        }
    }

    func updateTextBox(_ rect: CGRect?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textBox.isHidden = rect == nil
        if let rect { textBox.frame = layerRect(for: rect) }
        CATransaction.commit()
    }

    func draw(_ layer: CALayer, in context: CGContext) {
        guard let markup = markupForDisplay?() else { return }
        context.translateBy(x: -layer.frame.minX, y: bounds.height - layer.frame.minY)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for annotation in markup.committed { annotation.draw(in: context) }
        markup.draft?.draw(in: context)
    }

    private func layerRect(for rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: bounds.height - rect.maxY, width: rect.width, height: rect.height)
    }
}
