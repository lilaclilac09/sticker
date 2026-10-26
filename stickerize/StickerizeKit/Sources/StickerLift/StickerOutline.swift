import CoreGraphics
import CoreImage
import StickerizeKit

/// Die-cut style outline: a solid border following the opaque parts of the image.
public enum StickerOutline {
    /// Returns `image` with an outline `width` pixels wide. The canvas grows by `width` + 2 px on every side so the
    /// border is never clipped, even when the subject touches the edge.
    public static func apply(to image: CGImage, width: Double, color: CGColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)) throws -> CGImage {
        guard width > 0 else { return image }
        let radius = width.rounded(.up)
        let margin = radius + 2
        let input = CIImage(cgImage: image)
        let components = CIColor(cgColor: color)
        // Silhouette: the outline color everywhere, with the input's alpha (CIColorMatrix works on unpremultiplied values).
        let silhouette = input.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: components.alpha),
            "inputBiasVector": CIVector(x: components.red, y: components.green, z: components.blue, w: 0),
        ])
        // Dilate the silhouette (circular maximum filter), then put the original on top.
        let border = silhouette.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: radius])
        let canvas = input.extent.insetBy(dx: -margin, dy: -margin)
        let output = input.composited(over: border).cropped(to: canvas)
        guard let result = SharedCIContext.context.createCGImage(output, from: canvas, format: .RGBA8, colorSpace: ImageOps.sRGB) else {
            throw SubjectLiftError.renderFailed
        }
        return result
    }
}
