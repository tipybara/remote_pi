import Foundation
import Observation
import RemotePiProtocol

/// The Quick Actions sheet's behaviour (spec 08 §8.11).
///
/// Testable without SwiftUI: it holds no `View`, no environment, no `AppModel`
/// — only a ``SessionActionsService`` and a ``SessionKey``.
///
/// ## What is stored and what is derived
///
/// The only stored state is "what did *this device* just do": which action is
/// in flight, and the model / thinking level a tap set locally. The displayed
/// model name and the selected thinking segment are **derived on every read**
/// from the room's live `room_meta`.
///
/// The Dart view model instead mirrors `room_meta` into its state through an
/// `activeRoomMetaStream` subscription (`quick_actions_viewmodel.dart:145-179`)
/// and has to hand-merge each snapshot with the busy flag so an in-flight call
/// does not lose its spinner. Deriving removes that merge, and with it the
/// class of bug where the mirror and the relay disagree.
///
/// Reading through to `AppModel.snapshot` inside a computed property is also
/// what keeps SwiftUI's observation correct: the read happens during `body`,
/// so the view re-renders when the relay announces a new meta. No stream, no
/// subscription, nothing to cancel.
@MainActor
@Observable
final class QuickActionsModel {
    // MARK: - Stored state

    /// Which action is in flight, or `nil`. Drives the 14pt spinner that
    /// replaces a row's trailing affordance and disables the row (§8.11).
    ///
    /// One at a time by construction: every action goes through ``run(_:_:)``,
    /// which refuses to start while `busy != nil`. Two concurrent
    /// `thinking_set` frames would race to set the same field on the Pi and
    /// the loser would silently win the UI.
    private(set) var busy: ActionName?

    /// The most recent failure, for the toast. Not part of a state enum: a
    /// failed action must leave the sheet *usable* so the next tap retries
    /// (`quick_actions_viewmodel.dart:19-21`).
    private(set) var errorMessage: String?

    /// `true` while the New Context confirmation is up.
    private(set) var isConfirmingNewContext = false

    /// Set once the Pi acks a `session_new` and the local mirror is wiped, so
    /// the presenting view knows to close the sheet.
    private(set) var didClearContext = false

    /// The model this device selected. Optimistic: set on tap, reverted on
    /// failure (§8.11, `:58-86`). Also the only structured record available —
    /// `room_meta` carries a display name and nothing else.
    private var localModel: WireModel?
    /// The `room_meta.model` value ``localModel`` replaced. See
    /// ``currentModelName`` for what it is for.
    private var supersededModelName: String?

    /// The thinking level this device selected, same optimistic shape.
    private var localThinking: ThinkingLevel?
    /// The `room_meta.thinking` value ``localThinking`` replaced.
    private var supersededThinking: ThinkingLevel?

    private var service: (any SessionActionsService)?
    private var session: SessionKey?

    init() {}

    /// Wire the model up. Idempotent for the same session; re-pointing it at a
    /// different session clears every local value, because those describe the
    /// old room and rendering them against the new one is exactly the "state
    /// keyed by the wrong thing" failure plan 61 is about.
    func bind(to service: any SessionActionsService, session: SessionKey) {
        if self.session != session {
            localModel = nil
            supersededModelName = nil
            localThinking = nil
            supersededThinking = nil
            busy = nil
            errorMessage = nil
            isConfirmingNewContext = false
            didClearContext = false
        }
        self.service = service
        self.session = session
    }

    // MARK: - Derived read models

    /// The room's live `(model, thinking)`. Read fresh every time — see the
    /// type doc for why there is no mirror.
    var facts: RoomFacts {
        guard let service, let session else { return .unknown }
        return service.facts(for: session)
    }

    /// `false` when the socket is down. The rows stay tappable — the failure
    /// is a toast, not a disabled state — but the sheet shows an offline note
    /// so a user is not left guessing why every tap toasts.
    var isOffline: Bool {
        service.map { !$0.isConnected } ?? true
    }

    /// The name shown on the Model row, and the value the picker's fallback
    /// check mark compares against.
    ///
    /// ## The stale-echo rule
    ///
    /// A local `model_set` is acked by `action_ok` well before the relay
    /// re-broadcasts `room_meta`, so for a beat the relay is still reporting
    /// the *old* name. Deferring to the relay unconditionally would flip the
    /// row back to the previous model right after a successful switch; never
    /// deferring to it would miss an external switch (another paired device,
    /// or `/model` in the TUI — spec 08 §8.11, `:155-160`).
    ///
    /// The tiebreak needs no clock: our value wins **only while the relay is
    /// still reporting the exact name our set replaced**. The moment it
    /// reports anything else — our new name, or a third name because someone
    /// else switched — the relay wins.
    var currentModelName: String? {
        if let localModel, facts.modelName == supersededModelName {
            return localModel.name
        }
        return facts.modelName ?? localModel?.name
    }

    /// The structured model, when the name we are showing is one we hold a
    /// record for. `nil` after an external switch — the picker refetches.
    var currentModel: WireModel? {
        guard let localModel, currentModelName == localModel.name else { return nil }
        return localModel
    }

    /// The thinking segment to highlight.
    ///
    /// Same stale-echo rule as ``currentModelName``. Note that most relay
    /// builds do not flatten `room_meta.thinking` at all
    /// (`actions_repository.dart:59-64`), so `facts.thinking` is usually
    /// `nil`; that is `nil == supersededThinking` on a first set, which is
    /// precisely why the local value has to be allowed to win — otherwise the
    /// segmented control would snap back on every tap and look broken.
    var currentThinking: ThinkingLevel? {
        if let localThinking, facts.thinking == supersededThinking {
            return localThinking
        }
        return facts.thinking ?? localThinking
    }

    /// Exactly what the Model row prints, placeholders included (§8.11).
    var modelRowLabel: String {
        if let currentModelName, !currentModelName.isEmpty { return currentModelName }
        return busy == .modelSet ? "Switching…" : "Choose a model"
    }

    func isBusy(_ action: ActionName) -> Bool { busy == action }

    /// Any row in flight disables the *whole* sheet's affordances, not just
    /// its own row — see ``busy``.
    var isAnyActionRunning: Bool { busy != nil }

    func dismissError() { errorMessage = nil }

    // MARK: - Actions

    /// Row 1. Returns `true` when the sheet should close.
    ///
    /// Success closes the sheet with **no toast**: compacting is quiet and
    /// frequent, and the toast was noise (§8.11). Failure keeps the sheet open
    /// with the message in ``errorMessage`` so the next tap retries.
    @discardableResult
    func compact() async -> Bool {
        await run(.sessionCompact) { service, session in
            try await service.compact(session)
        }
    }

    /// Row 2, step 1 — open the confirmation.
    ///
    /// Unlike Dart, the sheet is **not** closed before the dialog: SwiftUI
    /// presents an `.alert` over the sheet without a navigator to capture, and
    /// closing first is what forced the Flutter version to route failure
    /// toasts through a messenger captured from the page context
    /// (`quick_actions_sheet.dart:189-263`). Keeping the sheet up keeps the
    /// failure path in one place.
    func requestNewContext() {
        guard !isAnyActionRunning else { return }
        isConfirmingNewContext = true
    }

    func cancelNewContext() {
        isConfirmingNewContext = false
    }

    /// Row 2, step 2 — dispatch `session_new` and wipe the local mirror.
    ///
    /// `session_new` clears the context of the **same** session; it does not
    /// create one (spec 08 §13.4). The row is labelled "New Context" for that
    /// reason — the Flutter copy ("New session") describes something the frame
    /// does not do, and plan 61 renamed it.
    @discardableResult
    func confirmNewContext() async -> Bool {
        isConfirmingNewContext = false
        let ok = await run(.sessionNew) { service, session in
            try await service.newContext(session)
            // Only after `action_ok`. Wiping first would delete a transcript
            // the Pi still has whenever the action fails.
            await service.clearLocalTranscript(session)
        }
        if ok { didClearContext = true }
        return ok
    }

    /// Row 3's sub-picker result. Optimistic highlight, reverted on failure.
    @discardableResult
    func setModel(_ model: WireModel) async -> Bool {
        guard !isAnyActionRunning else { return false }
        let previousModel = localModel
        let previousSuperseded = supersededModelName
        // Capture what the relay is saying *now*, before the optimistic flip:
        // that is the name our set replaces, and the stale-echo rule keys off
        // it. Capturing it after would record our own new value.
        supersededModelName = facts.modelName
        localModel = model
        let ok = await run(.modelSet) { service, session in
            try await service.setModel(model, for: session)
        }
        if !ok {
            localModel = previousModel
            supersededModelName = previousSuperseded
        }
        return ok
    }

    /// Row 4. Same optimistic/revert shape as ``setModel(_:)``.
    @discardableResult
    func setThinking(_ level: ThinkingLevel) async -> Bool {
        guard !isAnyActionRunning else { return false }
        let previousLevel = localThinking
        let previousSuperseded = supersededThinking
        supersededThinking = facts.thinking
        localThinking = level
        let ok = await run(.thinkingSet) { service, session in
            try await service.setThinking(level, for: session)
        }
        if !ok {
            localThinking = previousLevel
            supersededThinking = previousSuperseded
        }
        return ok
    }

    /// Adopt a catalogue the picker loaded, so the Model row's label upgrades
    /// from the `room_meta` display name to a structured record.
    ///
    /// Only adopts when the catalogue actually names a current model — a
    /// cached entry with `current == nil` must not clobber a value we already
    /// learned from ``setModel(_:)`` (`quick_actions_viewmodel.dart:123-129`).
    func adopt(_ catalogue: ModelCatalogue) {
        guard let current = catalogue.current else { return }
        // The Pi's own answer, so it is not superseding anything: line it up
        // with the relay's name so the stale-echo rule reads "converged".
        supersededModelName = facts.modelName
        localModel = current
    }

    /// Report a failure raised by the sub-picker, which has no toast of its
    /// own — in Dart the picker's errors surface through the parent sheet's
    /// listener (`model_picker_sheet.dart:70-72`).
    func report(_ failure: ActionFailure) {
        errorMessage = failure.message
    }

    // MARK: - Internals

    /// The one place an action is dispatched: sets `busy`, runs, clears
    /// `busy`, and turns any throw into a message. Returns `true` on success.
    ///
    /// A single funnel is what makes "only one action in flight" true for
    /// every row at once, rather than four independent guards that a fifth row
    /// would forget to add.
    private func run(
        _ action: ActionName,
        _ body: @MainActor (any SessionActionsService, SessionKey) async throws -> Void
    ) async -> Bool {
        guard busy == nil else { return false }
        guard let service, let session else {
            errorMessage = ActionFailure.notWired.message
            return false
        }
        busy = action
        errorMessage = nil
        defer { busy = nil }
        do {
            try await body(service, session)
            return true
        } catch let failure as ActionFailure {
            errorMessage = failure.message
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

// MARK: - Thinking segments

/// The 6-way segmented control's contents (§8.11, `:514-558`).
///
/// A type rather than a dictionary in the view so the labels and the order are
/// testable, and so a level added to `ThinkingLevel` cannot ship with a
/// missing label: ``label(for:)`` is total.
enum ThinkingSegments {
    /// SDK order, `off` → `xhigh`. `ThinkingLevel.allCases` already declares
    /// it; naming it here documents that the order is intentional and not an
    /// accident of declaration order.
    static let ordered: [ThinkingLevel] = ThinkingLevel.allCases

    /// Short labels: `off · min · low · med · high · x`.
    static func label(for level: ThinkingLevel) -> String {
        switch level {
        case .off: "off"
        case .minimal: "min"
        case .low: "low"
        case .medium: "med"
        case .high: "high"
        case .xhigh: "x"
        }
    }

    /// The accessibility label, because `min` / `med` / `x` are unreadable
    /// aloud and the segment is otherwise a three-character target.
    static func accessibilityLabel(for level: ThinkingLevel) -> String {
        switch level {
        case .off: "Thinking off"
        case .minimal: "Minimal thinking"
        case .low: "Low thinking"
        case .medium: "Medium thinking"
        case .high: "High thinking"
        case .xhigh: "Extra high thinking"
        }
    }
}
