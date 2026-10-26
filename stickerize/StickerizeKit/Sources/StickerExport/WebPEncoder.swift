import CoreGraphics
import Foundation
import libwebp
import StickerizeKit

public enum WebPEncodingError: LocalizedError, Equatable {
    case invalidImage
    case encodeFailed(code: Int)
    case cannotFit(bytes: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidImage: "The image is empty."
        case let .encodeFailed(code): "WebP encoding failed (libwebp error \(code))."
        case let .cannotFit(bytes, limit): "The sticker is \(bytes / 1024) KB as WebP; the limit is \(limit / 1024) KB."
        }
    }
}

/// Minimal libwebp wrapper: straight-alpha RGBA in, lossy (with lossless alpha plane) WebP out. No EXIF or ICC chunks
/// are written (WhatsApp issue #1106: EXIF in WebP broke playback).
public enum WebPEncoder {
    /// Encodes `image` lossily, lowering quality until the file fits `maxBytes`.
    public static func encode(_ image: CGImage, maxBytes: Int, qualities: [Float] = [80, 65, 50, 35]) throws -> Data {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { throw WebPEncodingError.invalidImage }
        let rgba = try straightRGBA(image)
        var smallest = Int.max
        for quality in qualities {
            let data = try encode(rgba: rgba, width: width, height: height, quality: quality)
            if data.count <= maxBytes { return data }
            smallest = min(smallest, data.count)
        }
        throw WebPEncodingError.cannotFit(bytes: smallest, limit: maxBytes)
    }

    static func encode(rgba: [UInt8], width: Int, height: Int, quality: Float) throws -> Data {
        var config = WebPConfig()
        guard WebPConfigPreset(&config, WEBP_PRESET_DEFAULT, quality) != 0 else { throw WebPEncodingError.encodeFailed(code: -1) }
        config.method = 4 // 6 compresses ~5% better but is several times slower, noticeably so in Debug builds
        config.alpha_quality = 100
        guard WebPValidateConfig(&config) != 0 else { throw WebPEncodingError.encodeFailed(code: -2) }

        var picture = WebPPicture()
        guard WebPPictureInit(&picture) != 0 else { throw WebPEncodingError.encodeFailed(code: -3) }
        picture.width = Int32(width)
        picture.height = Int32(height)
        picture.use_argb = 1
        defer { WebPPictureFree(&picture) }

        let writer = UnsafeMutablePointer<WebPMemoryWriter>.allocate(capacity: 1)
        WebPMemoryWriterInit(writer)
        defer {
            WebPMemoryWriterClear(writer)
            writer.deallocate()
        }
        picture.writer = WebPMemoryWrite
        picture.custom_ptr = UnsafeMutableRawPointer(writer)

        let imported = rgba.withUnsafeBufferPointer { WebPPictureImportRGBA(&picture, $0.baseAddress, Int32(width * 4)) }
        guard imported != 0 else { throw WebPEncodingError.encodeFailed(code: Int(picture.error_code.rawValue)) }
        guard WebPEncode(&config, &picture) != 0 else {
            throw WebPEncodingError.encodeFailed(code: Int(picture.error_code.rawValue))
        }
        return Data(bytes: writer.pointee.mem, count: writer.pointee.size)
    }

    /// Un-premultiplied sRGB RGBA bytes (libwebp's import expects straight alpha; CGContext only draws premultiplied).
    static func straightRGBA(_ image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: ImageOps.sRGB,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw WebPEncodingError.invalidImage }
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Int(bytes[index + 3])
            guard alpha != 0, alpha != 255 else { continue }
            for channel in 0..<3 {
                bytes[index + channel] = UInt8(min(255, (Int(bytes[index + channel]) * 255 + alpha / 2) / alpha))
            }
        }
        return bytes
    }
}
