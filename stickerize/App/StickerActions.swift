import CoreTransferable
import Photos
import StickerExport
import StickerizeKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension UTType {
    /// Marks drags that start in Stickerize, so dropping a tile back on the library doesn't import a duplicate.
    /// Declared in App-Info.plist (UTExportedTypeDeclarations).
    static let stickerizeSticker = UTType(exportedAs: "ai.qokka.stickerize.sticker", conformingTo: .data)
}

/// A sticker as a shareable PNG (share sheet, drag and drop). Uses the ≤ 512 px pasteboard copy, which other apps
/// handle best; transparency is kept.
struct StickerPNG: Transferable {
    let sticker: Sticker
    let store: StickerStore

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { item in
            try item.store.pasteboardPNG(for: item.sticker)
        }
        .suggestedFileName { $0.sticker.name + ".png" }
        // An empty marker that only this process sees, so the library can refuse its own tiles as drops.
        DataRepresentation(exportedContentType: .stickerizeSticker) { _ in Data() }
            .visibility(.ownProcess)
    }
}

@MainActor
enum StickerActions {
    /// Copies PNG bytes only. A UIImage would also publish a JPEG without alpha, which some apps prefer.
    static func copy(_ sticker: Sticker, from store: StickerStore) throws {
        let data = try store.pasteboardPNG(for: sticker)
        UIPasteboard.general.setItems([[UTType.png.identifier: data]])
    }

    /// Saves the full-size PNG (with alpha) to Photos, where "Add Sticker" can put it in the system sticker library.
    static func saveToPhotos(_ sticker: Sticker, from store: StickerStore) async throws {
        let data = try store.pngData(for: sticker)
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw PhotosAccessError() }
        try await PHPhotoLibrary.shared().performChanges {
            // Adding the PNG bytes as the photo resource keeps the alpha channel (a UIImage would be re-encoded).
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.originalFilename = sticker.name + ".png"
            options.uniformTypeIdentifier = UTType.png.identifier
            request.addResource(with: .photo, data: data, options: options)
        }
    }

    struct PhotosAccessError: LocalizedError {
        var errorDescription: String? {
            String(localized: "Stickerize doesn't have permission to add to your photo library. You can allow it in Settings › Stickerize › Photos.")
        }
    }

    // MARK: Messengers

    enum Messenger: String, Identifiable, CaseIterable {
        case whatsApp, telegram

        var id: Self { self }

        var name: String {
            switch self {
            case .whatsApp: "WhatsApp"
            case .telegram: "Telegram"
            }
        }

        var allowedCount: ClosedRange<Int> {
            switch self {
            case .whatsApp: StickerPackExport.whatsAppStickerCount
            case .telegram: StickerPackExport.telegramStickerCount
            }
        }

        @MainActor
        var isInstalled: Bool {
            let scheme = self == .whatsApp ? "whatsapp://" : "tg://"
            return URL(string: scheme).map(UIApplication.shared.canOpenURL) ?? false
        }
    }

    /// Builds the pack (WebP/PNG renditions, off the main thread) and hands it to the messenger via the pasteboard.
    static func export(_ stickers: [Sticker], from store: StickerStore, to messenger: Messenger,
                       packName: String, publisher: String) async throws {
        let payload = try await Task.detached(priority: .userInitiated) {
            let items = stickers.map { sticker in
                ExportSticker(source: .file(store.fileURL(for: sticker)),
                              emojis: StickerPackExport.emojis(in: sticker.emoji ?? ""),
                              accessibilityText: sticker.name)
            }
            switch messenger {
            case .whatsApp: return try StickerPackExport.whatsApp(items, name: packName, publisher: publisher)
            case .telegram: return try StickerPackExport.telegram(items)
            }
        }.value
        try Task.checkCancellation()
        UIPasteboard.general.setItems([[payload.pasteboardType: payload.data]],
                                      options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(payload.expiration)])
        guard await UIApplication.shared.open(payload.openURL) else { throw MessengerMissingError(name: messenger.name) }
    }

    struct MessengerMissingError: LocalizedError {
        let name: String
        var errorDescription: String? { String(localized: "\(name) isn't installed.") }
    }
}
