import CoreGraphics
import Foundation
import ImageIO
import StickerizeKit
import UniformTypeIdentifiers

/// Synthetic images for tests, so nothing depends on fixtures except the Vision tests.
enum TestImages {
    /// `width`×`height`, left half red, right half blue, opaque.
    static func halves(width: Int, height: Int) -> CGImage {
        let context = ImageOps.makeRGBAContext(width: width, height: height)!
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return context.makeImage()!
    }

    /// Transparent canvas with an opaque square at `rect` (top-left origin).
    static func square(canvas: Int, rect: CGRect) -> CGImage {
        let context = ImageOps.makeRGBAContext(width: canvas, height: canvas)!
        context.setFillColor(CGColor(srgbRed: 0, green: 0.6, blue: 0.2, alpha: 1))
        // Flip to top-left coordinates.
        context.fill(CGRect(x: rect.minX, y: CGFloat(canvas) - rect.maxY, width: rect.width, height: rect.height))
        return context.makeImage()!
    }

    /// Random opaque noise: the worst case for PNG compression.
    static func noise(width: Int, height: Int, seed: UInt64 = 42) -> CGImage {
        let context = ImageOps.makeRGBAContext(width: width, height: height)!
        let base = context.data!.assumingMemoryBound(to: UInt8.self)
        var state = seed
        for y in 0..<height {
            let row = base + y * context.bytesPerRow
            for x in 0..<width {
                for c in 0..<3 {
                    state = state &* 6364136223846793005 &+ 1442695040888963407
                    row[x * 4 + c] = UInt8(truncatingIfNeeded: state >> 56)
                }
                row[x * 4 + 3] = 255
            }
        }
        return context.makeImage()!
    }

    static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any] = [:]) -> Data {
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        precondition(CGImageDestinationFinalize(destination))
        return data as Data
    }

    /// A one-page PDF, `size` points, with a filled rectangle.
    static func pdf(size: CGSize) -> Data {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 10, y: 10, width: size.width - 20, height: size.height - 20))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// RGBA8 of one pixel (top-left origin), un-premultiplied enough for opaque checks.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let context = ImageOps.makeRGBAContext(width: image.width, height: image.height)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let row = context.data!.assumingMemoryBound(to: UInt8.self) + y * context.bytesPerRow
        let p = row + x * 4
        return (p[0], p[1], p[2], p[3])
    }

    static func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("StickerizeKitTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
