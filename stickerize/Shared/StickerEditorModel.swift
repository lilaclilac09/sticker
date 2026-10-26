import CoreGraphics
import Foundation
import Observation
import StickerizeKit
import StickerLift

enum OutlineStyle: String, CaseIterable, Identifiable {
    case none, thin, medium, thick

    var id: Self { self }

    /// Width as a fraction of the sticker's longest side.
    var fraction: Double {
        switch self {
        case .none: 0
        case .thin: 0.015
        case .medium: 0.03
        case .thick: 0.05
        }
    }

    var title: String {
        switch self {
        case .none: String(localized: "None")
        case .thin: String(localized: "Thin")
        case .medium: String(localized: "Medium")
        case .thick: String(localized: "Thick")
        }
    }
}

/// State for editing one imported image: subject detection, which instances to keep, crop/outline, name, and saving.
@MainActor
@Observable
final class StickerEditorModel {
    enum Subjects {
        case detecting
        case found(SubjectAnalysis)
        /// Vision isn't available (e.g. the iOS Simulator) or found nothing; the whole image is used.
        case unavailable(String)
    }

    let item: ImportedImage
    /// The decoded image; nil until `prepare()` has decoded it.
    private(set) var source: CGImage?
    /// Set when the image couldn't be decoded after all.
    private(set) var loadError: String?
    var name: String
    var emoji = ""
    var removeBackground: Bool { didSet { scheduleRender() } }
    var cropToSubject = true { didSet { scheduleRender() } }
    var outline: OutlineStyle = .none { didSet { scheduleRender() } }
    private(set) var selected = IndexSet()
    private(set) var subjects: Subjects = .detecting
    /// Rendered sticker at working resolution (before size normalization).
    private(set) var preview: CGImage?
    /// Tint over the source showing which instances are kept.
    private(set) var overlay: CGImage?
    private(set) var isRendering = false
    private(set) var isSaving = false
    var errorMessage: String?

    private var renderTask: Task<Void, Never>?

    init(item: ImportedImage) {
        self.item = item
        name = item.suggestedName
        removeBackground = true
    }

    var analysis: SubjectAnalysis? {
        if case let .found(analysis) = subjects { analysis } else { nil }
    }

    /// True when the cut-out would be empty.
    var nothingSelected: Bool { removeBackground && analysis != nil && selected.isEmpty }

    var canSave: Bool {
        guard source != nil, !isSaving, !nothingSelected else { return false }
        if case .detecting = subjects { return false }
        return true
    }

    /// Decodes the image, then finds its subjects. Both run off the main actor.
    func prepare() async {
        let item = item
        let decoded = await Task.detached(priority: .userInitiated) {
            Result { () throws -> (image: CGImage, transparent: Bool) in
                let image = try item.decode()
                return (image, ImageOps.hasTransparency(image))
            }
        }.value
        // The editor went away (Skip/Cancel) while decoding: don't start Vision for nothing.
        guard !Task.isCancelled else { return }
        switch decoded {
        case let .success(result):
            // Already-transparent images (existing stickers, logos) usually shouldn't be cut again.
            removeBackground = !result.transparent
            source = result.image
            await detectSubjects(in: result.image)
        case let .failure(error):
            loadError = Self.describe(error)
        }
    }

    private func detectSubjects(in image: CGImage) async {
        let result: Result<SubjectAnalysis, Error>
        do {
            result = .success(try await SubjectLifter.analyze(image))
        } catch is CancellationError {
            return
        } catch {
            result = .failure(error)
        }
        guard !Task.isCancelled else { return }
        switch result {
        case let .success(analysis):
            subjects = .found(analysis)
            selected = analysis.allInstanceIDs
        case let .failure(error):
            subjects = .unavailable(Self.unavailableMessage(for: error))
        }
        refreshOverlay()
        scheduleRender()
    }

    func toggle(_ id: Int) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
        refreshOverlay()
        scheduleRender()
    }

    func selectAll() {
        guard let analysis else { return }
        selected = analysis.allInstanceIDs
        refreshOverlay()
        scheduleRender()
    }

    /// `point` is in normalized image coordinates (0…1, top-left origin).
    func toggleInstance(atNormalizedPoint point: CGPoint) {
        guard let id = analysis?.instanceID(atNormalizedPoint: point) else { return }
        toggle(id)
    }

    /// Encodes and saves the sticker. Returns false (and sets `errorMessage`) on failure.
    func save(to store: StickerStore) async -> Bool {
        guard canSave, let image = source else { return false }
        isSaving = true
        defer { isSaving = false }
        let analysis = analysis, recipe = recipe, name = name
        let emoji = emoji.isEmpty ? nil : emoji
        do {
            try await Task.detached(priority: .userInitiated) {
                let encoded = try StickerMaker.make(image, analysis: analysis, recipe: recipe)
                try store.add(encoded, name: name, emoji: emoji)
            }.value
            return true
        } catch {
            errorMessage = Self.describe(error)
            return false
        }
    }

    /// Stops pending work when the editor leaves the screen.
    func cancelPendingWork() {
        renderTask?.cancel()
    }

    // MARK: Private

    private var recipe: StickerRecipe {
        StickerRecipe(removeBackground: removeBackground && analysis != nil, instances: selected,
                      cropToSubject: cropToSubject, outlineFraction: outline.fraction)
    }

    private func refreshOverlay() {
        overlay = analysis?.overlay(selected: selected)
    }

    private func scheduleRender() {
        renderTask?.cancel()
        guard let image = source else { return }
        if case .detecting = subjects { return }
        guard !nothingSelected else {
            preview = nil
            isRendering = false
            return
        }
        let analysis = analysis, recipe = recipe
        isRendering = true
        let previous = renderTask
        renderTask = Task {
            // At most one render in flight: a cancelled wrapper still waits for its detached render, so awaiting it
            // serializes renders while a burst of changes collapses into the latest recipe.
            await previous?.value
            // Coalesce quick successive toggles.
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            let result = await Task.detached(priority: .userInitiated) {
                Result { try StickerMaker.render(image, analysis: analysis, recipe: recipe) }
            }.value
            guard !Task.isCancelled else { return }
            isRendering = false
            switch result {
            case let .success(rendered): preview = rendered
            case let .failure(error): errorMessage = Self.describe(error)
            }
        }
    }

    private static func unavailableMessage(for error: Error) -> String {
        switch error {
        case SubjectLiftError.noSubjects:
            return String(localized: "No subject found, so the whole image is used.")
        default:
            #if targetEnvironment(simulator)
            return String(localized: "Background removal doesn't run in the iOS Simulator, so the whole image is used.")
            #else
            return String(localized: "Background removal isn't available on this device, so the whole image is used.")
            #endif
        }
    }

    static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
