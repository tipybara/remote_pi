import Foundation

/// The `ScreenModel` conformance, split out so `HomeScreenModel.swift` itself
/// never names `AppModel` — that is what lets the model be built and driven in
/// a target that has no store, no socket and no SwiftUI scene.
extension HomeScreenModel: ScreenModel {
    func bind(to app: AppModel) {
        bind(backend: app)
    }
}
