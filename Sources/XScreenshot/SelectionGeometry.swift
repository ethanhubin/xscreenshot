import CoreGraphics

extension CGRect {
    static func spanning(_ start: CGPoint, _ end: CGPoint) -> CGRect {
        CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
               width: abs(start.x - end.x), height: abs(start.y - end.y))
    }

    func clamping(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, minX), maxX), y: min(max(point.y, minY), maxY))
    }

    func moved(from start: CGPoint, to end: CGPoint, within bounds: CGRect) -> CGRect {
        let x = min(max(minX + end.x - start.x, bounds.minX), bounds.maxX - width)
        let y = min(max(minY + end.y - start.y, bounds.minY), bounds.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

struct ResizeHandle {
    let x: CGFloat
    let y: CGFloat

    static let all: [ResizeHandle] = [
        .init(x: 0, y: 0), .init(x: 0.5, y: 0), .init(x: 1, y: 0),
        .init(x: 0, y: 0.5), .init(x: 1, y: 0.5),
        .init(x: 0, y: 1), .init(x: 0.5, y: 1), .init(x: 1, y: 1)
    ]

    func point(in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
    }

    func resize(_ rect: CGRect, from start: CGPoint, to end: CGPoint, within bounds: CGRect) -> CGRect {
        let point = self.point(in: rect)
        let proposed = bounds.clamping(CGPoint(x: point.x + end.x - start.x, y: point.y + end.y - start.y))
        let minX = x == 0 ? min(proposed.x, rect.maxX - 2) : rect.minX
        let maxX = x == 1 ? max(proposed.x, rect.minX + 2) : rect.maxX
        let minY = y == 0 ? min(proposed.y, rect.maxY - 2) : rect.minY
        let maxY = y == 1 ? max(proposed.y, rect.minY + 2) : rect.maxY
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
