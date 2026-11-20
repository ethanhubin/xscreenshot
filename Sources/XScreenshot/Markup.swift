import AppKit

enum EditorTool: CaseIterable {
    case select, pen, line, rectangle, ellipse, arrow, text

    var icon: String {
        switch self {
        case .select: "arrow.up.and.down.and.arrow.left.and.right"
        case .pen: "pencil.tip"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "oval"
        case .arrow: "arrow.up.right"
        case .text: "textformat"
        }
    }

    var title: String {
        switch self {
        case .select: "移动或缩放选区"
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

struct Markup {
    let tool: EditorTool
    let color: MarkupColor
    var points: [CGPoint]
    var text = ""

    @MainActor
    func draw(in context: CGContext) {
        guard let start = points.first, let end = points.last else { return }
        if tool == .text {
            (text as NSString).draw(at: start, withAttributes: [
                .foregroundColor: color.color,
                .font: NSFont.systemFont(ofSize: 22, weight: .semibold)
            ])
            return
        }

        context.saveGState()
        defer { context.restoreGState() }
        context.setStrokeColor(color.color.cgColor)
        context.setLineWidth(3)
        context.setLineCap(.round)
        context.setLineJoin(.round)

        switch tool {
        case .select, .text:
            return
        case .pen:
            context.addLines(between: points)
        case .rectangle:
            context.addRect(CGRect.spanning(start, end))
        case .ellipse:
            context.addEllipse(in: CGRect.spanning(start, end))
        case .line, .arrow:
            context.move(to: start)
            context.addLine(to: end)
            if tool == .arrow {
                let angle = atan2(end.y - start.y, end.x - start.x)
                let size = min(16, hypot(end.x - start.x, end.y - start.y) * 0.5)
                context.move(to: CGPoint(x: end.x - size * cos(angle - .pi / 6),
                                         y: end.y - size * sin(angle - .pi / 6)))
                context.addLine(to: end)
                context.addLine(to: CGPoint(x: end.x - size * cos(angle + .pi / 6),
                                            y: end.y - size * sin(angle + .pi / 6)))
            }
        }
        context.strokePath()
    }
}
