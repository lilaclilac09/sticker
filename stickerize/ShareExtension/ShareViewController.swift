import StickerizeKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Stickerize" in the share sheet: turns the shared images into stickers with the same editor as the app.
final class ShareViewController: UIViewController {
    private let store = StickerStore.makeDefault()

    override func viewDidLoad() {
        super.viewDidLoad()
        // Images only, matching the activation rule (NSExtensionActivationSupportsImageWithMaxCount); PDFs come in
        // through Files in the app.
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
            .filter { $0.hasItemConformingToTypeIdentifier(UTType.image.identifier) }
        let root = ShareRootView(providers: providers, store: store) { [weak self] saved in
            self?.finish(saved: saved)
        }
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
    }

    private func finish(saved: Int) {
        if saved > 0 {
            extensionContext?.completeRequest(returningItems: nil)
        } else {
            extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
    }
}

private struct ShareRootView: View {
    let providers: [NSItemProvider]
    let store: StickerStore
    let onFinish: (Int) -> Void

    @State private var items: [ImportedImage]?

    var body: some View {
        Group {
            if let items, !items.isEmpty {
                StickerEditorFlow(items: items, store: store) { saved in
                    ImageImport.discard(items)
                    onFinish(saved)
                }
            } else if items != nil {
                NavigationStack {
                    ContentUnavailableView("Can't Make a Sticker", systemImage: "photo.badge.exclamationmark",
                                           description: Text("Stickerize couldn't read an image from what you shared."))
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Close") { onFinish(0) }
                            }
                        }
                }
            } else {
                ProgressView("Opening…")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if store.location == .local {
                Text("Stickerize's shared library isn't available in this build, so stickers saved here won't appear in the app.")
                    .font(.footnote)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.orange.opacity(0.15))
            }
        }
        .task {
            // Share extensions get much less memory than apps: copy the files, decode one at a time (in the editor),
            // and work at a smaller size than the app's 2048 px.
            ImageImport.purgeTemporaryFiles()
            items = await ImageImport.images(from: providers, maxPixelSize: 1536).images
        }
    }
}
