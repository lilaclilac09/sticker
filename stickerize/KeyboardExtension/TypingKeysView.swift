import UIKit

/// Key styling shared by the typing layout and the sticker panel's bottom row.
@MainActor
enum KeyboardKey {
    static func make(title: String? = nil, systemImage: String? = nil, label: String? = nil, isFunction: Bool = true) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.title = title
        if let systemImage { configuration.image = UIImage(systemName: systemImage) }
        configuration.baseForegroundColor = .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 2)
        configuration.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = isFunction ? .systemFont(ofSize: 16) : .systemFont(ofSize: 22)
            return attributes
        }
        configuration.background.backgroundColor = isFunction ? functionKeyColor : characterKeyColor
        configuration.background.cornerRadius = 6
        let button = UIButton(configuration: configuration)
        button.configurationUpdateHandler = { button in
            button.configuration?.background.backgroundColor = button.isHighlighted
                ? (isFunction ? characterKeyColor : functionKeyColor)
                : (isFunction ? functionKeyColor : characterKeyColor)
        }
        button.layer.shadowColor = UIColor.black.cgColor
        button.layer.shadowOpacity = 0.25
        button.layer.shadowRadius = 0
        button.layer.shadowOffset = CGSize(width: 0, height: 1)
        button.accessibilityLabel = label ?? title
        return button
    }

    /// Fires on touch down, then repeats while held (like the system delete key).
    static func makeRepeating(_ button: UIButton, action: @escaping @MainActor () -> Void) {
        let repeater = KeyRepeater(action: action)
        button.addAction(UIAction { _ in repeater.start() }, for: .touchDown)
        for event: UIControl.Event in [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit] {
            button.addAction(UIAction { _ in repeater.stop() }, for: event)
        }
    }

    static let characterKeyColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white
    }
    static let functionKeyColor = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.27, alpha: 1) : UIColor(red: 0.67, green: 0.70, blue: 0.74, alpha: 1)
    }
}

@MainActor
private final class KeyRepeater {
    private let action: @MainActor () -> Void
    private var timer: Timer?

    init(action: @escaping @MainActor () -> Void) { self.action = action }

    func start() {
        action()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                    MainActor.assumeIsolated { self?.action() }
                }
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

/// A plain QWERTY / numbers layout so the keyboard types without Full Access.
final class TypingKeysView: UIView {
    var onText: ((String) -> Void)?
    var onDelete: (() -> Void)?
    var onStickers: (() -> Void)?
    /// Provided by the controller so it can hide it when the system shows its own globe key.
    var globeButton: UIButton? { didSet { rebuild() } }
    var returnKeyTitle = String(localized: "return") {
        didSet {
            returnButton?.configuration?.title = returnKeyTitle
            returnButton?.accessibilityLabel = returnKeyTitle
        }
    }

    private enum Page { case letters, numbers, symbols }
    private enum Key {
        case character(String)
        case shift, delete, page(Page), space, returnKey, stickers, globe
    }

    private var page = Page.letters { didSet { rebuild() } }
    private var shifted = false { didSet { updateShift() } }
    private var rows: [[(key: Key, button: UIButton, weight: CGFloat)]] = []
    private weak var returnButton: UIButton?

    override init(frame: CGRect) {
        super.init(frame: frame)
        rebuild()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func layout(for page: Page) -> [[(Key, CGFloat)]] {
        func characters(_ text: String) -> [(Key, CGFloat)] { text.map { (.character(String($0)), 1) } }
        let bottom: [(Key, CGFloat)] = [
            (.page(page == .letters ? .numbers : .letters), 1.25), (.stickers, 1.25), (.globe, 1.25),
            (.space, 4.5), (.returnKey, 1.75),
        ]
        switch page {
        case .letters:
            return [characters("qwertyuiop"), characters("asdfghjkl"),
                    [(.shift, 1.5)] + characters("zxcvbnm") + [(.delete, 1.5)], bottom]
        case .numbers:
            return [characters("1234567890"), characters("-/:;()$&@\""),
                    [(.page(.symbols), 1.5)] + characters(".,?!'") + [(.delete, 1.5)], bottom]
        case .symbols:
            return [characters("[]{}#%^*+="), characters("_\\|~<>€£¥•"),
                    [(.page(.numbers), 1.5)] + characters(".,?!'") + [(.delete, 1.5)], bottom]
        }
    }

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        rows = layout(for: page).map { row in
            row.map { key, weight in (key, button(for: key), weight) }
        }
        rows.flatMap { $0 }.forEach { addSubview($0.button) }
        updateShift()
        setNeedsLayout()
    }

    private func button(for key: Key) -> UIButton {
        switch key {
        case let .character(text):
            let button = KeyboardKey.make(title: text, isFunction: false)
            button.addAction(UIAction { [weak self] _ in self?.type(text) }, for: .touchUpInside)
            return button
        case .shift:
            let button = KeyboardKey.make(systemImage: "shift", label: String(localized: "Shift"))
            button.addAction(UIAction { [weak self] _ in self?.shifted.toggle() }, for: .touchUpInside)
            return button
        case .delete:
            let button = KeyboardKey.make(systemImage: "delete.left", label: String(localized: "Delete"))
            KeyboardKey.makeRepeating(button) { [weak self] in self?.onDelete?() }
            return button
        case let .page(target):
            let title = switch target {
            case .letters: "ABC"
            case .numbers: "123"
            case .symbols: "#+="
            }
            let button = KeyboardKey.make(title: title)
            button.addAction(UIAction { [weak self] _ in self?.page = target }, for: .touchUpInside)
            return button
        case .space:
            let button = KeyboardKey.make(title: String(localized: "space"), isFunction: false)
            button.configuration?.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
                var attributes = attributes
                attributes.font = .systemFont(ofSize: 16)
                return attributes
            }
            button.addAction(UIAction { [weak self] _ in self?.onText?(" ") }, for: .touchUpInside)
            return button
        case .returnKey:
            let button = KeyboardKey.make(title: returnKeyTitle)
            button.addAction(UIAction { [weak self] _ in self?.onText?("\n") }, for: .touchUpInside)
            returnButton = button
            return button
        case .stickers:
            let button = KeyboardKey.make(systemImage: "face.smiling", label: String(localized: "Stickers"))
            button.addAction(UIAction { [weak self] _ in self?.onStickers?() }, for: .touchUpInside)
            return button
        case .globe:
            return globeButton ?? UIButton()
        }
    }

    private func type(_ text: String) {
        UIDevice.current.playInputClick()
        onText?(shifted ? text.uppercased() : text)
        if shifted { shifted = false }
    }

    private func updateShift() {
        for row in rows {
            for entry in row {
                switch entry.key {
                case let .character(text) where page == .letters:
                    let shown = shifted ? text.uppercased() : text
                    entry.button.configuration?.title = shown
                    entry.button.accessibilityLabel = shown
                case .shift:
                    entry.button.configuration?.image = UIImage(systemName: shifted ? "shift.fill" : "shift")
                default:
                    break
                }
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let spacing: CGFloat = 6
        let rowGap: CGFloat = 10
        let insets = UIEdgeInsets(top: 8, left: 3, bottom: 4, right: 3)
        let area = bounds.inset(by: insets)
        let rowHeight = (area.height - rowGap * CGFloat(rows.count - 1)) / CGFloat(max(rows.count, 1))
        // Letter keys share one width across rows (from the 10-key top row); shorter rows are centred.
        let unit = (area.width - spacing * 9) / 10
        for (index, row) in rows.enumerated() {
            let visible = row.filter { !$0.button.isHidden }
            let isBottomRow = index == rows.count - 1
            var rowWidth = visible.reduce(0) { $0 + $1.weight * unit } + spacing * CGFloat(visible.count - 1)
            var scale: CGFloat = 1
            if isBottomRow || rowWidth > area.width {
                // The bottom row stretches to the full width (it shrinks when the globe key is hidden).
                scale = (area.width - spacing * CGFloat(visible.count - 1)) / (rowWidth - spacing * CGFloat(visible.count - 1))
                rowWidth = area.width
            }
            var x = area.minX + (area.width - rowWidth) / 2
            let y = area.minY + CGFloat(index) * (rowHeight + rowGap)
            for entry in visible {
                let width = entry.weight * unit * scale
                entry.button.frame = CGRect(x: x, y: y, width: width, height: rowHeight)
                x += width + spacing
            }
        }
    }
}
