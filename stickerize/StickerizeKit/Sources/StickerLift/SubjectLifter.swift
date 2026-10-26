import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import StickerizeKit
import Vision

public struct SubjectInstance: Identifiable, Hashable, Sendable {
    /// Vision instance id (1-based; 0 is background).
    public let id: Int
    /// Fraction of the image covered by this instance.
    public let areaFraction: Double
    /// Bounding box in image pixels, top-left origin.
    public let boundingBox: CGRect
}

public enum SubjectLiftError: LocalizedError {
    case noSubjects
    /// Vision couldn't run here (for example, the iOS Simulator has no Neural Engine model for this request).
    case unavailable(String)
    case unknownInstances(IndexSet)
    case renderFailed

    public var errorDescription: String? {
        switch self {
        case .noSubjects: "No subject was found in this image."
        case let .unavailable(reason): "Background removal isn't available on this device (\(reason))."
        case let .unknownInstances(ids): "Instance \(ids.map(String.init).joined(separator: ", ")) wasn't detected."
        case .renderFailed: "Couldn't cut out the subject."
        }
    }
}

/// Class-agnostic subject detection with Vision's foreground instance mask: every foreground object is its own
/// instance, so callers can pick exactly which ones to keep (Photos' "Add Sticker" only lifts its main subject).
public enum SubjectLifter {
    /// Runs the request synchronously; call off the main thread. `image` must already be upright
    /// (`ImageLoader` applies EXIF orientation), so Vision is told `.up`.
    public static func analyze(_ image: CGImage) throws -> SubjectAnalysis {
        try analyze(image, request: CancellableRequest())
    }

    /// Runs `analyze` off the caller's actor and stops Vision if the calling task is cancelled.
    public static func analyze(_ image: CGImage) async throws -> SubjectAnalysis {
        let request = CancellableRequest()
        let work = Task.detached(priority: .userInitiated) { () throws -> SubjectAnalysis in
            try analyze(image, request: request)
        }
        return try await withTaskCancellationHandler {
            let analysis = try await work.value
            try Task.checkCancellation()
            return analysis
        } onCancel: {
            request.cancel()
            work.cancel()
        }
    }

    private static func analyze(_ image: CGImage, request holder: CancellableRequest) throws -> SubjectAnalysis {
        let request = holder.start()
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        do {
            try handler.perform([request])
        } catch {
            if holder.isCancelled { throw CancellationError() }
            throw SubjectLiftError.unavailable(error.localizedDescription)
        }
        guard let observation = request.results?.first, !observation.allInstances.isEmpty else {
            throw SubjectLiftError.noSubjects
        }
        let labels = try LabelMap(observation.instanceMask)
        return SubjectAnalysis(image: image, observation: observation, handler: handler, labels: labels)
    }
}

/// Lets a cancellation handler on another thread cancel the Vision request in flight (VNRequest.cancel is thread safe).
private final class CancellableRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNGenerateForegroundInstanceMaskRequest?
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }

    func start() -> VNGenerateForegroundInstanceMaskRequest {
        lock.withLock {
            let request = VNGenerateForegroundInstanceMaskRequest()
            if cancelled { request.cancel() }
            self.request = request
            return request
        }
    }

    func cancel() {
        lock.withLock {
            cancelled = true
            request?.cancel()
        }
    }
}

/// The result of one Vision pass. Holds the request handler so different instance selections can be rendered
/// without re-running detection.
public final class SubjectAnalysis: @unchecked Sendable {
    public let image: CGImage
    /// Sorted by id.
    public let instances: [SubjectInstance]
    public var allInstanceIDs: IndexSet { observation.allInstances }

    private let observation: VNInstanceMaskObservation
    private let handler: VNImageRequestHandler
    private let labels: LabelMap
    private let lock = NSLock()

    fileprivate init(image: CGImage, observation: VNInstanceMaskObservation, handler: VNImageRequestHandler, labels: LabelMap) {
        self.image = image
        self.observation = observation
        self.handler = handler
        self.labels = labels
        // The label map has its own resolution (not necessarily the image's aspect ratio), so scale each axis separately.
        let sx = Double(image.width) / Double(labels.width)
        let sy = Double(image.height) / Double(labels.height)
        let total = Double(labels.width * labels.height)
        instances = labels.statistics()
            .filter { observation.allInstances.contains($0.key) }
            .sorted { $0.key < $1.key }
            .map { id, stats in
                let minX = (Double(stats.minX) * sx).rounded(.down)
                let minY = (Double(stats.minY) * sy).rounded(.down)
                let maxX = min(Double(image.width), (Double(stats.maxX + 1) * sx).rounded(.up))
                let maxY = min(Double(image.height), (Double(stats.maxY + 1) * sy).rounded(.up))
                return SubjectInstance(id: id, areaFraction: Double(stats.count) / total,
                                       boundingBox: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
            }
    }

    /// Instance under a point given in normalized image coordinates (0…1, top-left origin), or nil for background.
    public func instanceID(atNormalizedPoint point: CGPoint) -> Int? {
        guard (0...1).contains(point.x), (0...1).contains(point.y) else { return nil }
        let x = min(labels.width - 1, Int(point.x * CGFloat(labels.width)))
        let y = min(labels.height - 1, Int(point.y * CGFloat(labels.height)))
        let id = Int(labels.values[y * labels.width + x])
        return id == 0 ? nil : id
    }

    /// Color overlay at label-map resolution, meant to be stretched over the image's frame: selected instances are tinted
    /// with their palette color, unselected ones with a faint gray, background is clear.
    public func overlay(selected: IndexSet, palette: [(red: UInt8, green: UInt8, blue: UInt8)] = SubjectAnalysis.palette) -> CGImage? {
        let width = labels.width, height = labels.height
        guard let context = ImageOps.makeRGBAContext(width: width, height: height),
              let base = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let bytesPerRow = context.bytesPerRow
        for y in 0..<height {
            let row = base + y * bytesPerRow
            for x in 0..<width {
                let id = Int(labels.values[y * width + x])
                guard id != 0 else { continue }
                let pixel = row + x * 4
                if selected.contains(id) {
                    let color = palette[(id - 1) % palette.count]
                    let alpha = 0.45
                    pixel[0] = UInt8(Double(color.red) * alpha)
                    pixel[1] = UInt8(Double(color.green) * alpha)
                    pixel[2] = UInt8(Double(color.blue) * alpha)
                    pixel[3] = UInt8(255 * alpha)
                } else {
                    pixel[0] = 0; pixel[1] = 0; pixel[2] = 0; pixel[3] = 110
                }
            }
        }
        return context.makeImage()
    }

    /// Full-resolution cut-out of the chosen instances on a transparent background (sRGB RGBA8).
    public func render(instances ids: IndexSet, croppedToInstances: Bool = false) throws -> CGImage {
        let unknown = ids.subtracting(observation.allInstances)
        guard unknown.isEmpty else { throw SubjectLiftError.unknownInstances(unknown) }
        guard !ids.isEmpty else { throw SubjectLiftError.noSubjects }
        lock.lock()
        defer { lock.unlock() }
        let buffer = try observation.generateMaskedImage(ofInstances: ids, from: handler, croppedToInstancesExtent: croppedToInstances)
        let ciImage = CIImage(cvPixelBuffer: buffer)
        guard let image = SharedCIContext.context.createCGImage(ciImage, from: ciImage.extent, format: .RGBA8,
                                                                 colorSpace: ImageOps.sRGB) else {
            throw SubjectLiftError.renderFailed
        }
        return image
    }

    public static let palette: [(red: UInt8, green: UInt8, blue: UInt8)] = [
        (255, 59, 48), (0, 122, 255), (52, 199, 89), (255, 149, 0), (175, 82, 222), (255, 204, 0), (90, 200, 250), (255, 45, 85),
    ]
}

enum SharedCIContext {
    static let context = CIContext(options: [.cacheIntermediates: false])
}

/// Copy of Vision's per-pixel instance label buffer, with row padding removed.
struct LabelMap: Sendable {
    let width: Int
    let height: Int
    let values: [UInt8]

    struct Stats {
        var count = 0
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
    }

    init(_ buffer: CVPixelBuffer) throws {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        guard width > 0, height > 0, let base = CVPixelBufferGetBaseAddress(buffer) else { throw SubjectLiftError.renderFailed }
        var values = [UInt8](repeating: 0, count: width * height)
        // Read the format from the buffer instead of guessing from bytesPerRow / width, which row padding breaks.
        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<height {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width { values[y * width + x] = row[x] }
            }
        case kCVPixelFormatType_OneComponent32Float:
            for y in 0..<height {
                let row = base.advanced(by: y * bytesPerRow).assumingMemoryBound(to: Float32.self)
                for x in 0..<width { values[y * width + x] = UInt8(clamping: Int(row[x].rounded())) }
            }
        default:
            throw SubjectLiftError.unavailable("unexpected mask pixel format \(CVPixelBufferGetPixelFormatType(buffer))")
        }
        self.width = width
        self.height = height
        self.values = values
    }

    /// Pixel count and bounding box (label-map coordinates) for every non-zero id, in one pass.
    func statistics() -> [Int: Stats] {
        var stats: [Int: Stats] = [:]
        for y in 0..<height {
            for x in 0..<width {
                let id = Int(values[y * width + x])
                guard id != 0 else { continue }
                var entry = stats[id, default: Stats()]
                entry.count += 1
                entry.minX = min(entry.minX, x); entry.maxX = max(entry.maxX, x)
                entry.minY = min(entry.minY, y); entry.maxY = max(entry.maxY, y)
                stats[id] = entry
            }
        }
        return stats
    }
}
