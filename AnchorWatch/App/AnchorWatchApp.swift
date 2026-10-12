import SwiftUI

@main
struct AnchorWatchApp: App {
    @StateObject private var engine = AnchorWatchEngine()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .onAppear { engine.start() }
        }
    }
}
