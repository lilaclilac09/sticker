import CoreGraphics
import Foundation
import ImageIO
import StickerExport
import StickerizeKit
import XCTest

final class StickerExportTests: XCTestCase {
    private func sticker(_ seed: UInt64 = 1, width: Int = 400, height: Int = 300) -> ExportSticker {
        ExportSticker(image: noiseBlob(width: width, height: height, seed: seed), emojis: ["😀"], accessibilityText: "A blob")
    }

    func testWhatsAppStickerIs512WebPUnder100KB() throws {
        let data = try StickerPackExport.whatsAppStickerWebP(noiseBlob(width: 618, height: 618, seed: 7))
        XCTAssertLessThanOrEqual(data.count, 100 * 1024)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "org.webmproject.webp")
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(image.width, 512)
        XCTAssertEqual(image.height, 512)
        XCTAssertEqual(alpha(image, x: 2, y: 2), 0, "margin stays transparent")
        XCTAssertGreaterThan(alpha(image, x: 256, y: 256), 200)
        XCTAssertFalse(riffChunks(data).contains("EXIF"))
    }

    func testTrayIs96PNG() throws {
        let data = try StickerPackExport.trayPNG(noiseBlob(width: 300, height: 500, seed: 3))
        XCTAssertLessThanOrEqual(data.count, 50 * 1024)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(data as CFData, nil)!, 0, nil))
        XCTAssertEqual(image.width, 96)
        XCTAssertEqual(image.height, 96)
    }

    func testWhatsAppPayloadShape() throws {
        let payload = try StickerPackExport.whatsApp([sticker(1), sticker(2), sticker(3)], name: "My pack", publisher: "Me",
                                                    identifier: "pack-1")
        XCTAssertEqual(payload.pasteboardType, "net.whatsapp.third-party.sticker-pack")
        XCTAssertEqual(payload.openURL.absoluteString, "whatsapp://stickerPack")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload.data) as? [String: Any])
        XCTAssertEqual(json["identifier"] as? String, "pack-1")
        XCTAssertEqual(json["name"] as? String, "My pack")
        XCTAssertEqual(json["publisher"] as? String, "Me")
        XCTAssertNotNil(Data(base64Encoded: json["tray_image"] as? String ?? ""))
        let stickers = try XCTUnwrap(json["stickers"] as? [[String: Any]])
        XCTAssertEqual(stickers.count, 3)
        XCTAssertEqual(stickers[0]["emojis"] as? [String], ["😀"])
        XCTAssertEqual(stickers[0]["accessibility_text"] as? String, "A blob")
        let webp = try XCTUnwrap(Data(base64Encoded: stickers[0]["image_data"] as? String ?? ""))
        XCTAssertEqual(webp.prefix(4), Data("RIFF".utf8))
    }

    func testWhatsAppRejectsTooFewStickersAndBlankNames() {
        XCTAssertThrowsError(try StickerPackExport.whatsApp([sticker(), sticker()], name: "x", publisher: "y"))
        XCTAssertThrowsError(try StickerPackExport.whatsApp([sticker(1), sticker(2), sticker(3)], name: "  ", publisher: "y"))
    }

    func testTelegramPayloadShape() throws {
        let tall = ExportSticker(image: noiseBlob(width: 200, height: 400, seed: 4), emojis: [], accessibilityText: "")
        let payload = try StickerPackExport.telegram([tall])
        XCTAssertEqual(payload.pasteboardType, "org.telegram.third-party.stickerset")
        XCTAssertEqual(payload.openURL.absoluteString, "tg://importStickers")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: payload.data) as? [String: Any])
        XCTAssertEqual(json["isAnimated"] as? Bool, false)
        XCTAssertEqual(json["isVideo"] as? Bool, false)
        let thumbnail = try XCTUnwrap(json["thumbnail"] as? [String: Any])
        XCTAssertEqual(thumbnail["mimeType"] as? String, "image/png")
        let entry = try XCTUnwrap((json["stickers"] as? [[String: Any]])?.first)
        XCTAssertEqual(entry["mimeType"] as? String, "image/png")
        XCTAssertEqual(entry["emojis"] as? [String], [StickerPackExport.defaultEmoji], "Telegram needs at least one emoji")
        let png = try XCTUnwrap(Data(base64Encoded: entry["data"] as? String ?? ""))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png as CFData, nil)!, 0, nil))
        XCTAssertEqual(max(image.width, image.height), 512)
        XCTAssertLessThanOrEqual(png.count, 512 * 1024)
    }

    /// Review finding: a dense sticker the app stored at ~430 px became a 663 KB PNG when scaled back up to 512.
    func testTelegramPNGFitsLimitForDenseStickers() throws {
        // 2048² noise is stored at ~428 px; 600² noise at ~391 px (the verifier's case that a fixed ladder missed).
        for (seed, side, opaque) in [(UInt64(11), 2048, true), (12, 2048, false), (13, 600, true)] {
            let stored = try StickerEncoder.encode(opaque ? noise(width: side, height: side, seed: seed)
                                                          : noiseBlob(width: side, height: side, seed: seed))
            let reloaded = try ImageLoader.image(from: stored.data)
            let png = try StickerPackExport.telegramStickerPNG(reloaded)
            XCTAssertLessThanOrEqual(png.count, 512 * 1024)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(png as CFData, nil)!, 0, nil))
            XCTAssertEqual(max(image.width, image.height), 512)
        }
    }

    func testPerStickerErrorsNameTheSticker() {
        let broken = ExportSticker(source: .file(URL(fileURLWithPath: "/nonexistent/x.png")), emojis: [], accessibilityText: "Cat")
        XCTAssertThrowsError(try StickerPackExport.telegram([broken])) { error in
            guard case let StickerExportError.stickerFailed(name, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(name, "Cat")
        }
    }

    func testEmojiExtraction() {
        XCTAssertEqual(StickerPackExport.emojis(in: "cat 🐱 dog 🐶 👍🏽 🇯🇵 ❤️"), ["🐱", "🐶", "👍🏽"])
        XCTAssertEqual(StickerPackExport.emojis(in: "123 abc #"), [])
        XCTAssertEqual(StickerPackExport.emojis(in: "👨‍👩‍👧 🇯🇵", limit: 5), ["👨‍👩‍👧", "🇯🇵"])
    }

    // MARK: Helpers

    /// An opaque noisy ellipse on a transparent background: realistic for size limits and transparency checks.
    private func noiseBlob(width: Int, height: Int, seed: UInt64) -> CGImage {
        let context = ImageOps.makeRGBAContext(width: width, height: height)!
        let base = context.data!.assumingMemoryBound(to: UInt8.self)
        var state = seed
        for y in 0..<height {
            for x in 0..<width {
                let dx = (Double(x) - Double(width) / 2) / (Double(width) / 2)
                let dy = (Double(y) - Double(height) / 2) / (Double(height) / 2)
                guard dx * dx + dy * dy <= 1 else { continue }
                let pixel = base + y * context.bytesPerRow + x * 4
                for channel in 0..<3 {
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    pixel[channel] = UInt8(truncatingIfNeeded: state >> 56)
                }
                pixel[3] = 255
            }
        }
        return context.makeImage()!
    }

    private func noise(width: Int, height: Int, seed: UInt64) -> CGImage {
        let context = ImageOps.makeRGBAContext(width: width, height: height)!
        let base = context.data!.assumingMemoryBound(to: UInt8.self)
        var state = seed
        for y in 0..<height {
            for x in 0..<width {
                let pixel = base + y * context.bytesPerRow + x * 4
                for channel in 0..<3 {
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    pixel[channel] = UInt8(truncatingIfNeeded: state >> 56)
                }
                pixel[3] = 255
            }
        }
        return context.makeImage()!
    }

    private func alpha(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        let context = ImageOps.makeRGBAContext(width: image.width, height: image.height)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (context.data!.assumingMemoryBound(to: UInt8.self) + y * context.bytesPerRow + x * 4)[3]
    }

    private func riffChunks(_ data: Data) -> [String] {
        var chunks: [String] = []
        var index = 12
        let bytes = [UInt8](data)
        while index + 8 <= bytes.count {
            chunks.append(String(bytes: bytes[index..<index + 4], encoding: .ascii) ?? "?")
            let length = Int(bytes[index + 4]) | Int(bytes[index + 5]) << 8 | Int(bytes[index + 6]) << 16 | Int(bytes[index + 7]) << 24
            index += 8 + length + (length & 1)
        }
        return chunks
    }

    func testSignalStillIsPNGUnder300KB() throws {
        let url = try writeTempPNG(noiseBlob(width: 600, height: 400, seed: 21), name: "still")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let prepared = try SignalPackExport.prepare(contentsOf: url)
        XCTAssertFalse(prepared.animated)
        XCTAssertEqual(prepared.fileExtension, "png")
        XCTAssertLessThanOrEqual(prepared.data.count, SignalPackExport.maxFileBytes)
        XCTAssertLessThanOrEqual(max(prepared.pixelWidth, prepared.pixelHeight), SignalPackExport.pixelDimension)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(prepared.data as CFData, nil)!, 0, nil))
        XCTAssertEqual(image.width, prepared.pixelWidth)
    }

    func testSignalAnimatedIsAPNGUnder300KB() throws {
        let url = try writeTempGIF(frames: 6, seed: 22)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let prepared = try SignalPackExport.prepare(contentsOf: url)
        XCTAssertTrue(prepared.animated)
        XCTAssertEqual(prepared.fileExtension, "apng")
        XCTAssertLessThanOrEqual(prepared.data.count, SignalPackExport.maxFileBytes)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(prepared.data as CFData, nil))
        XCTAssertGreaterThan(CGImageSourceGetCount(source), 1)
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png")
    }

    func testSignalWritePacksSplitsAndSkipsInputDir() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("signal-pack-\(UUID().uuidString)", isDirectory: true)
        let input = root.appendingPathComponent("in", isDirectory: true)
        let output = root.appendingPathComponent("out", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: input, withIntermediateDirectories: true)
        for i in 1...5 {
            _ = try writeTempPNG(noiseBlob(width: 320, height: 320, seed: UInt64(i)), name: "s\(i)", directory: input)
        }
        let results = try SignalPackExport.writePacks(from: input, to: output, maxPerPack: 2)
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.map(\.stickers.count), [2, 2, 1])
        for result in results {
            XCTAssertTrue(result.directory.path.hasPrefix(output.path))
            XCTAssertFalse(result.directory.path.hasPrefix(input.path + "/"))
            let files = try FileManager.default.contentsOfDirectory(at: result.directory, includingPropertiesForKeys: nil)
            XCTAssertEqual(files.count, result.stickers.count)
            for file in files {
                XCTAssertEqual(file.pathExtension, "png")
                let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
                XCTAssertLessThanOrEqual(attrs[.size] as! Int, SignalPackExport.maxFileBytes)
            }
        }
        // Originals untouched: still 5 files in input.
        XCTAssertEqual(try SignalPackExport.listImages(in: input).count, 5)
    }

    func testSignalRejectsOutputInsideInput() throws {
        // Covered by the CLI; library just needs listImages sorted.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("signal-list-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try writeTempPNG(noiseBlob(width: 64, height: 64, seed: 1), name: "b", directory: root)
        _ = try writeTempPNG(noiseBlob(width: 64, height: 64, seed: 2), name: "a", directory: root)
        let names = try SignalPackExport.listImages(in: root).map(\.lastPathComponent)
        XCTAssertEqual(names, ["a.png", "b.png"])
    }

    private func writeTempPNG(_ image: CGImage, name: String, directory: URL? = nil) throws -> URL {
        let dir = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent("signal-one-\(UUID().uuidString)", isDirectory: true)
        if directory == nil { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let url = dir.appendingPathComponent("\(name).png")
        try StickerEncoder.pngData(image).write(to: url)
        return url
    }

    private func writeTempGIF(frames: Int, seed: UInt64) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("signal-gif-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var images: [CGImage] = []
        var delays: [Double] = []
        for i in 0..<frames {
            images.append(noiseBlob(width: 200, height: 200, seed: seed &+ UInt64(i)))
            delays.append(0.1)
        }
        let data = try AnimatedStickerEncoder.gifData(frames: images, delays: delays, loopCount: 0)
        let url = dir.appendingPathComponent("anim.gif")
        try data.write(to: url)
        return url
    }
}
