import Observation
import SwiftUI

/// The launch gate (spec 08 §1.1).
///
/// ## Why this is a state machine and not `if model.isReady`
///
/// Boot is an **ordered async sequence with early exits**, and the order is
/// load-bearing:
///
/// 1. hydrate preferences;
/// 2. materialise/restore the Owner Ed25519 key. If the platform reports the
///    key cannot be synced, stop here — nothing else runs, and the gate is
///    **sticky**;
/// 3. record whether the key was *generated* or *restored* ("restored from
///    iCloud" is `false`, and that is what keeps an existing user out of the
///    wizard);
/// 4. install the key-sync watcher **only after** step 2 succeeded — the
///    platform emits an initial blob on subscribe, and subscribing earlier
///    makes the bridge think the Owner key changed and wipe the pairings it
///    just loaded;
/// 5. pull mesh membership from the relay **before** listing peers, so a
///    reinstall materialises its pairings;
/// 6. list peers → `hasPeer`;
/// 7. if `hasPeer && !onboardingCompleted`, force it true;
/// 8. restore the selection pointer — **both halves**, `(peer, room)`.
///
/// Collapsing that into a boolean loses the ordering, and every one of those
/// steps has a bug attached to getting it wrong. The phase is derived once, at
/// the end, by ``resolvePhase()``; the redirect rules are:
///
/// ```
/// not finished                        -> .booting
/// identity cannot sync                -> .syncRequired      (sticky)
/// identity generated && no peer       -> .onboarding
/// otherwise                           -> .home
/// ```
///
/// A **restored** identity with zero peers goes to `.home`, not `.onboarding`:
/// Home's first-pair empty state reads better than re-running the wizard
/// (spec 08 §1.1).
@MainActor
@Observable
final class BootCoordinator {
    enum Phase: Equatable {
        /// Full-screen spinner. No text, no logo (spec 08 §3).
        case booting
        /// Sticky hard gate: no Owner key means no app (spec 08 §4).
        case syncRequired(reason: String)
        /// Fresh identity, no pairings — run the 3-step wizard (spec 08 §5).
        case onboarding
        /// Everything else.
        case home
        /// Boot itself threw. Distinct from ``syncRequired`` so the UI can
        /// offer a plain retry without claiming iCloud is off.
        case failed(String)
    }

    private(set) var phase: Phase = .booting

    /// Same shape as a ``ScreenModel``: no dependencies in `init`, wired by
    /// ``bind(to:)``, so the shell can hold it in a plain `@State` and give it
    /// one lifetime. See `ScreenModel.swift` for why that matters.
    private var app: AppModel!
    /// Guards against a second `start()` from a re-entrant `.task` (a scene
    /// re-activation, a preview reload). Boot must run exactly once.
    private var started = false

    init() {}

    func bind(to app: AppModel) {
        guard self.app == nil else { return }
        self.app = app
        // Settings cannot see this object — it is `@State` in `RootShell` and
        // not in the environment — so it revokes through `AppModel` and this
        // hook brings the phase change back (spec 08 §9.3).
        app.bootPhaseDidChange = { [weak self] in self?.reevaluate() }
    }

    /// Runs the sequence once. Safe to call from `.task` on every render.
    func start() async {
        guard !started, app != nil else { return }
        started = true
        await app.boot()
        resolvePhase()
    }

    /// The Sync Required screen's "Check again" button (spec 08 §4).
    ///
    /// Re-runs the identity gate only. On any result that is no longer
    /// "cannot sync" it re-resolves the phase, which lands on `.onboarding`
    /// or `.home` exactly as a cold start would — the screen never decides
    /// where to go itself.
    func recheckIdentity() async {
        guard let app else { return }
        await app.reloadIdentity()
        resolvePhase()
    }

    /// Called by the wizard when it finishes **or is skipped** (spec 08 §5.5).
    /// Skipping leaves zero peers and lands on Home's first-pair empty state.
    func completeOnboarding() {
        guard let app else { return }
        app.preferences.onboardingCompleted = true
        resolvePhase()
    }

    /// Revoking the last pairing resets onboarding (spec 08 §9.3), which sends
    /// the user back through the wizard on the next resolve. Settings calls
    /// this after `revoke` so the shell reacts without a relaunch.
    func reevaluate() {
        resolvePhase()
    }

    /// The redirect table. The single place a phase is chosen.
    private func resolvePhase() {
        guard let app else { return }
        switch app.identity {
        case .pending:
            phase = .booting
        case .syncUnavailable(let reason):
            // Sticky: the only exit is `recheckIdentity()` returning something
            // else. Nothing in the shell may route away from here.
            phase = .syncRequired(reason: reason)
        case .failed(let reason):
            phase = .failed(reason)
        case .ready(let generated):
            if generated && !app.hasPeer && !app.preferences.onboardingCompleted {
                phase = .onboarding
            } else {
                // A user with pairings never re-runs the wizard, even if the
                // flag was lost (reinstall, restored backup).
                if app.hasPeer && !app.preferences.onboardingCompleted {
                    app.preferences.onboardingCompleted = true
                }
                phase = .home
            }
        }
    }
}
