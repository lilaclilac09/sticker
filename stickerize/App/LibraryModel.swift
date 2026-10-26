import Observation
import PhotosUI
import StickerizeKit
import SwiftUI
import UIKit

/// The app's view of the shared sticker library, plus the queue of images waiting to be turned into stickers.
@MainActor
@Observable
final class LibraryModel {
    let store = StickerStore.makeDefault()
    private(set) var stickers: [Sticker] = []
    /// Images being edited; non-empty presents the editor.
    var editorBatch: EditorBatch?
    var isImporting = false
    var message: UserMessage?
    /// Set by the `stickerize://import` link (from the iMessage app) to open the photo picker.
    var requestsPhotoPicker = false

    @ObservationIgnored private var observer: StickerChangeObserver?
    /// Held back while the editor sheet is up: SwiftUI drops an alert presented under a sheet.
    @ObservationIgnored private var messageAfterEditing: UserMessage?

    struct EditorBatch: Identifiable {
        let id = UUID()
        let items: [ImportedImage]
    }

    struct UserMessage: Identifiable {
        let id = UUID()
        let title: String
        let body: String
    }

    init() {
        ImageImport.purgeTemporaryFiles()
        observer = store.observeChanges { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    func reload() {
        do {
            stickers = try store.stickers()
        } catch {
            show("Couldn't Load Stickers", error)
        }
    }

    // MARK: Importing

    /// True while an import is loading or the editor is open; import controls are disabled meanwhile, so a second
    /// batch can't replace one being edited.
    var isBusy: Bool { isImporting || editorBatch != nil }

    /// Photos arrive as temporary file copies (see `ImportedFile`). Loading can take a while for iCloud originals,
    /// so the progress overlay is up from the first item, and items that fail to load are counted.
    func importPhotos(_ items: [PhotosPickerItem]) async {
        await importBatch(count: items.count) { index in
            guard let file = try await items[index].loadTransferable(type: ImportedFile.self) else {
                throw ImageLoadingError.unreadable
            }
            return try ImageImport.image(ownedFile: file.url, name: nil)
        }
    }

    func importFiles(_ urls: [URL]) async {
        await importBatch(count: urls.count) { index in
            try await ImageImport.image(pickedFile: urls[index])
        }
    }

    /// Called when the editor sheet closes, whether the images were saved, skipped or cancelled.
    func finishEditing() {
        if let batch = editorBatch { ImageImport.discard(batch.items) }
        editorBatch = nil
        if let pending = messageAfterEditing {
            messageAfterEditing = nil
            Task {
                // Let the sheet finish dismissing before presenting the alert.
                try? await Task.sleep(for: .milliseconds(600))
                message = pending
            }
        }
    }

    func importProviders(_ providers: [NSItemProvider]) async {
        guard !isBusy else { return }
        let supported = providers.filter(\.canLoadImage)
        guard !supported.isEmpty else {
            message = UserMessage(title: String(localized: "Nothing to Import"),
                                  body: String(localized: "That isn't an image Stickerize can use."))
            return
        }
        isImporting = true
        defer { isImporting = false }
        let result = await ImageImport.images(from: supported)
        finishImport(result.images, failures: result.failures)
    }

    private func importBatch(count: Int, load: (Int) async throws -> ImportedImage) async {
        guard count > 0, !isBusy else { return }
        isImporting = true
        defer { isImporting = false }
        var images: [ImportedImage] = []
        var failures = 0
        for index in 0..<count {
            do { images.append(try await load(index)) } catch { failures += 1 }
        }
        finishImport(images, failures: failures)
    }

    private func finishImport(_ images: [ImportedImage], failures: Int) {
        var failureMessage: UserMessage?
        if failures > 0 {
            failureMessage = UserMessage(title: String(localized: "Some Images Couldn't Be Opened"),
                                         body: String(localized: "Couldn't read \(failures) of the selected items. They may not be images, or they couldn't be downloaded."))
        }
        if images.isEmpty {
            message = failureMessage
        } else {
            messageAfterEditing = failureMessage
            editorBatch = EditorBatch(items: images)
        }
    }

    // MARK: Editing the library

    func update(_ sticker: Sticker, name: String, emoji: String) {
        perform("Couldn't Save Changes") { try store.update(sticker.id, name: name, emoji: emoji) }
    }

    func delete(_ ids: Set<UUID>) {
        perform("Couldn't Delete") { try store.delete(ids) }
    }

    func moveToFront(_ sticker: Sticker) {
        perform("Couldn't Reorder") { try store.reorder([sticker.id]) }
    }

    func handle(_ url: URL) {
        guard url.scheme == "stickerize" else { return }
        if url.host() == "import" { requestsPhotoPicker = true }
    }

    // MARK: Helpers

    func show(_ title: LocalizedStringResource, _ error: Error) {
        message = UserMessage(title: String(localized: title),
                              body: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    private func perform(_ title: LocalizedStringResource, _ body: () throws -> Void) {
        do { try body() } catch { show(title, error) }
        // The change notification also reloads, but do it now so the UI doesn't wait for the round trip.
        reload()
    }
}
