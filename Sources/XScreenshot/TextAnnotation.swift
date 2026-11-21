import AppKit
import CoreText

@MainActor
struct TextLayout {
    nonisolated static let defaultFontSize: CGFloat = 22
    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineBreakMode = .byWordWrapping
        return style
    }()

    private let storage: NSTextStorage
    private let manager = NSLayoutManager()
    private let container = NSTextContainer()

    init(_ text: String, fontSize: CGFloat, color: NSColor, width: CGFloat?) {
        storage = NSTextStorage(string: text, attributes: [
            .font: Self.font(size: fontSize), .foregroundColor: color, .paragraphStyle: Self.paragraphStyle
        ])
        Self.configure(container, width: width)
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
    }

    static func font(size: CGFloat) -> NSFont {
        .systemFont(ofSize: size, weight: .semibold)
    }

    static func configure(_ container: NSTextContainer, width: CGFloat?) {
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        if let width { container.size.width = width }
    }

    var bounds: CGRect {
        manager.ensureLayout(for: container)
        return manager.usedRect(for: container)
    }

    func draw(at point: CGPoint) {
        manager.drawGlyphs(forGlyphRange: manager.glyphRange(for: container), at: point)
    }

    static func fittingFontSize(for text: String, in size: CGSize) -> CGFloat {
        let layout = TextLayout(text.isEmpty ? "X" : text, fontSize: 1, color: .black, width: size.width)
        let range = NSRange(location: 0, length: layout.storage.length)
        var smallest: CGFloat = 1
        var largest = floor(text.isEmpty ? min(defaultFontSize, size.height) : size.height)
        while smallest < largest {
            let candidate = floor((smallest + largest + 1) / 2)
            layout.storage.addAttribute(.font, value: Self.font(size: candidate), range: range)
            if layout.fits(in: size) {
                smallest = candidate
            } else {
                largest = candidate - 1
            }
        }
        return smallest
    }

    private func fits(in size: CGSize) -> Bool {
        let used = bounds
        guard used.maxY <= size.height else { return false }
        if used.maxX < size.width { return true }

        // TextKit reports the container width even when a single glyph is wider.
        let framesetter = CTFramesetterCreateWithAttributedString(storage)
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(), nil, CGSize(width: size.width, height: .greatestFiniteMagnitude), nil
        )
        return measured.width <= size.width
    }
}

@MainActor
final class TextAnnotationEditor: NSTextView {
    private static let boxPadding: CGFloat = 3

    let box: CGRect?
    var onFinish: ((Bool) -> Void)?
    var markupColor: MarkupColor {
        didSet { textColor = markupColor.color }
    }
    private let storage: NSTextStorage
    private let textBoxSize: CGSize?

    init(at point: CGPoint, in box: CGRect?, color: MarkupColor, text: String = "",
         fontSize: CGFloat = TextLayout.defaultFontSize) {
        let padding = box == nil ? 2 : Self.boxPadding
        self.box = box
        markupColor = color
        textBoxSize = box?.insetBy(dx: padding, dy: padding).size
        let origin = CGPoint(x: point.x - padding, y: point.y - padding)
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        self.storage = storage
        super.init(frame: box ?? CGRect(origin: origin, size: CGSize(width: 28, height: 28)),
                   textContainer: container)
        drawsBackground = false
        focusRingType = .none
        clipsToBounds = true
        isRichText = false
        allowsUndo = true
        textContainerInset = CGSize(width: padding, height: padding)
        isHorizontallyResizable = box == nil
        isVerticallyResizable = box == nil
        if box == nil { minSize = CGSize(width: 28, height: 0) }
        TextLayout.configure(container, width: textBoxSize?.width)
        defaultParagraphStyle = TextLayout.paragraphStyle
        string = text
        font = TextLayout.font(size: fontSize)
        textColor = color.color
        insertionPointColor = .controlAccentColor
        typingAttributes[.paragraphStyle] = TextLayout.paragraphStyle
        setAccessibilityLabel("截图文字")
        if text.isEmpty { fitFont() }
        setSelectedRange(NSRange(location: text.utf16.count, length: 0))
    }

    convenience init(editing annotation: Markup, at origin: CGPoint) {
        let box = annotation.textBoxSize.map {
            CGRect(origin: origin, size: $0).insetBy(dx: -Self.boxPadding, dy: -Self.boxPadding)
        }
        self.init(at: origin, in: box, color: annotation.color, text: annotation.text, fontSize: annotation.fontSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var annotation: Markup? {
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let origin = convert(textContainerOrigin, to: superview)
        return Markup(tool: .text, color: markupColor, points: [origin], text: string,
                      fontSize: font?.pointSize ?? TextLayout.defaultFontSize, textBoxSize: textBoxSize)
    }

    override func didChangeText() {
        super.didChangeText()
        fitFont()
    }

    override func keyDown(with event: NSEvent) {
        guard !hasMarkedText() else {
            super.keyDown(with: event)
            return
        }
        switch event.charactersIgnoringModifiers {
        case "\r", "\n", "\u{3}":
            if event.modifierFlags.contains(.shift) {
                insertNewline(nil)
            } else {
                onFinish?(false)
            }
        case "\t" where event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty:
            onFinish?(false)
        case "\u{1B}":
            onFinish?(true)
        default:
            super.keyDown(with: event)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    func adjustFont(with event: NSEvent) {
        guard box == nil, event.momentumPhase.isEmpty, event.scrollingDeltaY != 0 else { return }
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 0.25 : 2
        let size = (font?.pointSize ?? TextLayout.defaultFontSize) + step * event.scrollingDeltaY
        setFontSize(min(max(size, 6), 144))
    }

    private func fitFont() {
        guard let textBoxSize, !hasMarkedText() else { return }
        setFontSize(TextLayout.fittingFontSize(for: string, in: textBoxSize))
    }

    private func setFontSize(_ size: CGFloat) {
        if font?.pointSize != size { font = TextLayout.font(size: size) }
    }
}
