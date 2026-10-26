import CoreGraphics
import Foundation
import StickerizeKit

/// Everything the editor lets the user choose for one sticker.
public struct StickerRecipe: Sendable, Equatable {
    /// Cut out the subject with Vision. Ignored when no analysis is available.
    public var removeBackground: Bool
    /// Instances to keep; nil keeps every detected instance.
    public var instances: IndexSet?
    /// Trim transparent margins (works for cut-outs and for already-transparent imports).
    public var cropToSubject: Bool
    /// Outline width as a fraction of the sticker's longest side; 0 means no outline. 0.02 ≈ 12 px on a 618 px sticker.
    public var outlineFraction: Double

    public init(removeBackground: Bool = true, instances: IndexSet? = nil, cropToSubject: Bool = true, outlineFraction: Double = 0) {
        self.removeBackground = removeBackground
        self.instances = instances
        self.cropToSubject = cropToSubject
        self.outlineFraction = outlineFraction
    }
}

public enum StickerMaker {
    /// Applies the recipe at working resolution and returns the unencoded result.
    public static func render(_ image: CGImage, analysis: SubjectAnalysis?, recipe: StickerRecipe) throws -> CGImage {
        var result = image
        if recipe.removeBackground, let analysis {
            result = try analysis.render(instances: recipe.instances ?? analysis.allInstanceIDs)
        }
        if recipe.cropToSubject {
            result = ImageOps.trimTransparent(result)
        }
        if recipe.outlineFraction > 0 {
            let width = recipe.outlineFraction * Double(max(result.width, result.height))
            result = try StickerOutline.apply(to: result, width: max(1, width))
        }
        return result
    }

    /// Renders and normalizes to the sticker limits (by default MSSticker's: 300–618 px canvas, ≤ 500 KB PNG).
    public static func make(_ image: CGImage, analysis: SubjectAnalysis?, recipe: StickerRecipe,
                            canvas: StickerCanvas = .messages) throws -> EncodedSticker {
        try StickerEncoder.encode(render(image, analysis: analysis, recipe: recipe), canvas: canvas)
    }
}
