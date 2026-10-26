// Generates every icon image the project needs from one CoreGraphics drawing, and writes the asset catalogs'
// Contents.json files next to them.
//
//   swift scripts/make-icons.swift            (run from the stickerize/ folder)
//
// Outputs:
//   App/Assets.xcassets/AppIcon.appiconset                          single 1024² iOS icon (light, dark, tinted)
//   MessagesExtension/Assets.xcassets/iMessage App Icon.stickersiconset   every size Messages asks for

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

enum Variant { case light, dark, tinted }

/// A white die-cut sticker (rounded blob with a peeled corner and a smiling face) on a warm gradient.
/// `canvas` can be any aspect ratio; the sticker is centred and sized from the shorter side.
func draw(_ ctx: CGContext, canvas: CGSize, variant: Variant, opaqueBackground: Bool = true) {
    let w = canvas.width, h = canvas.height
    ctx.saveGState()
    if opaqueBackground {
        let colors: [CGColor]
        switch variant {
        case .light: colors = [color(0xFF7A59), color(0xF0437B), color(0x8B5CF6)]
        case .dark: colors = [color(0x3A1A2E), color(0x1E1230)]
        case .tinted: colors = [color(0x202020), color(0x000000)]
        }
        let gradient = CGGradient(colorsSpace: sRGB, colors: colors as CFArray, locations: nil)!
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
    }

    let s = min(w, h)
    let unit = s / 100
    ctx.translateBy(x: w / 2, y: h / 2)
    ctx.rotate(by: -8 * .pi / 180)

    // Sticker body: a squircle with the bottom-right corner folded back.
    let half = 31 * unit
    let corner = 14 * unit
    let fold = 16 * unit
    let body = CGMutablePath()
    body.move(to: CGPoint(x: -half + corner, y: half))
    body.addLine(to: CGPoint(x: half - corner, y: half))
    body.addQuadCurve(to: CGPoint(x: half, y: half - corner), control: CGPoint(x: half, y: half))
    body.addLine(to: CGPoint(x: half, y: -half + fold))
    body.addLine(to: CGPoint(x: half - fold, y: -half))
    body.addLine(to: CGPoint(x: -half + corner, y: -half))
    body.addQuadCurve(to: CGPoint(x: -half, y: -half + corner), control: CGPoint(x: -half, y: -half))
    body.addLine(to: CGPoint(x: -half, y: half - corner))
    body.addQuadCurve(to: CGPoint(x: -half + corner, y: half), control: CGPoint(x: -half, y: half))
    body.closeSubpath()

    let paper: CGColor = variant == .light ? color(0xFFFFFF) : variant == .dark ? color(0xF4EEF8) : color(0xFFFFFF)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -2.5 * unit), blur: 7 * unit, color: color(0x000000, 0.28))
    ctx.addPath(body)
    ctx.setFillColor(paper)
    ctx.fillPath()
    ctx.restoreGState()

    // The peeled flap, showing the sticker's back.
    let flap = CGMutablePath()
    flap.move(to: CGPoint(x: half, y: -half + fold))
    flap.addLine(to: CGPoint(x: half - fold, y: -half))
    flap.addQuadCurve(to: CGPoint(x: half - fold * 0.9, y: -half + fold * 0.9), control: CGPoint(x: half - fold * 1.15, y: -half + fold * 0.55))
    flap.closeSubpath()
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: -1 * unit, height: 1 * unit), blur: 3 * unit, color: color(0x000000, 0.25))
    ctx.addPath(flap)
    ctx.setFillColor(variant == .tinted ? color(0xBBBBBB) : color(0xE6DDF0))
    ctx.fillPath()
    ctx.restoreGState()

    // Face.
    let ink: CGColor = variant == .tinted ? color(0x111111) : color(0x2B1B3D)
    ctx.setFillColor(ink)
    for x in [-11.0, 11.0] {
        ctx.fillEllipse(in: CGRect(x: CGFloat(x) * unit - 4 * unit, y: 4 * unit, width: 8 * unit, height: 11 * unit))
    }
    if variant != .tinted {
        ctx.setFillColor(color(0xFF8FB1, 0.9))
        for x in [-19.0, 19.0] {
            ctx.fillEllipse(in: CGRect(x: CGFloat(x) * unit - 5 * unit, y: -6 * unit, width: 10 * unit, height: 6 * unit))
        }
    }
    let smile = CGMutablePath()
    smile.move(to: CGPoint(x: -12 * unit, y: -6 * unit))
    smile.addQuadCurve(to: CGPoint(x: 12 * unit, y: -6 * unit), control: CGPoint(x: 0, y: -20 * unit))
    ctx.addPath(smile)
    ctx.setStrokeColor(ink)
    ctx.setLineWidth(4.2 * unit)
    ctx.setLineCap(.round)
    ctx.strokePath()
    ctx.restoreGState()
}

func render(width: Int, height: Int, variant: Variant, opaqueBackground: Bool = true) -> CGImage {
    // App icons must not have an alpha channel; the tinted variant is grayscale-ish but stays RGB.
    let alpha: CGImageAlphaInfo = opaqueBackground ? .noneSkipLast : .premultipliedLast
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
                        bitmapInfo: alpha.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setAllowsAntialiasing(true)
    draw(ctx, canvas: CGSize(width: width, height: height), variant: variant, opaqueBackground: opaqueBackground)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination), "failed to write \(url.path)")
}

func writeJSON(_ object: Any, to url: URL) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: url)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let fm = FileManager.default

// MARK: App icon (Xcode 14+ single-size, with dark and tinted appearances)

let appIconSet = root.appendingPathComponent("App/Assets.xcassets/AppIcon.appiconset")
try! fm.createDirectory(at: appIconSet, withIntermediateDirectories: true)
writePNG(render(width: 1024, height: 1024, variant: .light), to: appIconSet.appendingPathComponent("AppIcon.png"))
writePNG(render(width: 1024, height: 1024, variant: .dark), to: appIconSet.appendingPathComponent("AppIcon-Dark.png"))
writePNG(render(width: 1024, height: 1024, variant: .tinted), to: appIconSet.appendingPathComponent("AppIcon-Tinted.png"))
writeJSON([
    "images": [
        ["filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"],
        ["appearances": [["appearance": "luminosity", "value": "dark"]],
         "filename": "AppIcon-Dark.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"],
        ["appearances": [["appearance": "luminosity", "value": "tinted"]],
         "filename": "AppIcon-Tinted.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"],
    ],
    "info": ["author": "xcode", "version": 1],
], to: appIconSet.appendingPathComponent("Contents.json"))
writeJSON(["info": ["author": "xcode", "version": 1]], to: root.appendingPathComponent("App/Assets.xcassets/Contents.json"))

// MARK: iMessage App Icon
// Xcode 27's actool still wants the multi-size set (a lone 1024×768 fails with "did not have any applicable content")
// and rejects the old 1x slots as "unassigned children". These 12 slots compile cleanly.

struct MessagesIcon { let idiom: String; let size: String; let scale: Int; let platform: String? }
let messagesIcons: [MessagesIcon] = [
    .init(idiom: "iphone", size: "29x29", scale: 2, platform: nil),
    .init(idiom: "iphone", size: "29x29", scale: 3, platform: nil),
    .init(idiom: "iphone", size: "60x45", scale: 2, platform: nil),
    .init(idiom: "iphone", size: "60x45", scale: 3, platform: nil),
    .init(idiom: "ipad", size: "29x29", scale: 2, platform: nil),
    .init(idiom: "ipad", size: "67x50", scale: 2, platform: nil),
    .init(idiom: "ipad", size: "74x55", scale: 2, platform: nil),
    .init(idiom: "universal", size: "27x20", scale: 2, platform: "ios"),
    .init(idiom: "universal", size: "27x20", scale: 3, platform: "ios"),
    .init(idiom: "universal", size: "32x24", scale: 2, platform: "ios"),
    .init(idiom: "universal", size: "32x24", scale: 3, platform: "ios"),
    .init(idiom: "ios-marketing", size: "1024x768", scale: 1, platform: "ios"),
]
let messagesAssets = root.appendingPathComponent("MessagesExtension/Assets.xcassets")
let messagesIconSet = messagesAssets.appendingPathComponent("iMessage App Icon.stickersiconset")
try! fm.createDirectory(at: messagesIconSet, withIntermediateDirectories: true)
var images: [[String: Any]] = []
for icon in messagesIcons {
    let parts = icon.size.split(separator: "x").map { Double($0)! }
    let width = Int(parts[0] * Double(icon.scale)), height = Int(parts[1] * Double(icon.scale))
    let name = "icon-\(icon.idiom)-\(icon.size)@\(icon.scale)x.png"
    writePNG(render(width: width, height: height, variant: .light), to: messagesIconSet.appendingPathComponent(name))
    var entry: [String: Any] = ["filename": name, "idiom": icon.idiom, "scale": "\(icon.scale)x", "size": icon.size]
    if let platform = icon.platform { entry["platform"] = platform }
    images.append(entry)
}
writeJSON(["images": images, "info": ["author": "xcode", "version": 1]], to: messagesIconSet.appendingPathComponent("Contents.json"))
writeJSON(["info": ["author": "xcode", "version": 1]], to: messagesAssets.appendingPathComponent("Contents.json"))

// A transparent version of the artwork for in-app use (empty states, onboarding).
let artSet = root.appendingPathComponent("App/Assets.xcassets/StickerArt.imageset")
try! fm.createDirectory(at: artSet, withIntermediateDirectories: true)
writePNG(render(width: 600, height: 600, variant: .light, opaqueBackground: false), to: artSet.appendingPathComponent("StickerArt.png"))
writeJSON([
    "images": [["filename": "StickerArt.png", "idiom": "universal", "scale": "3x"]],
    "info": ["author": "xcode", "version": 1],
], to: artSet.appendingPathComponent("Contents.json"))

print("icons written")
