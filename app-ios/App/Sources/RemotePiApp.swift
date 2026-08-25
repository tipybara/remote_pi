import SwiftUI

@main
struct RemotePiApp: App {
    /// The composition root. One instance for the process, handed to the whole
    /// tree through the environment; `RootShell` owns boot, layout, navigation
    /// and selection on top of it.
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootShell()
                .environment(model)
        }
    }
}
