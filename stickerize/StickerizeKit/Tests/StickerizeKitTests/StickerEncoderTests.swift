import CoreGraphics
import ImageIO
import StickerizeKit
import XCTest

final class StickerEncoderTests: XCTestCase {
    /// Review finding 5: full-resolution output was over iMessage's 500 KB limit.
    func testNoiseIsShrunkUntilItFitsTheByteLimit() throws {
        let encoded = try StickerEncoder.encode(TestImages.noise(width: 2048, height: 2048))
        XCTAssertLessThanOrEqual(encoded.data.count, StickerSpec.maxFileBytes)
        XCTAssertLessThanOrEqual(max(encoded.pixelWidth, encoded.pixelHeight), StickerSpec.maxPixelDimension)
        // Noise at 618² is ~1.1 MB, so it must have gone below 618 to fit.
        XCTAssertLessThan(encoded.pixelWidth, StickerSpec.maxPixelDimension)
        XCTAssertGreaterThanOrEqual(encoded.pixelWidth, StickerSpec.minPixelDimension)
        try assertPNG(encoded)
    }

    func testFitsLongestSideAndPadsShortSide() throws {
        // 1236×412 → content 618×206, which is under MSSticker's 300 px minimum, so the canvas is 618×300.
        let encoded = try StickerEncoder.encode(TestImages.halves(width: 1236, height: 412))
        XCTAssertEqual(encoded.pixelWidth, 618)
        XCTAssertEqual(encoded.pixelHeight, 300)
        let image = try assertPNG(encoded)
        XCTAssertEqual(TestImages.pixel(image, x: 300, y: 5).a, 0, "padding is transparent")
        XCTAssertEqual(TestImages.pixel(image, x: 300, y: 150).a, 255)
    }

    func testTallCutoutIsPaddedToMinimumWidth() throws {
        // A 100×400 subject: scaled to 155×618, then padded to the 300 px minimum width.
        let image = TestImages.square(canvas: 400, rect: CGRect(x: 150, y: 0, width: 100, height: 400))
        let trimmed = ImageOps.trimTransparent(image)
        XCTAssertEqual(trimmed.width, 100)
        let encoded = try StickerEncoder.encode(trimmed)
        XCTAssertEqual(encoded.pixelWidth, 300)
        XCTAssertEqual(encoded.pixelHeight, 618)
    }

    func testSmallImagesAreUpscaledAtMostThreeTimes() throws {
        let encoded = try StickerEncoder.encode(TestImages.halves(width: 120, height: 80))
        XCTAssertEqual(encoded.pixelWidth, 360)
        XCTAssertEqual(encoded.pixelHeight, 300) // 240 tall content, padded
    }

    func testEveryStickerMeetsMSStickerLimits() throws {
        for (width, height) in [(10, 10), (50, 2000), (2000, 50), (618, 618), (299, 301), (1500, 1000)] {
            let encoded = try StickerEncoder.encode(TestImages.noise(width: width, height: height, seed: UInt64(width * height)))
            XCTAssertGreaterThanOrEqual(min(encoded.pixelWidth, encoded.pixelHeight), 300, "\(width)×\(height)")
            XCTAssertLessThanOrEqual(max(encoded.pixelWidth, encoded.pixelHeight), 618, "\(width)×\(height)")
            XCTAssertLessThanOrEqual(encoded.data.count, 500_000, "\(width)×\(height)")
        }
    }

    func testOpaqueImagesAreStoredWithoutAlpha() throws {
        let encoded = try StickerEncoder.encode(TestImages.noise(width: 400, height: 400))
        let image = try assertPNG(encoded)
        XCTAssertTrue([.none, .noneSkipLast, .noneSkipFirst].contains(image.alphaInfo), "\(image.alphaInfo)")
    }

    func testCustomCanvas() throws {
        let canvas = StickerCanvas(maxPixelDimension: 512, minPixelDimension: 0, maxUpscale: 1, maxBytes: 100_000)
        let encoded = try StickerEncoder.encode(TestImages.noise(width: 512, height: 512), canvas: canvas)
        XCTAssertLessThanOrEqual(encoded.data.count, 100_000)
        XCTAssertLessThan(encoded.pixelWidth, 512)
        let small = try StickerEncoder.encode(TestImages.halves(width: 120, height: 80), canvas: canvas)
        XCTAssertEqual(small.pixelWidth, 120, "no upscaling or padding")
    }

    func testThrowsWhenLimitIsImpossible() {
        let canvas = StickerCanvas(maxPixelDimension: 618, minPixelDimension: 300, maxUpscale: 1, maxBytes: 500)
        XCTAssertThrowsError(try StickerEncoder.encode(TestImages.noise(width: 400, height: 400), canvas: canvas)) { error in
            guard case StickerEncodingError.cannotFitByteLimit = error else { return XCTFail("\(error)") }
        }
    }

    func testOutputIsSRGBWithAlpha() throws {
        // A Display P3 source must come out as sRGB RGBA8.
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 16, bytesPerRow: 0, space: p3,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder16Little.rawValue)!
        context.setFillColor(CGColor(colorSpace: p3, components: [0, 1, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 64))
        let encoded = try StickerEncoder.encode(context.makeImage()!)
        let source = CGImageSourceCreateWithData(encoded.data as CFData, nil)!
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        XCTAssertEqual(image.bitsPerComponent, 8)
        XCTAssertEqual(image.colorSpace?.name, CGColorSpace.sRGB)
        XCTAssertNotEqual(image.alphaInfo, .none)
        XCTAssertEqual(TestImages.pixel(image, x: 60, y: 30).a, 0, "unfilled half stays transparent")
    }

    @discardableResult
    private func assertPNG(_ encoded: EncodedSticker, file: StaticString = #filePath, line: UInt = #line) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(encoded.data as CFData, nil), file: file, line: line)
        XCTAssertEqual(CGImageSourceGetType(source) as String?, "public.png", file: file, line: line)
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil), file: file, line: line)
        XCTAssertEqual(image.width, encoded.pixelWidth, file: file, line: line)
        XCTAssertEqual(image.height, encoded.pixelHeight, file: file, line: line)
        return image
    }
}

final class ImageOpsTests: XCTestCase {
    func testOpaqueBoundsUsesTopLeftOrigin() {
        let image = TestImages.square(canvas: 100, rect: CGRect(x: 10, y: 20, width: 30, height: 40))
        XCTAssertEqual(ImageOps.opaqueBounds(of: image), CGRect(x: 10, y: 20, width: 30, height: 40))
    }

    func testTrimTransparentWithPadding() {
        let image = TestImages.square(canvas: 100, rect: CGRect(x: 10, y: 20, width: 30, height: 40))
        let trimmed = ImageOps.trimTransparent(image, padding: 5)
        XCTAssertEqual(trimmed.width, 40)
        XCTAssertEqual(trimmed.height, 50)
        XCTAssertEqual(TestImages.pixel(trimmed, x: 1, y: 1).a, 0)
        XCTAssertEqual(TestImages.pixel(trimmed, x: 20, y: 25).a, 255)
    }

    func testTrimLeavesOpaqueAndEmptyImagesAlone() {
        let opaque = TestImages.halves(width: 50, height: 30)
        XCTAssertEqual(ImageOps.trimTransparent(opaque).width, 50)
        let empty = ImageOps.makeRGBAContext(width: 20, height: 20)!.makeImage()!
        XCTAssertEqual(ImageOps.trimTransparent(empty).width, 20)
    }

    func testHasTransparency() {
        XCTAssertFalse(ImageOps.hasTransparency(TestImages.halves(width: 20, height: 20)))
        XCTAssertTrue(ImageOps.hasTransparency(TestImages.square(canvas: 20, rect: CGRect(x: 5, y: 5, width: 5, height: 5))))
    }

    func testFittedSize() {
        XCTAssertTrue(ImageOps.fittedSize(width: 1000, height: 500, longestSide: 618) == (618, 309))
        XCTAssertTrue(ImageOps.fittedSize(width: 100, height: 500, longestSide: 618) == (100, 500))
    }
}
