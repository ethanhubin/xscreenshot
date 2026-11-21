import AppKit
import QuartzCore

@MainActor
final class SelectionPreview: NSView, @preconcurrency CALayerDelegate {
    var markupForDisplay: (() -> (committed: [Markup], draft: Markup?))?

    private static let resolutionFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
    private let snapshot: DisplaySnapshot
    private let scene = CALayer()
    private let shades = (0..<4).map { _ in CALayer() }
    private let annotationClip = CALayer()
    private let annotations = CALayer()
    private let markupOutline = CAShapeLayer()
    private let outline = CALayer()
    private let border = CALayer()
    private let textBox = CALayer()
    private let resolutionBadge = CALayer()
    private let resolutionText = CATextLayer()
    private let handles = ResizeHandle.all.map { _ in CALayer() }
    private let markupHandles = (0..<4).map { _ in CALayer() }
    private var renderedRegion: CGRect?
    private var renderedHandles = false
    private var renderedMarkupOffset = CGPoint.zero
    private var displayedPixelSize = CGSize.zero

    init(snapshot: DisplaySnapshot) {
        self.snapshot = snapshot
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
        markupOutline.fillColor = nil
        markupOutline.strokeColor = NSColor.controlAccentColor.cgColor
        markupOutline.lineWidth = 1.5
        markupOutline.lineDashPattern = [4, 3]
        markupOutline.shadowColor = CGColor(gray: 0, alpha: 1)
        markupOutline.shadowOpacity = 0.8
        markupOutline.shadowOffset = .zero
        markupOutline.shadowRadius = 1
        annotationClip.addSublayer(markupOutline)
        scene.addSublayer(annotationClip)

        outline.borderColor = CGColor(gray: 0, alpha: 0.65)
        outline.borderWidth = 1
        border.borderColor = NSColor.systemBlue.cgColor
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
        for handle in markupHandles {
            handle.isHidden = true
            handle.bounds.size = CGSize(width: 9, height: 9)
            handle.backgroundColor = CGColor.white
            handle.borderColor = NSColor.controlAccentColor.cgColor
            handle.borderWidth = 2
            handle.cornerRadius = 2.5
            scene.addSublayer(handle)
        }
        resolutionBadge.isHidden = true
        resolutionBadge.backgroundColor = NSColor(srgbRed: 0.16, green: 0.17, blue: 0.19, alpha: 0.94).cgColor
        resolutionBadge.cornerRadius = 5
        resolutionText.alignmentMode = .center
        resolutionBadge.addSublayer(resolutionText)
        scene.addSublayer(resolutionBadge)

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
        resolutionText.contentsScale = window?.backingScaleFactor ?? 1
        updateMarkup()
    }

    var resolutionFrame: CGRect {
        resolutionBadge.isHidden ? .null : layerRect(for: resolutionBadge.frame)
    }

    func updateRegion(_ region: CGRect, showHandles: Bool, markupOffset: CGPoint = .zero) {
        guard renderedRegion != region || renderedHandles != showHandles ||
                renderedMarkupOffset != markupOffset else { return }
        renderedRegion = region
        renderedHandles = showHandles
        renderedMarkupOffset = markupOffset

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
        annotationClip.position = CGPoint(x: hole.midX, y: hole.midY)
        annotationClip.bounds = hole
        // Translate the existing raster during a drag. Commit the new coordinates when it ends.
        annotationClip.sublayerTransform = CATransform3DMakeTranslation(markupOffset.x, -markupOffset.y, 0)
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
        updateResolution(for: region)
    }

    private func updateResolution(for region: CGRect) {
        let pixels = snapshot.pixelRect(for: region)
        resolutionBadge.isHidden = region.isEmpty || pixels.isEmpty
        guard !resolutionBadge.isHidden else { return }

        if displayedPixelSize != pixels.size {
            displayedPixelSize = pixels.size
            let text = "\(Int(pixels.width)) × \(Int(pixels.height))"
            let title = NSAttributedString(string: text, attributes: [
                .font: Self.resolutionFont, .foregroundColor: NSColor.white
            ])
            let textSize = title.size()
            resolutionText.contentsScale = window?.backingScaleFactor ?? 1
            resolutionText.string = title
            resolutionText.frame = CGRect(x: 8, y: 4, width: ceil(textSize.width), height: ceil(textSize.height))
            resolutionBadge.bounds.size = CGSize(width: resolutionText.frame.width + 16,
                                                height: resolutionText.frame.height + 8)
        }

        let size = resolutionBadge.bounds.size
        let x = max(bounds.minX, min(region.minX, bounds.maxX - size.width))
        let y = max(bounds.minY + 4, region.minY - size.height - 7)
        resolutionBadge.frame = layerRect(for: CGRect(origin: CGPoint(x: x, y: y), size: size))
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

    func updateTextBox(_ rect: CGRect?, animated: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let opacity = #keyPath(CALayer.opacity)
        textBox.removeAnimation(forKey: opacity)
        textBox.isHidden = rect == nil
        textBox.opacity = animated ? 0 : 1
        guard let rect else { return }
        textBox.frame = layerRect(for: rect)
        guard animated else { return }

        let highlight = CAKeyframeAnimation(keyPath: opacity)
        highlight.values = [0.0, 0.44, 0.0]
        highlight.keyTimes = [0, 0.24, 1]
        highlight.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        highlight.duration = 0.7
        textBox.add(highlight, forKey: opacity)
    }

    func updateMarkupSelection(_ path: CGPath?, handles: [CGPoint]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height)
        let outline = path?.copy(using: &transform)
        if let outline {
            let frame = outline.boundingBoxOfPath.insetBy(dx: -4, dy: -4).integral
            markupOutline.bounds = frame
            markupOutline.position = CGPoint(x: frame.midX, y: frame.midY)
        }
        markupOutline.path = outline
        for (index, layer) in markupHandles.enumerated() {
            layer.isHidden = index >= handles.count
            if !layer.isHidden { layer.position = handles[index].applying(transform) }
        }
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
