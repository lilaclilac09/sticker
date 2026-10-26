import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct EncodedSticker: Sendable {
    public let pngData: Data
    public let pixelWidth: Int
    public let pixelHeight: Int
}

public enum StickerEncodingError: LocalizedError, Equatable {
    case invalidImage
    case encodeFailed
    case cannotFitByteLimit(bytes: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidImage: "The image is empty."
        case .encodeFailed: "Couldn't encode the sticker as PNG."
        case let .cannotFitByteLimit(bytes, limit):
            "The sticker is still \(bytes / 1000) KB at the smallest size (limit \(limit / 1000) KB)."
        }
    }
}

/// Size limits for one encode. `.messages` is what MSSticker requires.
public struct StickerCanvas: Sendable, Equatable {
    /// Longest side of the canvas.
    public var maxPixelDimension: Int
    /// Each canvas side is at least this (content is centred on transparent padding). 0 disables padding.
    public var minPixelDimension: Int
    /// How far small content may be scaled up toward `maxPixelDimension` (1 = never upscale).
    public var maxUpscale: Double
    /// PNG byte limit.
    public var maxBytes: Int

    public init(maxPixelDimension: Int, minPixelDimension: Int, maxUpscale: Double, maxBytes: Int) {
        self.maxPixelDimension = maxPixelDimension
        self.minPixelDimension = min(minPixelDimension, maxPixelDimension)
        self.maxUpscale = max(1, maxUpscale)
        self.maxBytes = maxBytes
    }

    public static let messages = StickerCanvas(maxPixelDimension: StickerSpec.maxPixelDimension,
                                               minPixelDimension: StickerSpec.minPixelDimension,
                                               maxUpscale: StickerSpec.maxUpscale,
                                               maxBytes: StickerSpec.maxFileBytes)
}

/// Turns any image into a sticker file: an sRGB 8-bit PNG whose canvas fits the limits.
/// If the PNG is too big, the content shrinks and it tries again, down to `StickerSpec.minContentDimension`.
public enum StickerEncoder {
    public static func encode(_ image: CGImage, canvas: StickerCanvas = .messages) throws -> EncodedSticker {
        guard image.width > 0, image.height > 0 else { throw StickerEncodingError.invalidImage }
        let longest = Double(max(image.width, image.height))
        var scale = min(Double(canvas.maxPixelDimension) / longest, canvas.maxUpscale)
        let sourceIsOpaque = !ImageOps.hasTransparency(image)
        let floor = min(StickerSpec.minContentDimension, Int(longest * scale))
        while true {
            let contentWidth = max(1, Int((Double(image.width) * scale).rounded()))
            let contentHeight = max(1, Int((Double(image.height) * scale).rounded()))
            let width = max(contentWidth, canvas.minPixelDimension)
            let height = max(contentHeight, canvas.minPixelDimension)
            // Photos kept whole have no transparency; storing them without alpha buys 10–15% of the byte budget.
            let opaque = sourceIsOpaque && width == contentWidth && height == contentHeight
            guard let context = ImageOps.makeRGBAContext(width: width, height: height, opaque: opaque) else {
                throw StickerEncodingError.encodeFailed
            }
            // Always redraw, even at 1:1, so wide-gamut / 16-bit / grayscale / CMYK input becomes sRGB 8-bit.
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: (width - contentWidth) / 2, y: (height - contentHeight) / 2,
                                           width: contentWidth, height: contentHeight))
            guard let rendered = context.makeImage() else { throw StickerEncodingError.encodeFailed }
            let data = try pngData(rendered)
            if data.count <= canvas.maxBytes {
                return EncodedSticker(pngData: data, pixelWidth: width, pixelHeight: height)
            }
            let contentLongest = max(contentWidth, contentHeight)
            guard contentLongest > floor else {
                throw StickerEncodingError.cannotFitByteLimit(bytes: data.count, limit: canvas.maxBytes)
            }
            // PNG size grows roughly with pixel count, so scale the side by √(limit/size), with a little margin.
            let ratio = (Double(canvas.maxBytes) / Double(data.count)).squareRoot() * 0.95
            let next = max(Double(floor), min(Double(contentLongest - 1), Double(contentLongest) * ratio))
            scale = next / longest
        }
    }

    public static func pngData(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw StickerEncodingError.encodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw StickerEncodingError.encodeFailed }
        return data as Data
    }
}
