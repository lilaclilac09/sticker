import CoreGraphics
import Foundation
import StickerizeKit
import UniformTypeIdentifiers

/// Signal Desktop sticker packs (File → Create/Upload Sticker Pack). Unlike WhatsApp / Telegram there is no
/// pasteboard import API on iOS: you prepare PNG / APNG files on disk and upload them from Signal Desktop.
///
/// Official limits (support.signal.org Stickers article):
/// - up to 200 stickers per pack
/// - each sticker ≤ 300 KB
/// - stills: PNG or WebP; animated: APNG (not GIF)
/// - ~512×512 is the usual canvas
///
/// Typical input: a folder of WeChat favorite stickers from export-wechat-emoji (GIF / JPG / PNG). Originals are
/// never overwritten; output goes to a separate directory, split into pack-01, pack-02, … when needed.
public enum SignalPackExport {
    public static let stickerCount = 1...200
    public static let maxFileBytes = 300 * 1024
    public static let pixelDimension = 512

    public static let canvas = StickerCanvas(maxPixelDimension: pixelDimension, minPixelDimension: 0,
                                             maxUpscale: StickerSpec.maxUpscale, maxBytes: maxFileBytes)

    public struct PreparedSticker: Sendable {
        public let data: Data
        /// `png` for stills, `apng` for animated (both are PNG containers; Signal wants the apng extension for motion).
        public let fileExtension: String
        public let pixelWidth: Int
        public let pixelHeight: Int
        public let animated: Bool
        public let sourceName: String
    }

    public struct PackResult: Sendable {
        public let directory: URL
        public let stickers: [PreparedSticker]
        public let skipped: [(name: String, reason: String)]
    }

    private static let imageExtensions: Set<String> = ["gif", "png", "jpg", "jpeg", "webp", "heic", "heif", "tif", "tiff", "bmp"]

    /// Converts one image (still or animated) into a Signal-ready sticker without writing disk.
    public static func prepare(contentsOf url: URL) throws -> PreparedSticker {
        let name = url.deletingPathExtension().lastPathComponent
        let frameCount = AnimatedImageLoader.frameCount(contentsOf: url)
        if frameCount > 1 {
            let animation = try AnimatedImageLoader.frames(contentsOf: url, maxPixelSize: pixelDimension)
            let encoded = try AnimatedStickerEncoder.encodeAPNG(animation, canvas: canvas)
            return PreparedSticker(data: encoded.data, fileExtension: "apng",
                                   pixelWidth: encoded.pixelWidth, pixelHeight: encoded.pixelHeight,
                                   animated: true, sourceName: name)
        }
        let image = try ImageLoader.image(contentsOf: url, maxPixelSize: pixelDimension * 2)
        let encoded = try StickerEncoder.encode(image, canvas: canvas)
        guard encoded.data.count <= maxFileBytes else {
            throw StickerExportError.pngTooLarge(bytes: encoded.data.count, limit: maxFileBytes)
        }
        return PreparedSticker(data: encoded.data, fileExtension: "png",
                               pixelWidth: encoded.pixelWidth, pixelHeight: encoded.pixelHeight,
                               animated: false, sourceName: name)
    }

    /// Reads every image in `inputDirectory` (non-recursive), converts each, and writes Signal-ready packs under
    /// `outputDirectory` as `pack-01`, `pack-02`, … Never writes into `inputDirectory`.
    @discardableResult
    public static func writePacks(from inputDirectory: URL, to outputDirectory: URL,
                                  maxPerPack: Int = stickerCount.upperBound) throws -> [PackResult] {
        let maxPerPack = min(max(1, maxPerPack), stickerCount.upperBound)
        let inputs = try listImages(in: inputDirectory)
        guard !inputs.isEmpty else {
            throw StickerExportError.invalidText("No images found in \(inputDirectory.path).")
        }

        var prepared: [PreparedSticker] = []
        var skipped: [(String, String)] = []
        for url in inputs {
            do {
                try prepared.append(prepare(contentsOf: url))
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                skipped.append((url.lastPathComponent, reason))
            }
        }
        guard !prepared.isEmpty else {
            throw StickerExportError.invalidText("Every input failed to convert (\(skipped.count) skipped).")
        }

        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        var results: [PackResult] = []
        let packCount = (prepared.count + maxPerPack - 1) / maxPerPack
        for packIndex in 0..<packCount {
            let slice = Array(prepared[(packIndex * maxPerPack)..<min((packIndex + 1) * maxPerPack, prepared.count)])
            let packDir = outputDirectory.appendingPathComponent(String(format: "pack-%02d", packIndex + 1), isDirectory: true)
            try FileManager.default.createDirectory(at: packDir, withIntermediateDirectories: true)
            var written: [PreparedSticker] = []
            for (offset, sticker) in slice.enumerated() {
                let safe = sanitizeFileName(sticker.sourceName)
                let fileName = String(format: "%03d-%@.%@", offset + 1, safe, sticker.fileExtension)
                let dest = packDir.appendingPathComponent(fileName)
                try sticker.data.write(to: dest, options: .atomic)
                written.append(sticker)
            }
            let packSkipped = packIndex == 0 ? skipped : []
            results.append(PackResult(directory: packDir, stickers: written, skipped: packSkipped))
        }
        return results
    }

    public static func listImages(in directory: URL) throws -> [URL] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory,
                                                               includingPropertiesForKeys: [.isRegularFileKey],
                                                               options: [.skipsHiddenFiles])
        return urls.filter { url in
            imageExtensions.contains(url.pathExtension.lowercased())
        }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func sanitizeFileName(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = name.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }.map(String.init).joined()
        let trimmed = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(40)
        return trimmed.isEmpty ? "sticker" : String(trimmed)
    }
}
