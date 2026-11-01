import SwiftUI

@main
struct PhotosTriApp: App {
    @StateObject private var lib = Library()
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(lib)
        }
    }
}
