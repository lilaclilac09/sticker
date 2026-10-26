import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ImageLoadingError: LocalizedError, Equatable {
    case unreadable
    case emptyDocument

    public var errorDescription: String? {
        switch self {
        case .unreadable: "The file isn't an image this device can read."
        case .emptyDocument: "The document has no pages."
        }
    }
}

/// Decodes any ImageIO-readable image (JPEG, HEIC, PNG, GIF, TIFF, WebP, RAW, …) or page 1 of a PDF into an upright
/// `CGImage`. EXIF/TIFF orientation is applied, and the result is downsampled while decoding so the longest side
/// is at most `maxPixelSize`. Pass `nil` to decode at full size.
public enum ImageLoader {
    public static func image(from data: Data, maxPixelSize: Int? = StickerSpec.importMaxPixelDimension) throws -> CGImage {
        if isPDF(data) {
            guard let provider = CGDataProvider(data: data as CFData),
                  let document = CGPDFDocument(provider) else { throw ImageLoadingError.unreadable }
            return try render(document, maxPixelSize: maxPixelSize)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            throw ImageLoadingError.unreadable
        }
        return try image(from: source, maxPixelSize: maxPixelSize)
    }

    public static func image(contentsOf url: URL, maxPixelSize: Int? = StickerSpec.importMaxPixelDimension) throws -> CGImage {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
            guard let document = CGPDFDocument(url as CFURL) else { throw ImageLoadingError.unreadable }
            return try render(document, maxPixelSize: maxPixelSize)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            throw ImageLoadingError.unreadable
        }
        return try image(from: source, maxPixelSize: maxPixelSize)
    }

    /// Whether `data` looks decodable, from the header alone (no pixels are decoded).
    public static func isReadable(_ data: Data) -> Bool {
        if isPDF(data) {
            return CGDataProvider(data: data as CFData).flatMap(CGPDFDocument.init)?.numberOfPages ?? 0 > 0
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else { return false }
        return CGImageSourceGetCount(source) > 0 && orientedPixelSize(of: source, at: CGImageSourceGetPrimaryImageIndex(source)) != nil
    }

    /// Whether the file looks decodable, from the header alone.
    public static func isReadable(contentsOf url: URL) -> Bool {
        if UTType(filenameExtension: url.pathExtension)?.conforms(to: .pdf) == true {
            return (CGPDFDocument(url as CFURL)?.numberOfPages ?? 0) > 0
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return false }
        return CGImageSourceGetCount(source) > 0 && orientedPixelSize(of: source, at: CGImageSourceGetPrimaryImageIndex(source)) != nil
    }

    /// Cheap decode for grids. Returns nil instead of throwing.
    public static func thumbnail(contentsOf url: URL, maxPixelSize: Int) -> CGImage? {
        try? image(contentsOf: url, maxPixelSize: maxPixelSize)
    }

    /// Pixel size after orientation is applied, read from the header without decoding.
    public static func orientedPixelSize(contentsOf url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        return orientedPixelSize(of: source, at: CGImageSourceGetPrimaryImageIndex(source))
    }

    // MARK: - Private

    private static var sourceOptions: CFDictionary { [kCGImageSourceShouldCache: false] as CFDictionary }

    private static func isPDF(_ data: Data) -> Bool {
        data.prefix(5).elementsEqual("%PDF-".utf8)
    }

    private static func image(from source: CGImageSource, maxPixelSize: Int?) throws -> CGImage {
        guard CGImageSourceGetCount(source) > 0 else { throw ImageLoadingError.unreadable }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let size = orientedPixelSize(of: source, at: index) else { throw ImageLoadingError.unreadable }
        let longest = Int(max(size.width, size.height))
        // The thumbnail API applies orientation and resamples while decoding. Capping the requested size at the real
        // size keeps small images at 1:1 instead of letting ImageIO pick an embedded preview or upscale.
        let target = min(maxPixelSize ?? longest, longest)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(target, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
            throw ImageLoadingError.unreadable
        }
        return image
    }

    private static func orientedPixelSize(of source: CGImageSource, at index: Int) -> CGSize? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        // Orientations 5–8 rotate by 90°, swapping width and height.
        return orientation >= 5 ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }

    /// Renders page 1 of a PDF on a transparent background, scaled so its longest side is `maxPixelSize`
    /// (PDFs are vector, so small pages are scaled up rather than kept at their point size).
    private static func render(_ document: CGPDFDocument, maxPixelSize: Int?) throws -> CGImage {
        guard let page = document.page(at: 1) else { throw ImageLoadingError.emptyDocument }
        let box = page.getBoxRect(.cropBox)
        let rotated = page.rotationAngle % 180 != 0
        let pageSize = rotated ? CGSize(width: box.height, height: box.width) : box.size
        guard pageSize.width > 0, pageSize.height > 0 else { throw ImageLoadingError.unreadable }
        let longest = CGFloat(maxPixelSize ?? StickerSpec.importMaxPixelDimension)
        let scale = longest / max(pageSize.width, pageSize.height)
        let width = max(1, Int((pageSize.width * scale).rounded()))
        let height = max(1, Int((pageSize.height * scale).rounded()))
        guard let context = ImageOps.makeRGBAContext(width: width, height: height) else {
            throw ImageLoadingError.unreadable
        }
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(width) / pageSize.width, y: CGFloat(height) / pageSize.height)
        // getDrawingTransform never scales up, so it is asked for a rect the size of the page and scaled above.
        context.concatenate(page.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: pageSize),
                                                     rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(page)
        guard let image = context.makeImage() else { throw ImageLoadingError.unreadable }
        return image
    }
}
