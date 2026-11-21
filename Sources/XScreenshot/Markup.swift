import AppKit

enum EditorTool: CaseIterable {
    case select, pen, line, rectangle, ellipse, arrow, text

    var drawsStroke: Bool {
        self != .select && self != .text
    }

    var icon: String {
        switch self {
        case .select: "arrow.up.and.down.and.arrow.left.and.right"
        case .pen: "pencil"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "oval"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        }
    }

    var title: String {
        switch self {
        case .select: "选择标注或调整选区"
        case .pen: "画笔"
        case .line: "直线"
        case .rectangle: "矩形"
        case .ellipse: "椭圆"
        case .arrow: "箭头"
        case .text: "文本"
        }
    }
}

enum MarkupColor: CaseIterable {
    case red, yellow, green, blue, white, black

    var color: NSColor {
        switch self {
        case .red: NSColor(srgbRed: 1, green: 0.24, blue: 0.26, alpha: 1)
        case .yellow: NSColor(srgbRed: 1, green: 0.78, blue: 0.23, alpha: 1)
        case .green: NSColor(srgbRed: 0.28, green: 0.83, blue: 0.47, alpha: 1)
        case .blue: NSColor(srgbRed: 0.26, green: 0.62, blue: 1, alpha: 1)
        case .white: .white
        case .black: .black
        }
    }

    var title: String {
        switch self {
        case .red: "红色"
        case .yellow: "黄色"
        case .green: "绿色"
        case .blue: "蓝色"
        case .white: "白色"
        case .black: "黑色"
        }
    }
}

struct Markup: Equatable {
    enum Handle {
        case endpoint(Int)
        case corner(ResizeHandle)
    }

    enum Hit {
        case content
        case interior
    }

    static let defaultLineWidth: CGFloat = 3

    let tool: EditorTool
    var color: MarkupColor
    var points: [CGPoint]
    var lineWidth = Markup.defaultLineWidth
    var text = ""
    var fontSize = TextLayout.defaultFontSize
    var textBoxSize: CGSize?

    @MainActor
    var drawingBounds: CGRect {
        guard tool == .text else {
            let padding = lineWidth / 2 + 0.5
            return strokePath?.boundingBoxOfPath.insetBy(dx: -padding, dy: -padding) ?? .null
        }
        guard let start = points.first else { return .null }
        if let resizeBounds { return resizeBounds }
        let padding = max(2, fontSize / 8)
        return textLayout.bounds.offsetBy(dx: start.x, dy: start.y).insetBy(dx: -padding, dy: -padding)
    }

    @MainActor
    var selectionPath: CGPath? {
        if tool == .line || tool == .arrow { return strokePath }
        let rect = resizeBounds ?? drawingBounds
        guard !rect.isNull else { return nil }
        return CGPath(rect: rect, transform: nil)
    }

    var handles: [(handle: Handle, position: CGPoint)] {
        if tool == .line || tool == .arrow {
            guard let first = points.first, let last = points.indices.last, last > 0 else { return [] }
            return [(.endpoint(0), first), (.endpoint(last), points[last])]
        }
        guard let rect = resizeBounds, rect.width > 0 || rect.height > 0 else { return [] }
        let handles = ResizeHandle.all.filter { handle in
            if rect.width == 0 { return handle.x == 0.5 }
            if rect.height == 0 { return handle.y == 0.5 }
            return handle.x != 0.5 && handle.y != 0.5
        }
        return handles.map { (.corner($0), $0.point(in: rect)) }
    }

    @MainActor
    func hitTest(_ point: CGPoint) -> Hit? {
        if tool == .text {
            return drawingBounds.insetBy(dx: -4, dy: -4).contains(point) ? .content : nil
        }
        guard let path = strokePath else { return nil }
        let hitWidth = lineWidth + 14
        let padding = -hitWidth / 2
        guard path.boundingBoxOfPath.insetBy(dx: padding, dy: padding).contains(point) else { return nil }
        let stroke = path.copy(strokingWithWidth: hitWidth, lineCap: .round, lineJoin: .round, miterLimit: 1)
        if stroke.contains(point) { return .content }
        if tool == .rectangle || tool == .ellipse, path.contains(point) { return .interior }
        return nil
    }

    func offsetBy(dx: CGFloat, dy: CGFloat) -> Markup {
        var result = self
        result.points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        return result
    }

    @MainActor
    func moved(from start: CGPoint, to end: CGPoint, within bounds: CGRect) -> Markup {
        guard start != end else { return self }
        let frame = drawingBounds
        guard !frame.isNull else { return self }
        let leading = CGPoint(x: bounds.minX - frame.minX, y: bounds.minY - frame.minY)
        let trailing = CGPoint(x: bounds.maxX - frame.maxX, y: bounds.maxY - frame.maxY)
        // A mark already clipped by the crop can move without jumping into it.
        let limits = CGRect.spanning(leading, trailing).union(.zero)
        let delta = limits.clamping(CGPoint(x: end.x - start.x, y: end.y - start.y))
        return offsetBy(dx: delta.x, dy: delta.y)
    }

    @MainActor
    func resized(by handle: Handle, from start: CGPoint, to end: CGPoint, within bounds: CGRect) -> Markup {
        guard start != end else { return self }
        var result = self
        switch handle {
        case let .endpoint(index):
            let point = points[index]
            let target = bounds.clamping(CGPoint(x: point.x + end.x - start.x, y: point.y + end.y - start.y))
            let anchor = points[index == 0 ? points.count - 1 : 0]
            if hypot(target.x - anchor.x, target.y - anchor.y) >= 1 { result.points[index] = target }
        case let .corner(handle):
            guard let rect = resizeBounds else { return self }
            let resized = handle.resize(rect, from: start, to: end, within: bounds)
            guard resized != rect else { return self }
            if tool == .text {
                result.points = [resized.origin]
                result.textBoxSize = resized.size
                result.fontSize = TextLayout.fittingFontSize(for: text, in: resized.size)
            } else {
                let scaleX = rect.width == 0 ? 1 : resized.width / rect.width
                let scaleY = rect.height == 0 ? 1 : resized.height / rect.height
                result.points = points.map {
                    CGPoint(x: resized.minX + ($0.x - rect.minX) * scaleX,
                            y: resized.minY + ($0.y - rect.minY) * scaleY)
                }
            }
        }
        return result
    }

    private var resizeBounds: CGRect? {
        guard let start = points.first else { return nil }
        switch tool {
        case .pen, .rectangle, .ellipse:
            return points.dropFirst().reduce(CGRect(origin: start, size: .zero)) {
                $0.union(CGRect(origin: $1, size: .zero))
            }
        case .text:
            return textBoxSize.map { CGRect(origin: start, size: $0) }
        default:
            return nil
        }
    }

    private var strokePath: CGPath? {
        guard let start = points.first, let end = points.last else { return nil }
        let path = CGMutablePath()
        switch tool {
        case .select, .text:
            return nil
        case .pen:
            path.addLines(between: points)
        case .rectangle:
            path.addRect(CGRect.spanning(start, end))
        case .ellipse:
            path.addEllipse(in: CGRect.spanning(start, end))
        case .line, .arrow:
            path.move(to: start)
            path.addLine(to: end)
            if tool == .arrow {
                let angle = atan2(end.y - start.y, end.x - start.x)
                let size = min(max(16, lineWidth * 3), hypot(end.x - start.x, end.y - start.y) * 0.5)
                path.move(to: CGPoint(x: end.x - size * cos(angle - .pi / 6),
                                      y: end.y - size * sin(angle - .pi / 6)))
                path.addLine(to: end)
                path.addLine(to: CGPoint(x: end.x - size * cos(angle + .pi / 6),
                                         y: end.y - size * sin(angle + .pi / 6)))
            }
        }
        return path
    }

    @MainActor
    private var textLayout: TextLayout {
        TextLayout(text, fontSize: fontSize, color: color.color, width: textBoxSize?.width)
    }

    @MainActor
    func draw(in context: CGContext) {
        if tool == .text {
            guard let start = points.first else { return }
            context.saveGState()
            defer { context.restoreGState() }
            if let textBoxSize { context.clip(to: CGRect(origin: start, size: textBoxSize)) }
            textLayout.draw(at: start)
            return
        }

        guard let path = strokePath else { return }
        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(color.color.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.addPath(path)
        context.strokePath()
    }
}
