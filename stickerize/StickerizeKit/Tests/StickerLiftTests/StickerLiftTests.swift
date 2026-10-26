import CoreGraphics
import Foundation
import ImageIO
import StickerizeKit
import StickerLift
import UniformTypeIdentifiers
import XCTest

final class SubjectLifterTests: XCTestCase {
    private func analyze(_ name: String, maxPixelSize: Int? = nil) throws -> SubjectAnalysis {
        let image = try ImageLoader.image(contentsOf: sampleURL(name), maxPixelSize: maxPixelSize)
        do {
            return try SubjectLifter.analyze(image)
        } catch SubjectLiftError.unavailable(let reason) {
            throw XCTSkip("Vision foreground instance masks unavailable here: \(reason)")
        }
    }

    /// Review finding 1: --list reported boxes in the 512×512 mask grid instead of image pixels.
    /// The reported box must now match the cut-out the same instance produces.
    func testBoundingBoxesAreInImagePixels() throws {
        let analysis = try analyze("test3.jpg")
        XCTAssertEqual(analysis.image.width, 960)
        XCTAssertGreaterThanOrEqual(analysis.instances.count, 2)
        for instance in analysis.instances {
            let cutout = try analysis.render(instances: [instance.id])
            let opaque = try XCTUnwrap(ImageOps.opaqueBounds(of: cutout, threshold: 127))
            // The label map is coarser than the image, so allow a few pixels of slack per edge.
            let slack = 2 * Double(analysis.image.width) / 512 + 2
            XCTAssertEqual(instance.boundingBox.minX, opaque.minX, accuracy: slack, "instance \(instance.id)")
            XCTAssertEqual(instance.boundingBox.minY, opaque.minY, accuracy: slack, "instance \(instance.id)")
            XCTAssertEqual(instance.boundingBox.maxX, opaque.maxX, accuracy: slack, "instance \(instance.id)")
            XCTAssertEqual(instance.boundingBox.maxY, opaque.maxY, accuracy: slack, "instance \(instance.id)")
        }
    }

    func testAsyncAnalysisMatchesSyncAndHonoursCancellation() async throws {
        let image = try ImageLoader.image(contentsOf: sampleURL("test3.jpg"), maxPixelSize: nil)
        do {
            let analysis = try await SubjectLifter.analyze(image)
            XCTAssertEqual(analysis.instances.count, try analyzeSynchronously(image).instances.count)
        } catch SubjectLiftError.unavailable(let reason) {
            throw XCTSkip(reason)
        }
        let task = Task { try await SubjectLifter.analyze(image) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled analysis must not return a result")
        } catch is CancellationError {
            // expected
        }
    }

    func testCutoutHasTransparentBackground() throws {
        let analysis = try analyze("test.jpg")
        let cutout = try analysis.render(instances: analysis.allInstanceIDs)
        XCTAssertEqual(cutout.width, analysis.image.width)
        XCTAssertEqual(pixel(cutout, x: 2, y: 2).a, 0)
        let box = try XCTUnwrap(analysis.instances.first).boundingBox
        XCTAssertEqual(pixel(cutout, x: Int(box.midX), y: Int(box.midY)).a, 255)
    }

    func testHitTestingFindsTheInstanceUnderAPoint() throws {
        let analysis = try analyze("test3.jpg")
        for instance in analysis.instances {
            // Sample a column through the box centre: some point there must belong to the instance.
            let box = instance.boundingBox
            let hits = stride(from: box.minY, to: box.maxY, by: 4).compactMap { y in
                analysis.instanceID(atNormalizedPoint: CGPoint(x: box.midX / Double(analysis.image.width),
                                                               y: y / Double(analysis.image.height)))
            }
            XCTAssertTrue(hits.contains(instance.id), "instance \(instance.id)")
        }
        XCTAssertNil(analysis.instanceID(atNormalizedPoint: CGPoint(x: 0.01, y: 0.01)))
        XCTAssertNil(analysis.instanceID(atNormalizedPoint: CGPoint(x: 2, y: 0.5)))
    }

    func testOverlayMatchesLabelMap() throws {
        let analysis = try analyze("test3.jpg")
        let overlay = try XCTUnwrap(analysis.overlay(selected: analysis.allInstanceIDs))
        XCTAssertGreaterThan(overlay.width, 0)
        XCTAssertNotNil(ImageOps.opaqueBounds(of: overlay, threshold: 1))
    }

    func testUnknownInstanceIsRejected() throws {
        let analysis = try analyze("test3.jpg")
        XCTAssertThrowsError(try analysis.render(instances: [99]))
        XCTAssertThrowsError(try analysis.render(instances: []))
    }

    /// The whole pipeline on the sample that used to be 1280×973 / 744 KB.
    func testRecipeProducesValidSticker() throws {
        let analysis = try analyze("test2.jpg", maxPixelSize: StickerSpec.importMaxPixelDimension)
        let encoded = try StickerMaker.make(analysis.image, analysis: analysis, recipe: StickerRecipe(outlineFraction: 0.02))
        XCTAssertLessThanOrEqual(encoded.data.count, StickerSpec.maxFileBytes)
        XCTAssertEqual(max(encoded.pixelWidth, encoded.pixelHeight), StickerSpec.maxPixelDimension)
        XCTAssertGreaterThanOrEqual(min(encoded.pixelWidth, encoded.pixelHeight), StickerSpec.minPixelDimension)
    }

    func testSubsetRecipeIsNarrowerThanAll() throws {
        let analysis = try analyze("test3.jpg")
        let ids = analysis.instances.map(\.id)
        let all = try StickerMaker.render(analysis.image, analysis: analysis, recipe: StickerRecipe())
        let one = try StickerMaker.render(analysis.image, analysis: analysis, recipe: StickerRecipe(instances: [ids[0]]))
        XCTAssertLessThan(one.width, all.width)
    }

    /// Review finding 3 end to end: a rotated JPEG is lifted upright.
    func testRotatedInputIsLiftedUpright() throws {
        let original = try ImageLoader.image(contentsOf: sampleURL("test.jpg"), maxPixelSize: 1024)
        // Store the pixels rotated 90° counter-clockwise and tag orientation 6 so a correct decoder turns them back.
        let rotated = try XCTUnwrap(rotateCounterClockwise(original))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, rotated, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let decoded = try ImageLoader.image(from: data as Data)
        XCTAssertEqual(decoded.width, original.width)
        XCTAssertEqual(decoded.height, original.height)
        let analysis: SubjectAnalysis
        do { analysis = try SubjectLifter.analyze(decoded) } catch SubjectLiftError.unavailable(let reason) { throw XCTSkip(reason) }
        let reference = try analyze("test.jpg", maxPixelSize: 1024)
        let a = try XCTUnwrap(analysis.instances.max { $0.areaFraction < $1.areaFraction }).boundingBox
        let b = try XCTUnwrap(reference.instances.max { $0.areaFraction < $1.areaFraction }).boundingBox
        // Same subject, same place (portrait person stays portrait).
        XCTAssertGreaterThan(a.height, a.width)
        XCTAssertEqual(a.midX, b.midX, accuracy: 20)
        XCTAssertEqual(a.midY, b.midY, accuracy: 20)
    }
}

final class StickerOutlineTests: XCTestCase {
    func testOutlineGrowsCanvasAndPaintsBorder() throws {
        let image = square(canvas: 100, rect: CGRect(x: 0, y: 0, width: 100, height: 100))
        let outlined = try StickerOutline.apply(to: image, width: 10)
        XCTAssertEqual(outlined.width, 124) // 100 + 2 × (10 + 2)
        XCTAssertEqual(outlined.height, 124)
        let border = pixel(outlined, x: 62, y: 5) // 7 px outside the square, inside the 10 px border
        XCTAssertGreaterThan(border.a, 250)
        XCTAssertGreaterThan(border.r, 250); XCTAssertGreaterThan(border.g, 250); XCTAssertGreaterThan(border.b, 250)
        XCTAssertEqual(pixel(outlined, x: 0, y: 0).a, 0, "corner beyond the rounded border is clear")
        let inside = pixel(outlined, x: 62, y: 62)
        XCTAssertLessThan(inside.r, 30, "subject stays on top")
    }

    func testZeroWidthIsIdentity() throws {
        let image = square(canvas: 20, rect: CGRect(x: 5, y: 5, width: 10, height: 10))
        XCTAssertEqual(try StickerOutline.apply(to: image, width: 0).width, 20)
    }

    func testRecipeOutlineWithoutVision() throws {
        // Background removal off: crop trims the transparent margin, then the outline is added.
        let image = square(canvas: 200, rect: CGRect(x: 50, y: 50, width: 100, height: 100))
        let rendered = try StickerMaker.render(image, analysis: nil, recipe: StickerRecipe(removeBackground: true, outlineFraction: 0.05))
        XCTAssertEqual(rendered.width, 100 + 2 * (5 + 2))
    }
}

// MARK: - Helpers

/// The synchronous overload; inside an async test the compiler would pick the async one.
private func analyzeSynchronously(_ image: CGImage) throws -> SubjectAnalysis {
    try SubjectLifter.analyze(image)
}

private func sampleURL(_ name: String) -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("samples/\(name)")
}

private func square(canvas: Int, rect: CGRect) -> CGImage {
    let context = ImageOps.makeRGBAContext(width: canvas, height: canvas)!
    context.setFillColor(CGColor(srgbRed: 0, green: 0.3, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: rect.minX, y: CGFloat(canvas) - rect.maxY, width: rect.width, height: rect.height))
    return context.makeImage()!
}

private func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
    let context = ImageOps.makeRGBAContext(width: image.width, height: image.height)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let p = context.data!.assumingMemoryBound(to: UInt8.self) + y * context.bytesPerRow + x * 4
    return (p[0], p[1], p[2], p[3])
}

private func rotateCounterClockwise(_ image: CGImage) -> CGImage? {
    // CG space is y-up: rotating by +90° and shifting right puts the image's top edge on the left (counter-clockwise).
    let context = ImageOps.makeRGBAContext(width: image.height, height: image.width)
    context?.translateBy(x: CGFloat(image.height), y: 0)
    context?.rotate(by: .pi / 2)
    context?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return context?.makeImage()
}
