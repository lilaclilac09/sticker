import SwiftUI

@main
struct StickerizeApp: App {
    @State private var library = LibraryModel()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(library)
                .onOpenURL { library.handle($0) }
        }
    }
}
