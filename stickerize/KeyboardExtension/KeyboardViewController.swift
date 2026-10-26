import StickerizeKit
import UIKit
import UniformTypeIdentifiers

/// Sticker keyboard for apps that don't host iMessage apps (WhatsApp, Telegram, Signal, Slack, Mail…).
///
/// A sticker picker, not a typing keyboard: keyboards can only insert text (UITextDocumentProxy has no image API), so
/// tapping a sticker copies its PNG and the user pastes it. Copying needs Full Access; without it the keyboard still
/// shows the stickers (the App Group is readable) and explains how to turn it on.
/// Memory is tight in keyboards (tens of MB), so it only decodes cell-sized thumbnails and never links Vision.
final class KeyboardViewController: UIInputViewController {
    private let store = StickerStore.makeDefault()
    private var stickers: [Sticker] = []
    private var observer: StickerChangeObserver?
    private let thumbnails = NSCache<NSUUID, UIImage>()

    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    /// Centred over the grid when there are no stickers.
    private let messageLabel = UILabel()
    /// Above the grid when stickers exist but Full Access is off.
    private let bannerLabel = PaddedLabel()
    private let toastLabel = PaddedLabel()
    private let globeButton = UIButton(type: .system)
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
        thumbnails.totalCostLimit = 20 * 1024 * 1024
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
        // On Face ID iPhones the system draws its own globe key below the keyboard; elsewhere we must offer one.
        globeButton.isHidden = !needsInputModeSwitchKey
        collectionView.contentInset.bottom = needsInputModeSwitchKey ? 52 : 0
        heightConstraint?.constant = preferredHeight
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

    /// Taller than the system keyboard so a few rows of large stickers fit; shorter in iPhone landscape so the host
    /// keeps part of the screen. The screen's shape is checked too, in case the size class doesn't change on rotation.
    /// (Not the window's: a keyboard's window is only keyboard-sized, so it is always wider than tall.)
    private var preferredHeight: CGFloat {
        let screenSize = view.window?.windowScene?.screen.bounds.size ?? .zero
        let landscapePhone = traitCollection.userInterfaceIdiom == .phone && screenSize.width > screenSize.height
        if traitCollection.verticalSizeClass == .compact || landscapePhone { return 200 }
        return traitCollection.userInterfaceIdiom == .pad ? 380 : 320
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
        guard let item = try? store.pasteboardItem(for: sticker) else {
            showToast(String(localized: "That sticker is gone."))
            reload()
            return
        }
        // The file's bytes only (PNG, or GIF for animated stickers): setting a UIImage would also publish a JPEG
        // without alpha or animation, and some apps prefer it.
        UIPasteboard.general.setItems([[item.type.identifier: item.data]], options: [.localOnly: true])
        UIDevice.current.playInputClick()
        showToast(String(localized: "Copied. Touch and hold the message field, then tap Paste."))
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

        bannerLabel.text = String(localized: "To copy stickers, turn on Full Access in Settings › General › Keyboard › Keyboards › Stickerize.")
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

        var globe = UIButton.Configuration.filled()
        globe.image = UIImage(systemName: "globe")
        globe.baseForegroundColor = .label
        globe.baseBackgroundColor = .secondarySystemBackground
        globe.cornerStyle = .capsule
        globeButton.configuration = globe
        globeButton.accessibilityLabel = String(localized: "Next keyboard")
        globeButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        globeButton.isHidden = true

        // The banner sits above the grid (a hidden arranged view takes no space).
        let column = UIStackView(arrangedSubviews: [bannerLabel, collectionView])
        column.axis = .vertical
        column.spacing = 4
        column.isLayoutMarginsRelativeArrangement = true
        column.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 6, leading: 6, bottom: 0, trailing: 6)

        for subview in [column, messageLabel, globeButton, toastLabel] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            inputView.addSubview(subview)
        }
        let height = inputView.heightAnchor.constraint(equalToConstant: 320)
        height.priority = .defaultHigh
        heightConstraint = height
        NSLayoutConstraint.activate([
            height,
            column.topAnchor.constraint(equalTo: inputView.topAnchor),
            column.leadingAnchor.constraint(equalTo: inputView.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: inputView.trailingAnchor),
            column.bottomAnchor.constraint(equalTo: inputView.safeAreaLayoutGuide.bottomAnchor),
            messageLabel.centerYAnchor.constraint(equalTo: collectionView.centerYAnchor),
            messageLabel.leadingAnchor.constraint(equalTo: inputView.leadingAnchor, constant: 24),
            messageLabel.trailingAnchor.constraint(equalTo: inputView.trailingAnchor, constant: -24),
            globeButton.leadingAnchor.constraint(equalTo: inputView.leadingAnchor, constant: 10),
            globeButton.bottomAnchor.constraint(equalTo: inputView.safeAreaLayoutGuide.bottomAnchor, constant: -6),
            globeButton.widthAnchor.constraint(equalToConstant: 44),
            globeButton.heightAnchor.constraint(equalToConstant: 44),
            toastLabel.topAnchor.constraint(equalTo: inputView.topAnchor, constant: 10),
            toastLabel.centerXAnchor.constraint(equalTo: inputView.centerXAnchor),
            toastLabel.widthAnchor.constraint(lessThanOrEqualTo: inputView.widthAnchor, constant: -32),
        ])
    }

    /// Three columns on an iPhone in portrait (cells of about 130 pt); more on wider screens.
    private static func columnCount(forWidth width: CGFloat) -> Int {
        max(3, Int(width / 130))
    }

    private func makeLayout() -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { _, environment in
            let columns = Self.columnCount(forWidth: environment.container.effectiveContentSize.width)
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
        cell.badge.isHidden = !sticker.isAnimated
        cell.accessibilityLabel = sticker.isAnimated ? String(localized: "\(sticker.name), animated") : sticker.name
        cell.contentView.alpha = hasFullAccess ? 1 : 0.5
        // Decode at the cell's real size (stickers are at most 618 px, so this never upscales).
        let side = collectionView.bounds.width / CGFloat(Self.columnCount(forWidth: collectionView.bounds.width))
        let pixels = max(64, Int(side * traitCollection.displayScale))
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
    /// "GIF" on animated stickers (the grid shows their first frame, to keep the keyboard's memory low).
    let badge = UILabel()
    var stickerID: UUID?

    override init(frame: CGRect) {
        super.init(frame: frame)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = contentView.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        contentView.addSubview(imageView)
        badge.text = "GIF"
        badge.font = .systemFont(ofSize: 10, weight: .bold)
        badge.textColor = .label
        badge.backgroundColor = .secondarySystemBackground
        badge.textAlignment = .center
        badge.layer.cornerRadius = 4
        badge.layer.masksToBounds = true
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            badge.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            badge.widthAnchor.constraint(equalToConstant: 28),
            badge.heightAnchor.constraint(equalToConstant: 16),
        ])
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
