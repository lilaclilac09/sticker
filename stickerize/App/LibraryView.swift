import PhotosUI
import StickerizeKit
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(LibraryModel.self) private var library
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showsPhotoPicker = false
    @State private var showsFileImporter = false
    @State private var showsSetup = false
    @State private var isSelecting = false
    @State private var selection = Set<UUID>()
    @State private var exportTarget: StickerActions.Messenger?
    @State private var confirmsDelete = false
    @State private var isDropTargeted = false
    @State private var path: [Sticker.ID] = []

    var body: some View {
        @Bindable var library = library
        NavigationStack(path: $path) {
            Group {
                if library.stickers.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .navigationTitle(isSelecting ? selectionTitle : String(localized: "Stickers"))
            .toolbar { toolbar }
            .navigationDestination(for: Sticker.ID.self) { id in
                StickerDetailView(stickerID: id)
            }
            .overlay {
                if library.isImporting {
                    ProgressView("Opening…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10]))
                        .padding(8)
                        .allowsHitTesting(false)
                }
            }
        }
        .photosPicker(isPresented: $showsPhotoPicker, selection: $photoItems, maxSelectionCount: 20,
                      matching: .images, preferredItemEncoding: .current)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await library.importPhotos(items) }
        }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: ImageImport.supportedTypes,
                      allowsMultipleSelection: true) { result in
            switch result {
            case let .success(urls): Task { await library.importFiles(urls) }
            case let .failure(error): library.show("Couldn't Open the File", error)
            }
        }
        .onDrop(of: ImageImport.supportedTypes, isTargeted: $isDropTargeted) { providers in
            // A tile dragged and released inside the app would otherwise be imported again as a duplicate.
            guard !library.isBusy,
                  !providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.stickerizeSticker.identifier) })
            else { return false }
            Task { await library.importProviders(providers) }
            return true
        }
        .sheet(item: $library.editorBatch) { batch in
            StickerEditorFlow(items: batch.items, store: library.store) { _ in
                library.finishEditing()
            }
        }
        .sheet(isPresented: $showsSetup) {
            SetupGuideView()
        }
        .sheet(item: $exportTarget) { messenger in
            ExportView(messenger: messenger, stickers: library.stickers.filter { selection.contains($0.id) },
                       onCancel: { exportTarget = nil },
                       onExported: {
                           exportTarget = nil
                           endSelection()
                       })
        }
        .alert(item: $library.message) { message in
            Alert(title: Text(message.title), message: Text(message.body))
        }
        .confirmationDialog(deleteTitle, isPresented: $confirmsDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                library.delete(selection)
                endSelection()
            }
        } message: {
            Text("They'll also disappear from Messages and the keyboard.")
        }
        .onChange(of: library.requestsPhotoPicker) { _, requested in
            guard requested else { return }
            library.requestsPhotoPicker = false
            showsPhotoPicker = true
        }
        #if DEBUG
        .task { await runDebugLaunchActions() }
        #endif
    }

    #if DEBUG
    private func runDebugLaunchActions() async {
        if DebugLaunch.reset { library.delete(Set(library.stickers.map(\.id))) }
        let paths = DebugLaunch.importPaths
        if !paths.isEmpty { await library.importFiles(paths.map { URL(fileURLWithPath: $0) }) }
        if DebugLaunch.copy, let first = library.stickers.first { try? StickerActions.copy(first, from: library.store) }
        switch DebugLaunch.screen {
        case "detail": if let first = library.stickers.first { path = [first.id] }
        case "setup": showsSetup = true
        case "select":
            isSelecting = true
            selection = Set(library.stickers.prefix(2).map(\.id))
        case "export-whatsapp", "export-telegram":
            isSelecting = true
            selection = Set(library.stickers.prefix(30).map(\.id))
            exportTarget = DebugLaunch.screen == "export-whatsapp" ? .whatsApp : .telegram
        default: break
        }
    }
    #endif

    // MARK: Content

    private var grid: some View {
        ScrollView {
            if library.store.location == .local {
                StorageWarning()
                    .padding(.horizontal)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96, maximum: 160), spacing: 12)], spacing: 12) {
                ForEach(library.stickers) { sticker in
                    tile(for: sticker)
                }
            }
            .padding()
        }
    }

    @ViewBuilder
    private func tile(for sticker: Sticker) -> some View {
        // A square cell with the sticker fitted inside, so rows line up whatever the sticker's shape.
        let thumbnail = Color(uiColor: .secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay { StickerThumbnail(sticker: sticker, store: library.store).padding(8) }
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityElement()
            .accessibilityLabel(Text(sticker.name))
        if isSelecting {
            Button {
                if selection.contains(sticker.id) { selection.remove(sticker.id) } else { selection.insert(sticker.id) }
            } label: {
                thumbnail
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: selection.contains(sticker.id) ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(selection.contains(sticker.id) ? Color.accentColor : .secondary)
                            .background(Circle().fill(.background))
                            .padding(6)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selection.contains(sticker.id) ? .isSelected : [])
        } else {
            NavigationLink(value: sticker.id) { thumbnail }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Copy", systemImage: "doc.on.doc") {
                        do { try StickerActions.copy(sticker, from: library.store) } catch { library.show("Couldn't Copy", error) }
                    }
                    ShareLink(item: StickerPNG(sticker: sticker, store: library.store),
                              preview: SharePreview(sticker.name))
                    Button("Move to Front", systemImage: "arrow.up.to.line") { library.moveToFront(sticker) }
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive) { library.delete([sticker.id]) }
                }
                .draggable(StickerPNG(sticker: sticker, store: library.store)) {
                    StickerThumbnail(sticker: sticker, store: library.store).frame(width: 120, height: 120)
                }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label {
                Text("Make Your First Sticker")
            } icon: {
                Image("StickerArt")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 140, height: 140)
            }
        } description: {
            Text("Pick a photo and Stickerize cuts out the subject. Your stickers show up in Messages, in the emoji keyboard's Stickers, and in the Stickerize keyboard.")
            if library.store.location == .local {
                StorageWarning()
            }
        } actions: {
            Group {
                // Semibold: white on the dark-mode accent is 3.4:1, which meets the bar for bold text.
                Button("Choose Photos") { showsPhotoPicker = true }
                    .buttonStyle(.borderedProminent)
                    .fontWeight(.semibold)
                Button("Choose Files") { showsFileImporter = true }
                PasteButton(supportedContentTypes: ImageImport.supportedTypes) { providers in
                    Task { await library.importProviders(providers) }
                }
            }
            .disabled(library.isBusy)
            Button("How to Use Your Stickers") { showsSetup = true }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        if isSelecting {
            ToolbarItem(placement: .topBarLeading) {
                Button(selection.count == library.stickers.count ? "Deselect All" : "Select All") {
                    selection = selection.count == library.stickers.count ? [] : Set(library.stickers.map(\.id))
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done", action: endSelection)
                    .fontWeight(.semibold)
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Button("Delete", systemImage: "trash", role: .destructive) { confirmsDelete = true }
                    .disabled(selection.isEmpty)
                Spacer()
                Menu("Add to…", systemImage: "square.and.arrow.up.on.square") {
                    ForEach(StickerActions.Messenger.allCases) { messenger in
                        Button("Add to \(messenger.name)") { exportTarget = messenger }
                            .disabled(!messenger.allowedCount.contains(selection.count))
                    }
                }
                .disabled(selection.isEmpty)
            }
        } else {
            ToolbarItem(placement: .topBarLeading) {
                Button("How to Use", systemImage: "questionmark.circle") { showsSetup = true }
            }
            if !library.stickers.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Select") { isSelecting = true }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu("Add", systemImage: "plus") {
                    Button("Photos", systemImage: "photo.on.rectangle") { showsPhotoPicker = true }
                    Button("Files", systemImage: "folder") { showsFileImporter = true }
                }
                .disabled(library.isBusy)
            }
            ToolbarItem(placement: .topBarTrailing) {
                PasteButton(supportedContentTypes: ImageImport.supportedTypes) { providers in
                    Task { await library.importProviders(providers) }
                }
                .labelStyle(.iconOnly)
                .disabled(library.isBusy)
            }
        }
    }

    private var selectionTitle: String {
        selection.isEmpty ? String(localized: "Select Stickers") : String(localized: "\(selection.count) Selected")
    }

    private var deleteTitle: String {
        selection.count == 1 ? String(localized: "Delete 1 sticker?") : String(localized: "Delete \(selection.count) stickers?")
    }

    private func endSelection() {
        isSelecting = false
        selection = []
    }
}

/// Shown when the build has no App Group entitlement, so the extensions can't see the library.
struct StorageWarning: View {
    var body: some View {
        Label {
            Text("The shared library isn't available, so these stickers won't appear in Messages or the keyboard. The app was built without its App Group entitlement.")
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
        .font(.footnote)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// Grid thumbnail, decoded at display size off the main thread and cached.
struct StickerThumbnail: View {
    let sticker: Sticker
    let store: StickerStore
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                Color.clear
            }
        }
        .task(id: sticker.id) {
            image = await ThumbnailCache.shared.image(for: sticker, store: store, pixelSize: Int(160 * displayScale))
        }
    }
}

final class ThumbnailCache: @unchecked Sendable {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, UIImage>()

    func image(for sticker: Sticker, store: StickerStore, pixelSize: Int) async -> UIImage? {
        let key = "\(sticker.id.uuidString)-\(pixelSize)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let url = store.fileURL(for: sticker)
        let image = await Task.detached(priority: .userInitiated) {
            ImageLoader.thumbnail(contentsOf: url, maxPixelSize: pixelSize).map { UIImage(cgImage: $0) }
        }.value
        if let image { cache.setObject(image, forKey: key) }
        return image
    }
}
