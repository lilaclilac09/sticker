import Messages
import StickerizeKit
import UIKit

/// iMessage app: a sticker browser over the shared library. Stickers can be tapped to insert or peeled and dragged
/// onto a message bubble. The library reloads when the app (or the Share extension) changes it.
final class MessagesViewController: MSMessagesAppViewController {
    private let store = StickerStore.makeDefault()
    private var stickers: [MSSticker] = []
    private var observer: StickerChangeObserver?
    private let browser = MSStickerBrowserViewController(stickerSize: .regular)
    private let emptyState = UIStackView()
    private let emptyMessage = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        browser.stickerBrowserView.dataSource = self
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

    private func reload() {
        let library = (try? store.stickers()) ?? []
        stickers = library.compactMap { sticker in
            try? MSSticker(contentsOfFileURL: store.fileURL(for: sticker), localizedDescription: sticker.name)
        }
        browser.stickerBrowserView.reloadData()
        emptyState.isHidden = !stickers.isEmpty
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

extension MessagesViewController: @preconcurrency MSStickerBrowserViewDataSource {
    func numberOfStickers(in stickerBrowserView: MSStickerBrowserView) -> Int {
        stickers.count
    }

    func stickerBrowserView(_ stickerBrowserView: MSStickerBrowserView, stickerAt index: Int) -> MSSticker {
        stickers[index]
    }
}
