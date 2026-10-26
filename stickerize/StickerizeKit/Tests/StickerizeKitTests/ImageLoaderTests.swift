import CoreGraphics
import ImageIO
import StickerizeKit
import UniformTypeIdentifiers
import XCTest

final class ImageLoaderTests: XCTestCase {
    /// Review finding 3: rotated iPhone photos came out sideways because EXIF orientation was ignored.
    func testAppliesEXIFOrientation() throws {
        // Stored pixels: 80×40, red on the left. Orientation 6 = "rotate 90° clockwise to display".
        let stored = TestImages.halves(width: 80, height: 40)
        let jpeg = TestImages.encode(stored, type: .jpeg, properties: [kCGImagePropertyOrientation: 6])
        let image = try ImageLoader.image(from: jpeg)
        XCTAssertEqual(image.width, 40)
        XCTAssertEqual(image.height, 80)
        // After a clockwise turn the stored left (red) half is on top.
        let top = TestImages.pixel(image, x: 20, y: 5)
        let bottom = TestImages.pixel(image, x: 20, y: 75)
        XCTAssertGreaterThan(top.r, 200); XCTAssertLessThan(top.b, 60)
        XCTAssertGreaterThan(bottom.b, 200); XCTAssertLessThan(bottom.r, 60)
    }

    func testOrientedPixelSizeReadsHeaderOnly() throws {
        let jpeg = TestImages.encode(TestImages.halves(width: 80, height: 40), type: .jpeg, properties: [kCGImagePropertyOrientation: 8])
        let url = TestImages.temporaryDirectory().appendingPathComponent("rotated.jpg")
        try jpeg.write(to: url)
        XCTAssertEqual(ImageLoader.orientedPixelSize(contentsOf: url), CGSize(width: 40, height: 80))
    }

    func testDownsamplesToMaxPixelSize() throws {
        let png = TestImages.encode(TestImages.halves(width: 3000, height: 1000), type: .png)
        let image = try ImageLoader.image(from: png, maxPixelSize: 2048)
        XCTAssertEqual(image.width, 2048)
        XCTAssertEqual(image.height, 683, accuracy: 1)
    }

    func testKeepsSmallImagesAtNativeSize() throws {
        let png = TestImages.encode(TestImages.halves(width: 300, height: 200), type: .png)
        let image = try ImageLoader.image(from: png, maxPixelSize: 2048)
        XCTAssertEqual(image.width, 300)
        XCTAssertEqual(image.height, 200)
    }

    func testFullSizeWhenMaxIsNil() throws {
        let png = TestImages.encode(TestImages.halves(width: 2500, height: 100), type: .png)
        XCTAssertEqual(try ImageLoader.image(from: png, maxPixelSize: nil).width, 2500)
    }

    func testPreservesTransparency() throws {
        let png = TestImages.encode(TestImages.square(canvas: 100, rect: CGRect(x: 25, y: 25, width: 50, height: 50)), type: .png)
        let image = try ImageLoader.image(from: png)
        XCTAssertEqual(TestImages.pixel(image, x: 2, y: 2).a, 0)
        XCTAssertEqual(TestImages.pixel(image, x: 50, y: 50).a, 255)
    }

    func testRendersFirstPDFPageScaledUp() throws {
        let pdf = TestImages.pdf(size: CGSize(width: 200, height: 100))
        let image = try ImageLoader.image(from: pdf, maxPixelSize: 1000)
        XCTAssertEqual(image.width, 1000)
        XCTAssertEqual(image.height, 500)
        XCTAssertGreaterThan(TestImages.pixel(image, x: 500, y: 250).r, 200)
        // Outside the filled rect the page has no background: transparent.
        XCTAssertEqual(TestImages.pixel(image, x: 2, y: 2).a, 0)
    }

    func testPDFFromURL() throws {
        let url = TestImages.temporaryDirectory().appendingPathComponent("page.pdf")
        try TestImages.pdf(size: CGSize(width: 100, height: 300)).write(to: url)
        let image = try ImageLoader.image(contentsOf: url, maxPixelSize: 600)
        XCTAssertEqual(image.width, 200)
        XCTAssertEqual(image.height, 600)
    }

    func testReadabilityCheckUsesHeaderOnly() throws {
        XCTAssertTrue(ImageLoader.isReadable(TestImages.encode(TestImages.halves(width: 20, height: 10), type: .png)))
        XCTAssertTrue(ImageLoader.isReadable(TestImages.pdf(size: CGSize(width: 50, height: 50))))
        XCTAssertFalse(ImageLoader.isReadable(Data("not an image".utf8)))
        XCTAssertTrue(ImageLoader.isReadable(contentsOf: Samples.url("test.jpg")))
        let bogus = TestImages.temporaryDirectory().appendingPathComponent("bogus.png")
        try Data("nope".utf8).write(to: bogus)
        XCTAssertFalse(ImageLoader.isReadable(contentsOf: bogus))
    }

    func testRejectsNonImages() {
        XCTAssertThrowsError(try ImageLoader.image(from: Data("hello".utf8)))
        XCTAssertThrowsError(try ImageLoader.image(from: Data()))
    }

    func testDecodesSamplePhotos() throws {
        for name in ["test.jpg", "test2.jpg", "test3.jpg"] {
            let url = Samples.url(name)
            let image = try ImageLoader.image(contentsOf: url)
            XCTAssertLessThanOrEqual(max(image.width, image.height), StickerSpec.importMaxPixelDimension, name)
        }
    }
}

enum Samples {
    /// `<repo>/stickerize/samples/<name>`, located relative to this source file.
    static func url(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // StickerizeKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // StickerizeKit
            .deletingLastPathComponent() // stickerize
            .appendingPathComponent("samples/\(name)")
    }
}
