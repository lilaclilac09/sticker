import StickerizeKit
import UIKit
import UniformTypeIdentifiers

/// Sticker keyboard for apps that don't host iMessage apps (WhatsApp, Telegram, Signal, Slack, Mail…).
///
/// Keyboards can only type text (UITextDocumentProxy has no image API), so tapping a sticker copies its PNG and the
/// user pastes it. Copying needs Full Access; without it the keyboard still shows the stickers (the App Group is
/// readable) and works as a basic typing keyboard, as App Review guideline 4.4.1 requires.
/// Memory is tight in keyboards (tens of MB), so it only decodes small thumbnails and never links Vision.
final class KeyboardViewController: UIInputViewController {
    private enum Mode { case stickers, typing }

    private let store = StickerStore.makeDefault()
    private var stickers: [Sticker] = []
    private var observer: StickerChangeObserver?
    private let thumbnails = NSCache<NSUUID, UIImage>()
    private var mode = Mode.stickers

    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    /// Centred over the grid when there are no stickers.
    private let messageLabel = UILabel()
    /// Above the grid when stickers exist but Full Access is off.
    private let bannerLabel = PaddedLabel()
    private let toastLabel = PaddedLabel()
    private let typingView = TypingKeysView()
    private let stickerPanel = UIView()
    private let globeButton = KeyboardKey.make(systemImage: "globe", label: String(localized: "Next keyboard"))
    private let stickerGlobeButton = KeyboardKey.make(systemImage: "globe", label: String(localized: "Next keyboard"))
    private var toastHideWork: DispatchWorkItem?
    private var heightConstraint: NSLayoutConstraint?

    override func loadView() {
        // A custom UIInputView so the system plays key clicks (when the user has them turned on).
        let view = ClickingInputView(frame: .zero, inputViewStyle: .keyboard)
        view.allowsSelfSizing = true
        // Clear, so hosts using the iOS 26+ glass keyboard background show through.
        view.backgroundColor = .clear
        self.view = view
        self.inputView = view
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        thumbnails.totalCostLimit = 12 * 1024 * 1024
        setUpViews()
        observer = store.observeChanges { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Full Access can change between appearances.
        reload()
    }

    override func viewWillLayoutSubviews() {
        // On Face ID iPhones the system shows its own globe key below the keyboard.
        globeButton.isHidden = !needsInputModeSwitchKey
        stickerGlobeButton.isHidden = !needsInputModeSwitchKey
        // Shorter in iPhone landscape, like the system keyboard, so the host keeps some of the screen. The window's
        // shape is checked too, in case the extension's size class doesn't change on rotation.
        let windowSize = view.window?.bounds.size ?? view.bounds.size
        let landscapePhone = traitCollection.userInterfaceIdiom == .phone && windowSize.width > windowSize.height
        heightConstraint?.constant = traitCollection.verticalSizeClass == .compact || landscapePhone ? 186 : 268
        super.viewWillLayoutSubviews()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        thumbnails.removeAllObjects()
    }

    override func didReceiveMemoryWarning() {
        super.didReceiveMemoryWarning()
        thumbnails.removeAllObjects()
    }

    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        typingView.returnKeyTitle = Self.returnTitle(for: textDocumentProxy.returnKeyType)
    }

    // MARK: Stickers

    private func reload() {
        // Read files directly: without Full Access the App Group is read-only and coordination isn't needed.
        stickers = (try? store.stickers(coordinated: false)) ?? []
        collectionView.reloadData()
        messageLabel.text = store.location == .local
            ? String(localized: "Stickerize can't reach its shared library. Open the app for details.")
            : String(localized: "No stickers yet. Open the Stickerize app to make some.")
        messageLabel.isHidden = !stickers.isEmpty
        bannerLabel.isHidden = stickers.isEmpty || hasFullAccess
    }

    private func copy(_ sticker: Sticker) {
        guard hasFullAccess else {
            showToast(String(localized: "Turn on Full Access in Settings to copy stickers."))
            return
        }
        guard let data = try? store.pasteboardPNG(for: sticker) else {
            showToast(String(localized: "That sticker is gone."))
            reload()
            return
        }
        // PNG bytes only: setting a UIImage would also publish a JPEG without alpha, and some apps prefer it.
        UIPasteboard.general.setItems([[UTType.png.identifier: data]], options: [.localOnly: true])
        UIDevice.current.playInputClick()
        showToast(String(localized: "Copied. Touch and hold the message field, then tap Paste."))
    }

    private func setMode(_ newMode: Mode) {
        mode = newMode
        stickerPanel.isHidden = newMode != .stickers
        typingView.isHidden = newMode != .typing
        if newMode == .stickers { reload() }
    }

    // MARK: Layout

    private func setUpViews() {
        guard let inputView else { return }

        collectionView.backgroundColor = .clear
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(StickerCell.self, forCellWithReuseIdentifier: StickerCell.reuseIdentifier)

        messageLabel.numberOfLines = 0
        messageLabel.textAlignment = .center
        messageLabel.font = .preferredFont(forTextStyle: .subheadline)
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.textColor = .secondaryLabel

        bannerLabel.text = String(localized: "To copy stickers, turn on Full Access in Settings › General › Keyboard › Keyboards › Stickerize. Stickerize doesn't send anything you type.")
        bannerLabel.font = .preferredFont(forTextStyle: .caption1)
        bannerLabel.adjustsFontForContentSizeCategory = true
        bannerLabel.numberOfLines = 0
        bannerLabel.textAlignment = .center
        bannerLabel.textColor = .label
        bannerLabel.backgroundColor = .secondarySystemBackground
        bannerLabel.layer.cornerRadius = 10
        bannerLabel.layer.masksToBounds = true
        bannerLabel.isHidden = true

        toastLabel.font = .preferredFont(forTextStyle: .footnote)
        toastLabel.textColor = .white
        toastLabel.backgroundColor = UIColor.black.withAlphaComponent(0.78)
        toastLabel.numberOfLines = 0
        toastLabel.textAlignment = .center
        toastLabel.layer.cornerRadius = 10
        toastLabel.layer.masksToBounds = true
        toastLabel.alpha = 0
        toastLabel.isUserInteractionEnabled = false

        for button in [globeButton, stickerGlobeButton] {
            button.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        }

        // Sticker panel: grid plus a bottom row with ABC, globe, a hint and delete.
        let abcButton = KeyboardKey.make(title: "ABC", label: String(localized: "Letters"))
        abcButton.addAction(UIAction { [weak self] _ in self?.setMode(.typing) }, for: .touchUpInside)
        let hint = UILabel()
        hint.text = String(localized: "Tap a sticker to copy it")
        hint.font = .preferredFont(forTextStyle: .caption1)
        hint.textColor = .secondaryLabel
        hint.textAlignment = .center
        hint.adjustsFontSizeToFitWidth = true
        let deleteButton = KeyboardKey.make(systemImage: "delete.left", label: String(localized: "Delete"))
        KeyboardKey.makeRepeating(deleteButton) { [weak self] in self?.textDocumentProxy.deleteBackward() }
        let bar = UIStackView(arrangedSubviews: [abcButton, stickerGlobeButton, hint, deleteButton])
        bar.spacing = 6
        bar.alignment = .fill

        // The banner sits above the grid (a hidden arranged view takes no space).
        let column = UIStackView(arrangedSubviews: [bannerLabel, collectionView])
        column.axis = .vertical
        column.spacing = 4
        column.isLayoutMarginsRelativeArrangement = true
        column.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 8, bottom: 0, trailing: 8)
        for subview in [column, messageLabel, bar] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            stickerPanel.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: stickerPanel.topAnchor),
            column.leadingAnchor.constraint(equalTo: stickerPanel.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: stickerPanel.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -6),
            messageLabel.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: stickerPanel.leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(equalTo: stickerPanel.trailingAnchor, constant: -24),
            bar.leadingAnchor.constraint(equalTo: stickerPanel.leadingAnchor, constant: 4),
            bar.trailingAnchor.constraint(equalTo: stickerPanel.trailingAnchor, constant: -4),
            bar.bottomAnchor.constraint(equalTo: stickerPanel.bottomAnchor, constant: -4),
            bar.heightAnchor.constraint(equalToConstant: 42),
            abcButton.widthAnchor.constraint(equalToConstant: 56),
            stickerGlobeButton.widthAnchor.constraint(equalToConstant: 44),
            deleteButton.widthAnchor.constraint(equalToConstant: 56),
        ])

        typingView.globeButton = globeButton
        typingView.onText = { [weak self] text in self?.textDocumentProxy.insertText(text) }
        typingView.onDelete = { [weak self] in self?.textDocumentProxy.deleteBackward() }
        typingView.onStickers = { [weak self] in self?.setMode(.stickers) }
        typingView.returnKeyTitle = Self.returnTitle(for: textDocumentProxy.returnKeyType)
        typingView.isHidden = true

        for subview in [stickerPanel, typingView, toastLabel] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            inputView.addSubview(subview)
        }
        let height = inputView.heightAnchor.constraint(equalToConstant: 268)
        height.priority = .defaultHigh
        heightConstraint = height
        NSLayoutConstraint.activate([
            height,
            stickerPanel.topAnchor.constraint(equalTo: inputView.topAnchor),
            stickerPanel.leadingAnchor.constraint(equalTo: inputView.leadingAnchor),
            stickerPanel.trailingAnchor.constraint(equalTo: inputView.trailingAnchor),
            stickerPanel.bottomAnchor.constraint(equalTo: inputView.safeAreaLayoutGuide.bottomAnchor),
            typingView.topAnchor.constraint(equalTo: inputView.topAnchor),
            typingView.leadingAnchor.constraint(equalTo: inputView.leadingAnchor),
            typingView.trailingAnchor.constraint(equalTo: inputView.trailingAnchor),
            typingView.bottomAnchor.constraint(equalTo: inputView.safeAreaLayoutGuide.bottomAnchor),
            toastLabel.topAnchor.constraint(equalTo: inputView.topAnchor, constant: 10),
            toastLabel.centerXAnchor.constraint(equalTo: inputView.centerXAnchor),
            toastLabel.widthAnchor.constraint(lessThanOrEqualTo: inputView.widthAnchor, constant: -32),
        ])
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let columns = max(4, Int(environment.container.effectiveContentSize.width / 88))
            let fraction = 1 / CGFloat(columns)
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(fraction),
                                                                heightDimension: .fractionalWidth(fraction)))
            item.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1),
                                                                             heightDimension: .fractionalWidth(fraction)),
                                                           repeatingSubitem: item, count: columns)
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 0, bottom: 6, trailing: 0)
            return section
        }
    }

    private func showToast(_ text: String) {
        toastLabel.text = text
        UIAccessibility.post(notification: .announcement, argument: text)
        toastHideWork?.cancel()
        UIView.animate(withDuration: 0.15) { self.toastLabel.alpha = 1 }
        let work = DispatchWorkItem { [weak self] in
            UIView.animate(withDuration: 0.3) { self?.toastLabel.alpha = 0 }
        }
        toastHideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func thumbnail(for sticker: Sticker, pixelSize: Int, completion: @escaping @MainActor (UIImage?) -> Void) {
        let key = sticker.id as NSUUID
        if let cached = thumbnails.object(forKey: key) { return completion(cached) }
        let url = store.fileURL(for: sticker)
        Task.detached(priority: .userInitiated) {
            let image = ImageLoader.thumbnail(contentsOf: url, maxPixelSize: pixelSize).map { UIImage(cgImage: $0) }
            await MainActor.run { [weak self] in
                if let image, let cgImage = image.cgImage {
                    self?.thumbnails.setObject(image, forKey: key, cost: cgImage.bytesPerRow * cgImage.height)
                }
                completion(image)
            }
        }
    }

    private static func returnTitle(for type: UIReturnKeyType?) -> String {
        switch type ?? .default {
        case .go: String(localized: "go")
        case .search, .google, .yahoo: String(localized: "search")
        case .send: String(localized: "send")
        case .done: String(localized: "done")
        case .next: String(localized: "next")
        case .join: String(localized: "join")
        default: String(localized: "return")
        }
    }
}

extension KeyboardViewController: UICollectionViewDataSource, UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        stickers.count
    }

    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: StickerCell.reuseIdentifier, for: indexPath) as! StickerCell
        let sticker = stickers[indexPath.item]
        cell.stickerID = sticker.id
        cell.imageView.image = nil
        cell.accessibilityLabel = sticker.name
        cell.contentView.alpha = hasFullAccess ? 1 : 0.5
        let pixels = Int(88 * traitCollection.displayScale)
        thumbnail(for: sticker, pixelSize: pixels) { [weak cell] image in
            guard let cell, cell.stickerID == sticker.id else { return }
            cell.imageView.image = image
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        copy(stickers[indexPath.item])
    }
}

/// Enables UIDevice.playInputClick() for this keyboard.
private final class ClickingInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}

private final class StickerCell: UICollectionViewCell {
    static let reuseIdentifier = "StickerCell"
    let imageView = UIImageView()
    var stickerID: UUID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityHint = String(localized: "Copies the sticker so you can paste it")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isHighlighted: Bool {
        didSet { imageView.alpha = isHighlighted ? 0.5 : 1 }
    }
}

private final class PaddedLabel: UILabel {
    private let insets = UIEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

    override func textRect(forBounds bounds: CGRect, limitedToNumberOfLines numberOfLines: Int) -> CGRect {
        let rect = super.textRect(forBounds: bounds.inset(by: insets), limitedToNumberOfLines: numberOfLines)
        return rect.inset(by: UIEdgeInsets(top: -insets.top, left: -insets.left, bottom: -insets.bottom, right: -insets.right))
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: insets))
    }
}
