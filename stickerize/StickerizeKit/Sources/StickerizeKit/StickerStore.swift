import CoreGraphics
import Foundation

public struct Sticker: Codable, Hashable, Identifiable, Sendable {
    public let id: UUID
    /// Shown to VoiceOver and used as the MSSticker `localizedDescription`.
    public var name: String
    /// Up to three emoji describing the sticker, used when exporting to WhatsApp / Telegram. Nil in older manifests.
    public var emoji: String?
    public let createdAt: Date
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let byteCount: Int

    public var fileName: String { id.uuidString + ".png" }

    public init(id: UUID = UUID(), name: String, emoji: String? = nil, createdAt: Date = Date(),
                pixelWidth: Int, pixelHeight: Int, byteCount: Int) {
        self.id = id
        self.name = name
        self.emoji = emoji
        self.createdAt = createdAt
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.byteCount = byteCount
    }
}

struct StickerManifest: Codable {
    static let currentVersion = 1
    var version = currentVersion
    /// Display order: index 0 is shown first.
    var stickers: [Sticker] = []
}

public enum StickerStoreError: LocalizedError, Equatable {
    case notFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .notFound: "That sticker no longer exists."
        }
    }
}

/// Sticker library shared by the app and its extensions.
///
/// Layout: `<container>/Stickers/<uuid>.png` plus `<container>/Stickers/manifest.json`. The container is the App Group
/// when the entitlement is present, otherwise the process's own Application Support directory (so the app still works,
/// but the extensions see their own empty library). Every mutation is a coordinated read-modify-write of the manifest
/// followed by a Darwin notification, so other processes can reload.
public final class StickerStore: Sendable {
    public enum Location: Sendable, Equatable {
        case appGroup(String)
        /// The App Group container wasn't available; data is private to this process.
        case local
    }

    /// Info.plist key whose value is the App Group identifier (filled from the `APP_GROUP` build setting).
    public static let appGroupInfoKey = "StickerizeAppGroup"
    public static let defaultGroupIdentifier = "group.ai.qokka.stickerize"

    public let location: Location
    public let directory: URL
    public let changeNotificationName: String
    private let manifestURL: URL

    /// The store configured by this bundle's Info.plist.
    public static func makeDefault(bundle: Bundle = .main) -> StickerStore {
        let group = (bundle.object(forInfoDictionaryKey: appGroupInfoKey) as? String).flatMap { $0.isEmpty ? nil : $0 }
        return StickerStore(appGroupIdentifier: group)
    }

    public convenience init(appGroupIdentifier: String?) {
        let fileManager = FileManager.default
        if let appGroupIdentifier,
           let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            self.init(directory: container.appendingPathComponent("Stickers", isDirectory: true),
                      location: .appGroup(appGroupIdentifier),
                      changeNotificationName: "\(appGroupIdentifier).stickers-changed")
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.init(directory: support.appendingPathComponent("Stickers", isDirectory: true),
                      location: .local,
                      changeNotificationName: "\(appGroupIdentifier ?? Self.defaultGroupIdentifier).local-stickers-changed")
        }
    }

    public init(directory: URL, location: Location = .local, changeNotificationName: String) {
        self.directory = directory
        self.location = location
        self.changeNotificationName = changeNotificationName
        self.manifestURL = directory.appendingPathComponent("manifest.json")
    }

    // MARK: Reading

    /// All stickers in display order. Entries whose PNG is missing are skipped.
    ///
    /// - Parameter coordinated: Pass false from a keyboard extension without Full Access: its sandbox makes the App
    ///   Group read-only, so it should just read files. Writers replace files atomically, so a plain read never sees
    ///   a half-written manifest.
    public func stickers(coordinated: Bool = true) throws -> [Sticker] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var result: Result<[Sticker], Error> = .success([])
        if coordinated {
            var coordinationError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: manifestURL, options: [], error: &coordinationError) { url in
                result = Result { try loadManifest(at: url).stickers }
            }
            if let coordinationError { throw coordinationError }
        } else {
            result = Result { try loadManifest(at: manifestURL).stickers }
        }
        return try result.get().filter { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
    }

    public func fileURL(for sticker: Sticker) -> URL {
        directory.appendingPathComponent(sticker.fileName)
    }

    public func pngData(for sticker: Sticker) throws -> Data {
        try Data(contentsOf: fileURL(for: sticker))
    }

    /// The PNG to put on the pasteboard for pasting into other apps: the sticker scaled to fit
    /// `StickerSpec.pasteMaxPixelDimension`, alpha kept.
    public func pasteboardPNG(for sticker: Sticker) throws -> Data {
        let data = try pngData(for: sticker)
        guard max(sticker.pixelWidth, sticker.pixelHeight) > StickerSpec.pasteMaxPixelDimension else { return data }
        let image = try ImageLoader.image(from: data, maxPixelSize: StickerSpec.pasteMaxPixelDimension)
        return try StickerEncoder.pngData(image)
    }

    // MARK: Writing

    /// Saves an encoded sticker at the front of the library.
    @discardableResult
    public func add(_ encoded: EncodedSticker, name: String, emoji: String? = nil) throws -> Sticker {
        let sticker = Sticker(name: Self.cleanName(name), emoji: Self.cleanEmoji(emoji), pixelWidth: encoded.pixelWidth,
                              pixelHeight: encoded.pixelHeight, byteCount: encoded.pngData.count)
        try createDirectoryIfNeeded()
        let url = fileURL(for: sticker)
        try encoded.pngData.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        do {
            try mutate { manifest in
                // A missing manifest is rebuilt from the PNGs on disk, which already include this one.
                manifest.stickers.removeAll { $0.id == sticker.id }
                manifest.stickers.insert(sticker, at: 0)
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return sticker
    }

    public func rename(_ id: UUID, to name: String) throws {
        try mutate { manifest in
            guard let index = manifest.stickers.firstIndex(where: { $0.id == id }) else { throw StickerStoreError.notFound(id) }
            manifest.stickers[index].name = Self.cleanName(name)
        }
    }

    public func update(_ id: UUID, name: String, emoji: String?) throws {
        try mutate { manifest in
            guard let index = manifest.stickers.firstIndex(where: { $0.id == id }) else { throw StickerStoreError.notFound(id) }
            manifest.stickers[index].name = Self.cleanName(name)
            manifest.stickers[index].emoji = Self.cleanEmoji(emoji)
        }
    }

    public func delete(_ ids: Set<UUID>) throws {
        var removed: [Sticker] = []
        try mutate { manifest in
            removed = manifest.stickers.filter { ids.contains($0.id) }
            manifest.stickers.removeAll { ids.contains($0.id) }
        }
        for sticker in removed { try? FileManager.default.removeItem(at: fileURL(for: sticker)) }
    }

    /// Reorders to match `ids`. Stickers not mentioned keep their relative order after the mentioned ones.
    public func reorder(_ ids: [UUID]) throws {
        try mutate { manifest in
            let rank = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
            let indexed = manifest.stickers.enumerated().map { (offset: $0.offset, sticker: $0.element) }
            manifest.stickers = indexed.sorted { a, b in
                (rank[a.sticker.id] ?? Int.max, a.offset) < (rank[b.sticker.id] ?? Int.max, b.offset)
            }.map(\.sticker)
        }
    }

    /// Starts observing changes made by any process using this store. Keep the returned object alive.
    public func observeChanges(_ handler: @escaping @Sendable () -> Void) -> StickerChangeObserver {
        StickerChangeObserver(name: changeNotificationName, handler: handler)
    }

    // MARK: Private

    private func mutate(_ body: (inout StickerManifest) throws -> Void) throws {
        try createDirectoryIfNeeded()
        var result: Result<Void, Error> = .success(())
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: manifestURL, options: [], error: &coordinationError) { url in
            result = Result {
                var manifest = try loadManifest(at: url)
                try body(&manifest)
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(manifest).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
        StickerChangeObserver.post(name: changeNotificationName)
    }

    /// Reads the manifest. If it is missing or unreadable (an unreadable one is set aside first), the library is rebuilt
    /// from the PNGs on disk, so a bad write can never strand the user's stickers. No PNGs means an empty library.
    private func loadManifest(at url: URL) throws -> StickerManifest {
        if let data = try? Data(contentsOf: url) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let manifest = try? decoder.decode(StickerManifest.self, from: data) { return manifest }
            let backup = directory.appendingPathComponent("manifest.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: url, to: backup)
        }
        return rebuildManifest()
    }

    private func rebuildManifest() -> StickerManifest {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? []
        let stickers: [Sticker] = files.compactMap { url in
            guard url.pathExtension == "png", let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  let size = ImageLoader.orientedPixelSize(contentsOf: url) else { return nil }
            let values = try? url.resourceValues(forKeys: [.creationDateKey, .fileSizeKey])
            return Sticker(id: id, name: "Sticker", createdAt: values?.creationDate ?? Date(),
                           pixelWidth: Int(size.width), pixelHeight: Int(size.height), byteCount: values?.fileSize ?? 0)
        }
        return StickerManifest(stickers: stickers.sorted { $0.createdAt > $1.createdAt })
    }

    private func createDirectoryIfNeeded() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    static func cleanName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Sticker" : String(trimmed.prefix(StickerSpec.maxNameLength))
    }

    static func cleanEmoji(_ emoji: String?) -> String? {
        guard let trimmed = emoji?.filter({ !$0.isWhitespace }), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(3))
    }
}
