import Observation
import SwiftUI

// ============================================================================
// THE VIEW-MODEL PATTERN — copy this, do not invent a second one.
// ============================================================================
//
// Every screen in this app is a `View` + one `@Observable` model. The model
// owns state and talks to `AppModel`; the view owns layout and owns the
// model's *lifetime*. There is exactly one way to wire them:
//
//     @MainActor
//     @Observable
//     final class ThingScreenModel: ScreenModel {
//         private(set) var rows: [SessionRow] = []
//
//         private var app: AppModel?
//         private let subs = ScreenSubscriptions()
//
//         init() {}                                   // no dependencies here
//
//         func bind(to app: AppModel) { self.app = app }
//
//         func activate() async {
//             guard let app else { return }
//             // One task per stream. Every task recorded in `subs`.
//             subs.start { [weak self] in
//                 let stream = await app.someStream()
//                 for await value in stream {
//                     guard let self, !Task.isCancelled else { return }
//                     self.rows = value                // already on MainActor
//                 }
//             }
//         }
//
//         func deactivate() { subs.cancelAll() }
//     }
//
//     struct ThingScreen: View {
//         @State private var model = ThingScreenModel()
//         var body: some View {
//             List(model.rows) { ... }
//                 .screenModel(model)                  // <- the only wiring
//         }
//     }
//
// ── Why each piece is shaped that way ───────────────────────────────────────
//
// `init()` takes nothing.
//     `AppModel` lives in the environment and the environment is not readable
//     from a `View.init`. Making the model buildable without dependencies is
//     what lets it be a plain `@State`, which is what makes SwiftUI give it
//     ONE lifetime per view identity. A model built in `body` — or in the
//     view's `init` — is rebuilt on every re-render, and every rebuild starts
//     another set of stream tasks.
//
// `bind(to:)` is idempotent.
//     `.task` can run again for the same view identity (scene re-activation,
//     a `.task(id:)` retrigger). Binding twice must be free.
//
// `activate()` is called from `.task`, `deactivate()` from `.onDisappear`.
//     Both by ``SwiftUI/View/screenModel(_:)``, so no screen writes them by
//     hand and no screen forgets the second one.
//
// ── The cancellation story (read this one) ──────────────────────────────────
//
// The classic bug here is a leaked stream task per screen push: push the chat
// five times and five `for await` loops are still running, each holding a live
// model, each writing into a dead view. It compiles, it never crashes, and it
// shows up as "the app gets slower the longer you use it" plus messages
// appearing in the wrong session.
//
// Three rules make it structurally impossible:
//
// 1. **Every long-lived Task goes through `ScreenSubscriptions.start`.**
//    Never write a bare `Task { }` in a screen model. If you need a one-shot
//    (send a message, dispatch an action), it belongs in an `async` method the
//    *view* calls from a button — one await, no loop, nothing to leak.
//
// 2. **`deactivate()` is the only place anything is cancelled, and it cancels
//    everything.** It is idempotent and safe to call when nothing is running.
//
// 3. **Every `for await` body re-checks `Task.isCancelled` and holds `self`
//    weakly.** `AsyncStream` iteration does end on cancellation, but a stream
//    that is mid-emission can deliver one more value after `cancelAll()`;
//    without the check, that value lands in a model whose screen is gone.
//
// A fourth, non-obvious one:
//
// 4. **Do not restart subscriptions from `onChange`.** If a screen needs to
//    follow a *different* session, give the view `.id(sessionKey)`. That
//    changes the view's identity, which gives it a fresh `@State` model and a
//    fresh `.task` — old tasks cancelled by SwiftUI, new ones started once.
//    Re-subscribing in place is how you end up with two live subscriptions to
//    two different sessions writing into the same array. This is also what the
//    tablet detail pane does (spec 08 §11.2: the Flutter shell keys the chat
//    subtree `ValueKey('chat-<sessionKey>')` for exactly this reason).
//
// ── What a model may and may not touch ──────────────────────────────────────
//
// May: `AppModel`'s published values and its `async` methods; the Kit's
// `AsyncStream`s reached through `AppModel`.
//
// May not: the six Kit targets directly (no `SQLiteSessionStore`, no
// `SessionCoordinator` in a screen model — `AppModel` is the composition
// root and the only thing that owns them), UIKit, or another screen's model.
// ============================================================================

/// The contract ``SwiftUI/View/screenModel(_:)`` drives.
@MainActor
protocol ScreenModel: AnyObject, Observable {
    init()
    /// Wire dependencies. Called before ``activate()``. Must be idempotent.
    func bind(to app: AppModel)
    /// Start subscriptions. Called from `.task`; returns immediately after
    /// starting them (it does not park).
    func activate() async
    /// Cancel everything ``activate()`` started. Must be idempotent.
    func deactivate()
}

/// Holds the Tasks one screen started, so they die together and die once.
///
/// Not `Set<Task>` and not a `TaskGroup`: a group would require `activate()`
/// to stay suspended for the life of the screen, which means `.task` cannot
/// return and the model cannot be re-entered from a button. A recorded list
/// with one owner is the boring version that is easy to audit.
@MainActor
final class ScreenSubscriptions {
    private var tasks: [Task<Void, Never>] = []

    init() {}

    /// Starts a subscription loop and records it.
    ///
    /// The closure runs on the MainActor: assign straight to model properties,
    /// no `MainActor.run` hop, no `@Sendable` capture dance.
    func start(_ work: @MainActor @escaping () async -> Void) {
        tasks.append(Task { await work() })
    }

    /// Cancels and forgets every recorded task. Idempotent.
    func cancelAll() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
    }

    /// `true` while at least one subscription is recorded — use it to make
    /// `activate()` re-entrant-safe when a screen can be activated twice.
    var isActive: Bool { !tasks.isEmpty }
}

private struct ScreenModelLifecycle<Model: ScreenModel>: ViewModifier {
    let model: Model
    @Environment(AppModel.self) private var app

    func body(content: Content) -> some View {
        content
            .task {
                model.bind(to: app)
                await model.activate()
            }
            .onDisappear {
                model.deactivate()
            }
    }
}

extension View {
    /// Binds a screen model to `AppModel` and ties its subscriptions to this
    /// view's lifetime. Apply it once, on the screen's outermost view.
    ///
    /// The model must be held by `@State` in that same view — never built
    /// inline, never held by a parent that outlives the screen.
    func screenModel<Model: ScreenModel>(_ model: Model) -> some View {
        modifier(ScreenModelLifecycle(model: model))
    }
}
