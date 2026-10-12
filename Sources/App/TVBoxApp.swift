import SwiftUI

@main
@MainActor
struct TVBoxApp: App {
    @StateObject private var catalog = CatalogStore()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(catalog)
                .preferredColorScheme(.dark)
        }
    }
}
