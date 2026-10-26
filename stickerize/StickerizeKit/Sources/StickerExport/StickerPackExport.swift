import CoreGraphics
import Foundation
import StickerizeKit

/// One sticker going into an exported pack. File-backed stickers are decoded one at a time while the pack is built,
/// so a 120-sticker export holds one bitmap at a time instead of all of them.
public struct ExportSticker: Sendable {
    public enum Source: Sendable {
        case image(CGImage)
        case file(URL)
    }

    public var source: Source
    public var emojis: [String]
    public var accessibilityText: String

    public init(image: CGImage, emojis: [String], accessibilityText: String) {
        self.init(source: .image(image), emojis: emojis, accessibilityText: accessibilityText)
    }

    public init(source: Source, emojis: [String], accessibilityText: String) {
        self.source = source
        self.emojis = emojis
        self.accessibilityText = accessibilityText
    }

    func loadImage() throws -> CGImage {
        switch source {
        case let .image(image): image
        case let .file(url): try ImageLoader.image(contentsOf: url, maxPixelSize: nil)
        }
    }
}

/// What the app puts on the pasteboard before opening the messenger.
public struct StickerPackPayload: Sendable {
    public let pasteboardType: String
    public let data: Data
    public let openURL: URL
    /// Both apps read the pasteboard right after being opened; keep the item short-lived and on this device.
    public let expiration: TimeInterval = 60
}

public enum StickerExportError: LocalizedError, Equatable {
    case wrongStickerCount(destination: String, allowed: ClosedRange<Int>, actual: Int)
    case invalidText(String)
    case pngTooLarge(bytes: Int, limit: Int)
    /// Wraps a failure with the sticker it happened on.
    case stickerFailed(name: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case let .wrongStickerCount(destination, allowed, actual):
            "\(destination) packs need \(allowed.lowerBound)–\(allowed.upperBound) stickers; \(actual) selected."
        case let .invalidText(message): message
        case let .pngTooLarge(bytes, limit): "The sticker is \(bytes / 1024) KB as PNG; the limit is \(limit / 1024) KB."
        case let .stickerFailed(name, reason): "“\(name)”: \(reason)"
        }
    }
}

/// WhatsApp and Telegram sticker-pack import, following their official iOS samples:
/// - WhatsApp (github.com/WhatsApp/stickers, iOS): pasteboard type `net.whatsapp.third-party.sticker-pack`, open
///   `whatsapp://stickerPack`; 3–30 stickers, each exactly 512×512 WebP ≤ 100 KB, a 96×96 PNG tray icon ≤ 50 KB,
///   up to 3 emojis and ≤ 125 chars of accessibility text per sticker.
/// - Telegram (github.com/TelegramMessenger/TelegramStickersImport, and the Telegram-iOS parser): pasteboard type
///   `org.telegram.third-party.stickerset`, open `tg://importStickers`; 1–120 PNG stickers with one side exactly
///   512 px, ≤ 512 KB, at least one emoji each. Static packs must use `image/png` (the client only takes WebP for
///   video packs), and the thumbnail is a {data, mimeType} object (the SDK's plain string is ignored by the client).
public enum StickerPackExport {
    public static let whatsAppStickerCount = 3...30
    public static let telegramStickerCount = 1...120
    public static let defaultEmoji = "🙂"

    // MARK: WhatsApp

    public static func whatsApp(_ stickers: [ExportSticker], name: String, publisher: String,
                                identifier: String = UUID().uuidString) throws -> StickerPackPayload {
        guard whatsAppStickerCount.contains(stickers.count) else {
            throw StickerExportError.wrongStickerCount(destination: "WhatsApp", allowed: whatsAppStickerCount, actual: stickers.count)
        }
        let name = try checkedText(name, field: "Pack name")
        let publisher = try checkedText(publisher, field: "Publisher")
        let identifier = String(identifier.filter { $0.isASCII && ($0.isLetter || $0.isNumber || "_-. ".contains($0)) }.prefix(128))
        guard !identifier.isEmpty else { throw StickerExportError.invalidText("The pack identifier is empty.") }

        var entries: [[String: Any]] = []
        for sticker in stickers {
            var entry: [String: Any] = [
                "image_data": try named(sticker) { try whatsAppStickerWebP(sticker.loadImage()) }.base64EncodedString(),
                "emojis": Array(sticker.emojis.prefix(3)),
            ]
            let text = sticker.accessibilityText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { entry["accessibility_text"] = String(text.prefix(125)) }
            entries.append(entry)
        }
        let json: [String: Any] = [
            "identifier": identifier,
            "name": name,
            "publisher": publisher,
            "tray_image": try trayPNG(stickers[0].loadImage()).base64EncodedString(),
            "stickers": entries,
        ]
        return StickerPackPayload(pasteboardType: "net.whatsapp.third-party.sticker-pack",
                                  data: try JSONSerialization.data(withJSONObject: json),
                                  openURL: URL(string: "whatsapp://stickerPack")!)
    }

    /// 512×512 transparent canvas, subject fitted inside a 16 px margin, lossy WebP ≤ 100 KB.
    public static func whatsAppStickerWebP(_ image: CGImage) throws -> Data {
        let canvas = try fit(ImageOps.trimTransparent(image), width: 512, height: 512, margin: 16)
        return try WebPEncoder.encode(canvas, maxBytes: 100 * 1024)
    }

    /// 96×96 PNG tray icon ≤ 50 KB.
    public static func trayPNG(_ image: CGImage) throws -> Data {
        let tray = try fit(ImageOps.trimTransparent(image), width: 96, height: 96, margin: 4)
        let data = try StickerEncoder.pngData(tray)
        guard data.count <= 50 * 1024 else { throw WebPEncodingError.cannotFit(bytes: data.count, limit: 50 * 1024) }
        return data
    }

    // MARK: Telegram

    public static func telegram(_ stickers: [ExportSticker], software: String = "Stickerize") throws -> StickerPackPayload {
        guard telegramStickerCount.contains(stickers.count) else {
            throw StickerExportError.wrongStickerCount(destination: "Telegram", allowed: telegramStickerCount, actual: stickers.count)
        }
        var entries: [[String: Any]] = []
        for sticker in stickers {
            entries.append([
                "data": try named(sticker) { try telegramStickerPNG(sticker.loadImage()) }.base64EncodedString(),
                "mimeType": "image/png",
                "emojis": sticker.emojis.isEmpty ? [defaultEmoji] : sticker.emojis,
            ])
        }
        let json: [String: Any] = [
            "software": software,
            "isAnimated": false,
            "isVideo": false,
            "stickers": entries,
            "thumbnail": ["data": try trayPNG(stickers[0].loadImage()).base64EncodedString(), "mimeType": "image/png"],
        ]
        return StickerPackPayload(pasteboardType: "org.telegram.third-party.stickerset",
                                  data: try JSONSerialization.data(withJSONObject: json),
                                  openURL: URL(string: "tg://importStickers")!)
    }

    /// PNG whose longer side is exactly 512 px (scaled up if needed), ≤ 512 KB.
    ///
    /// The longer side must be 512 even for stickers the app stored smaller to meet iMessage's 500 KB, so dense images
    /// can come out too big. Opaque images are written without alpha, and if that's not enough the detail is reduced
    /// (drawn smaller, then scaled back up to 512) until the PNG fits.
    public static func telegramStickerPNG(_ image: CGImage) throws -> Data {
        let limit = 512 * 1024
        let trimmed = ImageOps.trimTransparent(image)
        let scale = 512 / Double(max(trimmed.width, trimmed.height))
        let width = min(512, max(1, Int((Double(trimmed.width) * scale).rounded())))
        let height = min(512, max(1, Int((Double(trimmed.height) * scale).rounded())))
        let opaque = !ImageOps.hasTransparency(trimmed)
        var detail = 1.0
        while true {
            var source = trimmed
            if detail < 1, let reduced = ImageOps.redraw(trimmed, width: max(1, Int(Double(width) * detail)),
                                                          height: max(1, Int(Double(height) * detail)), opaque: opaque) {
                source = reduced
            }
            let canvas = try fit(source, width: width, height: height, margin: 0, opaque: opaque)
            let data = try StickerEncoder.pngData(canvas)
            if data.count <= limit { return data }
            // Same idea as StickerEncoder: size tracks pixel count, so step by √(limit/size), down to 1/8 detail.
            guard detail > 0.125 else { throw StickerExportError.pngTooLarge(bytes: data.count, limit: limit) }
            detail = max(0.125, detail * min(0.9, (Double(limit) / Double(data.count)).squareRoot() * 0.95))
        }
    }

    // MARK: Helpers

    /// Up to `limit` emoji characters found in `text`, in order (non-emoji characters are ignored).
    public static func emojis(in text: String, limit: Int = 3) -> [String] {
        Array(text.filter(\.isStickerEmoji).map(String.init).prefix(limit))
    }

    private static func checkedText(_ text: String, field: String) throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw StickerExportError.invalidText("\(field) can't be empty.") }
        return String(trimmed.prefix(128))
    }

    /// Runs `body` for one sticker, naming the sticker in any error, and releases temporaries before the next one.
    private static func named<T>(_ sticker: ExportSticker, _ body: () throws -> T) throws -> T {
        do {
            return try autoreleasepool(invoking: body)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw StickerExportError.stickerFailed(name: sticker.accessibilityText.isEmpty ? "Sticker" : sticker.accessibilityText,
                                                   reason: reason)
        }
    }

    /// Draws `image` aspect-fit and centred on a canvas (transparent, or without alpha when `opaque`).
    static func fit(_ image: CGImage, width: Int, height: Int, margin: Int, opaque: Bool = false) throws -> CGImage {
        guard let context = ImageOps.makeRGBAContext(width: width, height: height, opaque: opaque) else { throw WebPEncodingError.invalidImage }
        let box = CGRect(x: margin, y: margin, width: width - 2 * margin, height: height - 2 * margin)
        let scale = min(box.width / CGFloat(image.width), box.height / CGFloat(image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: box.midX - size.width / 2, y: box.midY - size.height / 2,
                                       width: size.width, height: size.height))
        guard let result = context.makeImage() else { throw WebPEncodingError.invalidImage }
        return result
    }
}

extension Character {
    /// True for characters that render as emoji (including ZWJ sequences and flags), not plain digits or symbols.
    var isStickerEmoji: Bool {
        guard let first = unicodeScalars.first else { return false }
        return first.properties.isEmojiPresentation || (first.properties.isEmoji && unicodeScalars.count > 1)
    }
}
