import SwiftUI

@main
struct RemotePiApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environment(model)
                .task { await model.boot() }
        }
    }
}
