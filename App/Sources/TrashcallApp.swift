import SwiftUI
#if canImport(TrashcallCore)
import TrashcallCore
#elseif canImport(Trashcall)
import Trashcall
#endif

@main
struct TrashcallApp: App {
    var body: some Scene {
        WindowGroup {
            TrashcallDashboardView()
        }
    }
}
