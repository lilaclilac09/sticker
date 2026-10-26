import Foundation

/// Limits every saved sticker is normalized to. From the iOS 27.2 SDK, Messages.framework MSSticker.h:
/// "The specified file must have a maximum size of 500KB and must conform to kUTTypePNG, kUTTypeGIF or kUTTypeJPEG.
/// The image loaded from the file must be no smaller than 300px X 300px and must be no larger 618px x 618px.
/// This localized description string is limited to 150 Unicode characters in length."
/// MSSticker's initializer doesn't enforce any of this (it accepts 100×100 and 1.3 MB files), so we must.
public enum StickerSpec {
    /// Longest side of a saved sticker, in pixels.
    public static let maxPixelDimension = 618

    /// Each side of the canvas is at least this; smaller content is centred on transparent padding.
    public static let minPixelDimension = 300

    /// Small images are scaled up toward `maxPixelDimension`, but by no more than this, to limit blur.
    public static let maxUpscale = 3.0

    /// Upper bound on the encoded PNG. Stay under the decimal reading of "500KB".
    public static let maxFileBytes = 500_000

    /// Imported images are downsampled to this before any processing, to bound memory and Vision time.
    public static let importMaxPixelDimension = 2048

    /// Smallest longest-side the content is shrunk to while trying to meet `maxFileBytes`.
    public static let minContentDimension = 96

    /// MSSticker `localizedDescription` limit.
    public static let maxNameLength = 150

    /// Longest side of the copy put on the pasteboard for other apps. Signal keeps transparency only for images with
    /// alpha up to 512×512 (larger ones become JPEG), and Telegram turns a pasted transparent PNG into a 512 px sticker.
    public static let pasteMaxPixelDimension = 512
}
