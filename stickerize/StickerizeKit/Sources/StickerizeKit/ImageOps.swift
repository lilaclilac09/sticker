import CoreGraphics
import Foundation

/// Small CoreGraphics helpers shared by the encoder, the lifter and the extensions.
public enum ImageOps {
    public static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    /// 8-bit premultiplied RGBA in sRGB: the one pixel format everything is normalized to.
    /// `opaque` drops the alpha channel (RGBX), which makes PNGs of photos 10–15% smaller.
    public static func makeRGBAContext(width: Int, height: Int, opaque: Bool = false) -> CGContext? {
        let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                         bitmapInfo: alpha.rawValue)
    }

    /// Redraws `image` into sRGB RGBA8 at the given size with high-quality resampling.
    public static func redraw(_ image: CGImage, width: Int, height: Int, opaque: Bool = false) -> CGImage? {
        guard width > 0, height > 0, let context = makeRGBAContext(width: width, height: height, opaque: opaque) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// Size that fits `longestSide` while keeping the aspect ratio (never upscales).
    public static func fittedSize(width: Int, height: Int, longestSide: Int) -> (width: Int, height: Int) {
        let longest = max(width, height)
        guard longest > longestSide else { return (width, height) }
        let scale = Double(longestSide) / Double(longest)
        return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
    }

    /// Bounding box (top-left origin, pixels) of the pixels whose alpha exceeds `threshold`, or nil if none do.
    public static func opaqueBounds(of image: CGImage, threshold: UInt8 = 8) -> CGRect? {
        let width = image.width, height = image.height
        guard let context = makeRGBAContext(width: width, height: height) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let base = context.data else { return nil }
        let bytesPerRow = context.bytesPerRow
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var minX = width, minY = height, maxX = -1, maxY = -1
        // Bitmap contexts store the top row first, so row index == top-left y.
        for y in 0..<height {
            let row = pixels + y * bytesPerRow
            for x in 0..<width where row[x * 4 + 3] > threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Crops away fully transparent margins, keeping `padding` pixels of transparent border.
    /// Returns the image unchanged if it has no transparent margin or is fully transparent.
    public static func trimTransparent(_ image: CGImage, padding: Int = 0, threshold: UInt8 = 8) -> CGImage {
        guard let bounds = opaqueBounds(of: image, threshold: threshold) else { return image }
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        if bounds == full && padding == 0 { return image }
        guard let cropped = image.cropping(to: bounds) else { return image }
        return padding > 0 ? (padded(cropped, by: padding) ?? cropped) : cropped
    }

    /// Adds a transparent border of `amount` pixels on every side.
    public static func padded(_ image: CGImage, by amount: Int) -> CGImage? {
        let width = image.width + 2 * amount, height = image.height + 2 * amount
        guard let context = makeRGBAContext(width: width, height: height) else { return nil }
        context.draw(image, in: CGRect(x: amount, y: amount, width: image.width, height: image.height))
        return context.makeImage()
    }

    /// True if any pixel is not fully opaque.
    public static func hasTransparency(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: break
        }
        guard let context = makeRGBAContext(width: image.width, height: image.height) else { return true }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let base = context.data?.assumingMemoryBound(to: UInt8.self) else { return true }
        for y in 0..<image.height {
            let row = base + y * context.bytesPerRow
            for x in 0..<image.width where row[x * 4 + 3] < 255 { return true }
        }
        return false
    }
}
