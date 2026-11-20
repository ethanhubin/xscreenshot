import AppKit

@MainActor
final class EditorToolbar: NSView {
    static let preferredSize = CGSize(width: 350, height: 72)

    var onTool: ((EditorTool) -> Void)?
    var onColor: ((MarkupColor) -> Void)?
    var onUndo: (() -> Void)?
    var onCancel: (() -> Void)?
    var onConfirm: (() -> Void)?

    private var toolButtons: [EditorTool: NSButton] = [:]
    private var colorButtons: [MarkupColor: NSButton] = [:]
    private var undoButton: NSButton!

    init() {
        super.init(frame: CGRect(origin: .zero, size: Self.preferredSize))
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0.10, green: 0.11, blue: 0.13, alpha: 1).cgColor
        layer?.cornerRadius = 11
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        let tools = NSStackView()
        tools.spacing = 3
        for tool in EditorTool.allCases {
            let button = makeButton(tool.icon, title: tool.title, action: #selector(chooseTool(_:)))
            button.setButtonType(.pushOnPushOff)
            toolButtons[tool] = button
            tools.addArrangedSubview(button)
        }

        undoButton = makeButton("arrow.uturn.backward", title: "撤销（⌘Z）", action: #selector(undo))
        tools.addArrangedSubview(undoButton)
        tools.addArrangedSubview(makeButton("xmark", title: "取消（Esc）", action: #selector(cancel)))
        let confirmButton = makeButton("checkmark", title: "确认并复制（↩）", action: #selector(confirm))
        confirmButton.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        confirmButton.contentTintColor = .white
        tools.addArrangedSubview(confirmButton)

        let palette = NSStackView()
        palette.spacing = 4
        let paletteLabel = NSTextField(labelWithString: "标注颜色")
        paletteLabel.font = .systemFont(ofSize: 11)
        paletteLabel.textColor = .secondaryLabelColor
        palette.addArrangedSubview(paletteLabel)
        for color in MarkupColor.allCases {
            let button = makeButton("circle.fill", title: color.title, width: 23, height: 22,
                                    action: #selector(chooseColor(_:)))
            button.contentTintColor = color.color
            button.layer?.borderWidth = 1
            colorButtons[color] = button
            palette.addArrangedSubview(button)
        }

        let rows = NSStackView(views: [tools, palette])
        rows.orientation = .vertical
        rows.alignment = .centerX
        rows.spacing = 4
        rows.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rows)
        NSLayoutConstraint.activate([
            rows.centerXAnchor.constraint(equalTo: centerXAnchor),
            rows.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(tool: EditorTool, color: MarkupColor, canUndo: Bool) {
        for (kind, button) in toolButtons {
            button.state = kind == tool ? .on : .off
            button.layer?.backgroundColor = kind == tool ? NSColor.white.withAlphaComponent(0.17).cgColor : nil
        }
        for (kind, button) in colorButtons {
            button.layer?.borderColor = (kind == color ? NSColor.white : NSColor.clear).cgColor
        }
        undoButton.isEnabled = canUndo
    }

    private func makeButton(_ icon: String, title: String, width: CGFloat = 30, height: CGFloat = 29,
                            action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: icon, accessibilityDescription: title) ?? NSImage(),
                              target: self, action: action)
        button.isBordered = false
        button.focusRingType = .none
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.widthAnchor.constraint(equalToConstant: width).isActive = true
        button.heightAnchor.constraint(equalToConstant: height).isActive = true
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
