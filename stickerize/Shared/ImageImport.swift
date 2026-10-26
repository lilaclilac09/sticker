import CoreGraphics
import CoreTransferable
import Foundation
import StickerizeKit
import UniformTypeIdentifiers

/// An image waiting to become a sticker. It holds the encoded source, not pixels: decoding a batch up front costs
/// ~7 MB per image at 1536 px (more at 2048), which a Share extension can't afford for 10 images, so each image is
/// decoded only when its editor step appears.
struct ImportedImage: Identifiable, Sendable {
    enum Source: Sendable {
        case data(Data)
        /// A private copy in `ImageImport.temporaryDirectory`, removed by `ImageImport.discard(_:)`.
        case file(URL)
    }

    let id = UUID()
    let source: Source
    let suggestedName: String
    /// Longest side to decode at.
    let maxPixelSize: Int

    func decode() throws -> CGImage {
        switch source {
        case let .data(data): try ImageLoader.image(from: data, maxPixelSize: maxPixelSize)
        case let .file(url): try ImageLoader.image(contentsOf: url, maxPixelSize: maxPixelSize)
        }
    }
}

/// Turns whatever the user hands us (photo data, files, pasteboard or drag items, share-sheet attachments) into
/// imported images. Everything is decoded by ImageIO, so any format it reads works, plus page 1 of a PDF.
enum ImageImport {
    static let supportedTypes: [UTType] = [.image, .pdf]

    /// Where imported files are copied until they're edited. Cleared by `discard(_:)` and `purgeTemporaryFiles()`.
    static let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("Imports", isDirectory: true)

    static func image(from data: Data, name: String?, maxPixelSize: Int = StickerSpec.importMaxPixelDimension) throws -> ImportedImage {
        guard ImageLoader.isReadable(data) else { throw ImageLoadingError.unreadable }
        return ImportedImage(source: .data(data), suggestedName: suggestedName(from: name), maxPixelSize: maxPixelSize)
    }

    /// A file we already own (a temporary copy); validated from its header.
    static func image(ownedFile url: URL, name: String?, maxPixelSize: Int = StickerSpec.importMaxPixelDimension) throws -> ImportedImage {
        guard ImageLoader.isReadable(contentsOf: url) else {
            try? FileManager.default.removeItem(at: url)
            throw ImageLoadingError.unreadable
        }
        return ImportedImage(source: .file(url), suggestedName: suggestedName(from: name), maxPixelSize: maxPixelSize)
    }

    /// Copies a file picked with `.fileImporter` (possibly outside the sandbox, possibly still in iCloud) into our
    /// temporary directory, so it can be decoded later without holding security-scoped access.
    static func image(pickedFile url: URL, maxPixelSize: Int = StickerSpec.importMaxPixelDimension) async throws -> ImportedImage {
        try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let copy = try temporaryURL(pathExtension: url.pathExtension)
            var coordinationError: NSError?
            var copyError: Error?
            // Coordinated read so files still downloading from iCloud Drive are materialized first.
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
                do { try FileManager.default.copyItem(at: readURL, to: copy) } catch { copyError = error }
            }
            if let error = coordinationError ?? copyError { throw error }
            return try image(ownedFile: copy, name: url.lastPathComponent, maxPixelSize: maxPixelSize)
        }.value
    }

    /// Main-actor bound because NSItemProvider isn't Sendable; loading is callback based.
    @MainActor
    static func images(from providers: [NSItemProvider], maxPixelSize: Int = StickerSpec.importMaxPixelDimension) async -> (images: [ImportedImage], failures: Int) {
        var images: [ImportedImage] = []
        var failures = 0
        for provider in providers {
            do {
                let copy = try await provider.copyImageFile()
                // Photos and Files give the file's name as suggestedName; otherwise use the delivered file's name.
                let name = StickerName.fromFileName(provider.suggestedName) != nil ? provider.suggestedName : copy.originalName
                images.append(try image(ownedFile: copy.url, name: name, maxPixelSize: maxPixelSize))
            } catch {
                failures += 1
            }
        }
        return (images, failures)
    }

    /// Deletes the temporary copies behind `items` once they're saved or skipped.
    static func discard(_ items: [ImportedImage]) {
        for item in items {
            if case let .file(url) = item.source { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Removes copies left over from an earlier session (for example if the app was killed mid-edit).
    static func purgeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    static func temporaryURL(pathExtension: String) throws -> URL {
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let url = temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return pathExtension.isEmpty ? url : url.appendingPathExtension(pathExtension)
    }

    /// The file's name as a sticker name ("funny_cat.png" → "funny cat"); generated names such as IMG_1234 give
    /// the default name instead.
    static func suggestedName(from fileName: String?) -> String {
        StickerName.fromFileName(fileName) ?? StickerName.fallback
    }
}

/// A picked photo received as a file, so its bytes never have to sit in memory (`PhotosPickerItem.loadTransferable`).
struct ImportedFile: Transferable {
    let url: URL
    /// The name Photos delivered the file under (the asset's file name, e.g. "funny_cat.png").
    let originalName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let copy = try ImageImport.temporaryURL(pathExtension: received.file.pathExtension)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return ImportedFile(url: copy, originalName: received.file.lastPathComponent)
        }
    }
}

extension NSItemProvider {
    var canLoadImage: Bool {
        ImageImport.supportedTypes.contains { hasItemConformingToTypeIdentifier($0.identifier) }
    }

    /// Copies the most specific image (or PDF) representation into our temporary directory. File representations
    /// are copied on disk; only providers that offer nothing but in-memory data are written out from memory.
    /// `originalName` is the name the file was delivered under, when there was a file.
    @MainActor
    func copyImageFile() async throws -> (url: URL, originalName: String?) {
        let registered = registeredTypeIdentifiers.compactMap(UTType.init)
        let type = registered.first { candidate in ImageImport.supportedTypes.contains { candidate.conforms(to: $0) } }
            ?? ImageImport.supportedTypes.first { hasItemConformingToTypeIdentifier($0.identifier) }
        guard let type else { throw ImageLoadingError.unreadable }
        let extensionHint = type.preferredFilenameExtension ?? ""
        do {
            return try await withCheckedThrowingContinuation { continuation in
                _ = loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                    // The provided file is deleted when this handler returns, so copy it now.
                    guard let url else { return continuation.resume(throwing: error ?? ImageLoadingError.unreadable) }
                    do {
                        let copy = try ImageImport.temporaryURL(pathExtension: url.pathExtension.isEmpty ? extensionHint : url.pathExtension)
                        try FileManager.default.copyItem(at: url, to: copy)
                        continuation.resume(returning: (copy, url.lastPathComponent))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } catch {
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                _ = loadDataRepresentation(for: type) { data, error in
                    if let data { continuation.resume(returning: data) } else { continuation.resume(throwing: error ?? ImageLoadingError.unreadable) }
                }
            }
            let copy = try ImageImport.temporaryURL(pathExtension: extensionHint)
            try data.write(to: copy)
            return (copy, nil)
        }
    }
}
