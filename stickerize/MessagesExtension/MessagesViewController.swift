import Messages
import os
import StickerizeKit
import UIKit

/// iMessage app: a sticker browser over the shared library. Stickers can be tapped to insert or peeled and dragged
/// onto a message bubble. The library reloads when the app (or the Share extension) changes it.
final class MessagesViewController: MSMessagesAppViewController {
    private let store = StickerStore.makeDefault()
    private var observer: StickerChangeObserver?
    private let browser = StickerBrowserViewController(stickerSize: .regular)
    private let emptyState = UIStackView()
    private let emptyMessage = UILabel()
    private var laidOutSize = CGSize.zero
    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Stickerize", category: "stickers")

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(browser)
        browser.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(browser.view)
        NSLayoutConstraint.activate([
            browser.view.topAnchor.constraint(equalTo: view.topAnchor),
            browser.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            browser.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            browser.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        browser.didMove(toParent: self)
        // Let the last row scroll clear of the floating + button (44 pt + 12 pt margin + breathing room).
        browser.stickerBrowserView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 68, right: 0)
        setUpEmptyState()
        setUpAddButton()

        observer = store.observeChanges { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    override func willBecomeActive(with conversation: MSConversation) {
        super.willBecomeActive(with: conversation)
        reload()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        // The drawer opens at compact height and is resized by the user; lay the grid out again for the real size
        // (a sticker browser reloaded before it had a size has been reported to stay empty until the sheet is dragged).
        guard view.bounds.size != laidOutSize, view.bounds.width > 0 else { return }
        laidOutSize = view.bounds.size
        browser.stickerBrowserView.reloadData()
    }

    private func reload() {
        // A plain read: the app replaces files atomically, and this extension never writes.
        let library: [Sticker]
        do {
            library = try store.stickers(coordinated: false)
        } catch {
            log.error("Couldn't read the sticker library: \(error.localizedDescription, privacy: .public)")
            library = []
        }
        browser.stickers = library.compactMap { sticker in
            try? MSSticker(contentsOfFileURL: store.fileURL(for: sticker), localizedDescription: sticker.name)
        }
        log.info("Loaded \(self.browser.stickers.count) of \(library.count) stickers from \(String(describing: self.store.location), privacy: .public)")
        emptyState.isHidden = !browser.stickers.isEmpty
        if store.location == .local {
            emptyMessage.text = String(localized: "Stickerize can't reach its shared library. Reinstall the app, or check that the App Group is set up in the project.")
        } else {
            emptyMessage.text = String(localized: "No stickers yet. Make some from your photos in the Stickerize app.")
        }
    }

    // MARK: UI

    private func setUpEmptyState() {
        emptyMessage.numberOfLines = 0
        emptyMessage.textAlignment = .center
        emptyMessage.font = .preferredFont(forTextStyle: .body)
        emptyMessage.textColor = .secondaryLabel
        emptyMessage.adjustsFontForContentSizeCategory = true

        var configuration = UIButton.Configuration.filled()
        configuration.title = String(localized: "Open Stickerize")
        configuration.cornerStyle = .capsule
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.openApp() })

        emptyState.axis = .vertical
        emptyState.alignment = .center
        emptyState.spacing = 12
        emptyState.addArrangedSubview(emptyMessage)
        emptyState.addArrangedSubview(button)
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor),
            emptyState.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor, constant: 16),
            emptyState.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor, constant: -16),
        ])
    }

    private func setUpAddButton() {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: "plus")
        configuration.cornerStyle = .capsule
        let button = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.openApp() })
        button.accessibilityLabel = String(localized: "Make a sticker in Stickerize")
        button.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
            button.widthAnchor.constraint(equalToConstant: 44),
            button.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func openApp() {
        guard let url = URL(string: "stickerize://import") else { return }
        extensionContext?.open(url)
    }
}

/// The sticker grid. MSStickerBrowserViewController makes itself its browser view's data source when its view loads,
/// so a data source assigned from outside is replaced (and one assigned before the view loads is dropped). Checked in
/// the iOS 27.2 simulator. Subclassing and overriding both methods, as Apple documents, is what works.
final class StickerBrowserViewController: MSStickerBrowserViewController {
    var stickers: [MSSticker] = [] {
        didSet { if isViewLoaded { stickerBrowserView.reloadData() } }
    }

    override func numberOfStickers(in stickerBrowserView: MSStickerBrowserView) -> Int {
        stickers.count
    }

    override func stickerBrowserView(_ stickerBrowserView: MSStickerBrowserView, stickerAt index: Int) -> MSSticker {
        stickers[index]
    }
}
