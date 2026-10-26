import StickerizeKit
import XCTest

final class StickerNameTests: XCTestCase {
    func testMeaningfulFileNamesBecomeStickerNames() {
        XCTAssertEqual(StickerName.fromFileName("funny_cat.png"), "funny cat")
        XCTAssertEqual(StickerName.fromFileName("Grumpy Cat.HEIC"), "Grumpy Cat")
        XCTAssertEqual(StickerName.fromFileName("party__parrot  2.webp"), "party parrot 2")
        XCTAssertEqual(StickerName.fromFileName("/tmp/x/thumbs-up.jpg"), "thumbs-up")
        XCTAssertEqual(StickerName.fromFileName("logo.pdf"), "logo")
        XCTAssertEqual(StickerName.fromFileName("v1.5 final"), "v1.5 final", "non-image extensions are kept")
        XCTAssertEqual(StickerName.fromFileName("Dog"), "Dog", "suggested names arrive without an extension")
    }

    func testGeneratedNamesAreIgnored() {
        for name in ["IMG_1234.HEIC", "IMG-5678.jpg", "PXL_20260102_123456789.jpg", "DSC01234.JPG", "GOPR0042.JPG",
                     "Screenshot 2026-10-25 at 20.15.00.png", "Simulator Screenshot - iPhone 18 Pro.png",
                     "image.png", "Photo 3.jpg", "7D2A1C3E-0B4F-4C4D-9E1A-2B3C4D5E6F70.jpeg", "20261025_201500.jpg",
                     "", "   .png"] {
            XCTAssertNil(StickerName.fromFileName(name), name)
        }
        XCTAssertNil(StickerName.fromFileName(nil))
    }

    func testLongNamesAreCappedForMSSticker() {
        let long = String(repeating: "a", count: 300) + ".png"
        XCTAssertEqual(StickerName.fromFileName(long)?.count, StickerSpec.maxNameLength)
    }
}
