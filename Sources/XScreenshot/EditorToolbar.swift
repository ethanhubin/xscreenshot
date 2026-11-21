import AppKit
import QuartzCore

@MainActor
final class EditorToolbar: NSView {
    private static let buttonSide: CGFloat = 30
    private static let buttonSpacing: CGFloat = 4
    private static let panelInset: CGFloat = 7
    private static let panelGap: CGFloat = 6
    private static let panelRadius: CGFloat = 11
    private static let panelBackground = NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1).cgColor
    private static let panelBorder = NSColor.white.withAlphaComponent(0.18).cgColor
    private static let pencilImage: NSImage = {
        let image = NSImage(size: CGSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.translateBy(x: 2, y: 2)
            context.rotate(by: .pi / 4)
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setLineWidth(1.35)
            context.setLineJoin(.round)
            context.move(to: .zero)
            context.addLine(to: CGPoint(x: 4, y: 2.2))
            context.addLine(to: CGPoint(x: 18, y: 2.2))
            context.addQuadCurve(to: CGPoint(x: 20, y: 0), control: CGPoint(x: 20, y: 2.2))
            context.addQuadCurve(to: CGPoint(x: 18, y: -2.2), control: CGPoint(x: 20, y: -2.2))
            context.addLine(to: CGPoint(x: 4, y: -2.2))
            context.closePath()
            context.move(to: CGPoint(x: 16.2, y: 2.2))
            context.addLine(to: CGPoint(x: 16.2, y: -2.2))
            context.strokePath()
            return true
        }
        image.isTemplate = true
        return image
    }()

    var onTool: ((EditorTool) -> Void)?
    var onColor: ((MarkupColor) -> Void)?
    var onUndo: (() -> Void)?
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?

    private let toolPanel = NSView()
    private let palettePanel = NSView()
    private let paletteOutline = CAShapeLayer()
    private var toolButtons: [EditorTool: ToolbarButton] = [:]
    private var colorButtons: [MarkupColor: NSButton] = [:]
    private var undoButton: NSButton!

    init() {
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)

        let tools = NSStackView()
        tools.spacing = Self.buttonSpacing
        tools.distribution = .fillEqually
        for tool in EditorTool.allCases {
            let button = makeButton(tool.icon, title: tool.title, action: #selector(chooseTool(_:)))
            if tool == .pen { button.image = Self.pencilImage }
            switch tool {
            case .select: button.toolTip = "选择标注或调整选区（双击编辑文字，Delete 删除标注）"
            case .text: button.toolTip = "文本（单击已有文字编辑，单击空白处输入，拖拽创建文本框）"
            default: button.toolTip = "\(tool.title)（滚动鼠标滚轮调整粗细）"
            }
            button.setButtonType(.pushOnPushOff)
            toolButtons[tool] = button
            tools.addArrangedSubview(button)
        }

        undoButton = makeButton("arrow.uturn.backward", title: "撤销（⌘Z）", action: #selector(undo))
        tools.addArrangedSubview(undoButton)
        tools.addArrangedSubview(makeButton("xmark", title: "取消（Esc）", action: #selector(cancel)))
        let confirmButton = makeButton("checkmark", title: "确认并复制（↩）", action: #selector(confirm))
        confirmButton.restingColor = .controlAccentColor
        confirmButton.contentTintColor = .white
        tools.addArrangedSubview(confirmButton)

        let palette = NSStackView()
        palette.spacing = Self.buttonSpacing
        palette.distribution = .fillEqually
        for color in MarkupColor.allCases {
            let button = makeButton("circle.fill", title: color.title, action: #selector(chooseColor(_:)))
            button.contentTintColor = color.color
            button.layer?.borderWidth = 1
            colorButtons[color] = button
            palette.addArrangedSubview(button)
        }

        let toolSize = panelSize(for: tools)
        setFrameSize(toolSize)
        addPanel(toolPanel, row: tools, frame: CGRect(origin: .zero, size: toolSize))
        toolPanel.layer?.backgroundColor = Self.panelBackground
        toolPanel.layer?.cornerRadius = Self.panelRadius
        toolPanel.layer?.borderWidth = 1
        toolPanel.layer?.borderColor = Self.panelBorder

        let paletteOrigin = CGPoint(x: 0, y: toolSize.height + Self.panelGap)
        addPanel(palettePanel, row: palette, frame: CGRect(origin: paletteOrigin, size: panelSize(for: palette)))
        palettePanel.clipsToBounds = false
        palettePanel.layer?.masksToBounds = false
        paletteOutline.frame = palettePanel.bounds
        paletteOutline.fillColor = Self.panelBackground
        paletteOutline.strokeColor = Self.panelBorder
        palettePanel.layer?.insertSublayer(paletteOutline, at: 0)
        palettePanel.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var preferredSize: CGSize {
        CGSize(width: toolPanel.frame.width,
               height: palettePanel.isHidden ? toolPanel.frame.height : palettePanel.frame.maxY)
    }

    func containsPanel(at point: CGPoint) -> Bool {
        if toolPanel.frame.contains(point) { return true }
        guard !palettePanel.isHidden else { return false }
        return paletteOutline.path?.contains(convert(point, to: palettePanel)) == true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard containsPanel(at: convert(point, from: superview)) else { return nil }
        return super.hitTest(point)
    }

    func update(tool: EditorTool, color: MarkupColor, canUndo: Bool, showsPalette: Bool) {
        palettePanel.isHidden = !showsPalette
        if showsPalette, let button = toolButtons[tool] { positionPalette(for: button) }
        for (kind, button) in toolButtons {
            button.state = kind == tool ? .on : .off
            button.restingColor = kind == tool ? NSColor.white.withAlphaComponent(0.17) : nil
        }
        for (kind, button) in colorButtons {
            button.layer?.borderColor = (kind == color ? NSColor.white : NSColor.clear).cgColor
        }
        undoButton.isEnabled = canUndo
    }

    private func positionPalette(for button: ToolbarButton) {
        toolPanel.layoutSubtreeIfNeeded()
        func centerX(of button: ToolbarButton) -> CGFloat {
            button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: self).x
        }
        let centers = toolButtons.values.map { centerX(of: $0) }
        guard let first = centers.min(), let last = centers.max() else { return }
        let anchor = centerX(of: button)
        let fraction = (anchor - first) / max(1, last - first)
        let x = (fraction * max(0, bounds.width - palettePanel.bounds.width)).rounded()
        palettePanel.frame.origin.x = x
        updatePaletteOutline(pointerX: anchor - x)
    }

    private func updatePaletteOutline(pointerX: CGFloat) {
        let body = palettePanel.bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = Self.panelRadius
        let halfWidth: CGFloat = 6
        let left = body.minX
        let right = body.maxX
        let top = body.maxY
        let bottom = body.minY
        let tip = max(left + radius + halfWidth, min(pointerX, right - radius - halfWidth))

        let path = CGMutablePath()
        path.move(to: CGPoint(x: left + radius, y: top))
        path.addLine(to: CGPoint(x: tip - halfWidth, y: top))
        path.addLine(to: CGPoint(x: tip, y: top + 5))
        path.addLine(to: CGPoint(x: tip + halfWidth, y: top))
        path.addArc(tangent1End: CGPoint(x: right, y: top), tangent2End: CGPoint(x: right, y: bottom), radius: radius)
        path.addArc(tangent1End: CGPoint(x: right, y: bottom), tangent2End: CGPoint(x: left, y: bottom), radius: radius)
        path.addArc(tangent1End: CGPoint(x: left, y: bottom), tangent2End: CGPoint(x: left, y: top), radius: radius)
        path.addArc(tangent1End: CGPoint(x: left, y: top), tangent2End: CGPoint(x: right, y: top), radius: radius)
        path.closeSubpath()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        paletteOutline.path = path
        CATransaction.commit()
    }

    private func panelSize(for row: NSStackView) -> CGSize {
        let count = CGFloat(row.arrangedSubviews.count)
        let width = count * Self.buttonSide + (count - 1) * Self.buttonSpacing
        return CGSize(width: width + 2 * Self.panelInset, height: Self.buttonSide + 2 * Self.panelInset)
    }

    private func addPanel(_ panel: NSView, row: NSStackView, frame: CGRect) {
        panel.frame = frame
        panel.wantsLayer = true
        addSubview(panel)
        row.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(row)
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: frame.width - 2 * Self.panelInset),
            row.centerXAnchor.constraint(equalTo: panel.centerXAnchor),
            row.centerYAnchor.constraint(equalTo: panel.centerYAnchor)
        ])
    }

    private func makeButton(_ icon: String, title: String, action: Selector) -> ToolbarButton {
        let image = NSImage(systemSymbolName: icon, accessibilityDescription: title) ?? NSImage()
        let button = ToolbarButton(image: image, target: self, action: action)
        button.isBordered = false
        button.focusRingType = .none
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.heightAnchor.constraint(equalTo: button.widthAnchor).isActive = true
        return button
    }

    @objc private func chooseTool(_ button: NSButton) {
        if let tool = toolButtons.first(where: { $0.value === button })?.key { onTool?(tool) }
    }

    @objc private func chooseColor(_ button: NSButton) {
        if let color = colorButtons.first(where: { $0.value === button })?.key { onColor?(color) }
    }

    @objc private func undo() { onUndo?() }
    @objc private func cancel() { onCancel?() }
    @objc private func confirm() { onConfirm?() }
}

@MainActor
private final class ToolbarButton: NSButton {
    var restingColor: NSColor? { didSet { updateBackground() } }
    private var isHovered = false { didSet { updateBackground() } }
    private var hoverArea: NSTrackingArea?

    override var alignmentRectInsets: NSEdgeInsets { NSEdgeInsets() }
    override var isEnabled: Bool { didSet { updateBackground() } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.inVisibleRect, .activeInKeyWindow, .mouseEnteredAndExited],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        if let window, window.isKeyWindow {
            let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            isHovered = !isHiddenOrHasHiddenAncestor && bounds.contains(point)
        }
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
    }

    private func updateBackground() {
        let color = isHovered && isEnabled
            ? restingColor?.blended(withFraction: 0.14, of: .white) ?? NSColor.white.withAlphaComponent(0.14)
            : restingColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = color?.cgColor
        CATransaction.commit()
    }
}
