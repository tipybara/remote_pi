import Foundation
import RemotePiProtocol
import RemotePiSession

// ============================================================================
// `AppModel` as Home's backend.
//
// Kept in its own file so `HomeScreenModel` never has to see `AppModel`, which
// is what lets the model compile and run in a test target that has no store,
// no socket and no SwiftUI scene.
//
// Every member is wired. The five that need `AppModel`'s `coordinator` and
// `store` forward to `AppModel+Screens.swift`, which is where they can reach
// them; this file stays a thin, readable conformance.
//
// One caveat survives integration: `deleteCachedSession` deletes the row from
// the store, but `RoomRegistry` has no `forget(_:)`, so a session that is
// still live reappears on the next announce. That is the documented behaviour
// (spec 08 §7.7 — "if the session comes back online it reappears"), not a bug,
// but a *dead* room stays gone only until the next cold start rebuilds the
// registry. Adding `RoomRegistry.forget(_:)` to the Kit is the real fix.
// ============================================================================

extension AppModel: HomeBackend {
    var isBooting: Bool { phase == .booting }

    /// `subscribe(to:)` re-sends the subscription AND both checks; since the
    /// relay answers identical polls again (review/62 D2), this genuinely
    /// refreshes rather than performing.
    func refreshLiveness() async {
        await manager?.subscribe(to: peers.map(\.peer))
    }

    // `peers` and `snapshot` are already published under those names; the
    // protocol renames them so a conformance cannot be satisfied by accident
    // by some future unrelated property.
    var homePeers: [PeerRecord] { peers }
    var homeSnapshot: RegistrySnapshot { snapshot }

    func openSession(_ row: SessionRow) async {
        await openChat(row)
    }

    @discardableResult
    func setLocalSessionName(_ session: SessionKey, to name: String?) async -> Bool {
        await homeSetLocalSessionName(session, to: name)
    }

    func renameSession(_ session: SessionKey, to displayName: String) async -> String? {
        // `AppModel.rename` reports through the shared `lastError`. Snapshot it
        // so an unrelated error that was already sitting there is not
        // mis-attributed to this rename. Replace the whole body once `AppModel`
        // grows a rename that returns its own failure.
        let before = lastError
        await rename(session, to: displayName)
        guard lastError != before else { return nil }
        return lastError
    }

    func deleteCachedSession(_ session: SessionKey) async -> String? {
        await homeDeleteCachedSession(session)
    }

    func listWorkspaces(on machine: PeerID) async throws -> [RemoteWorkspace] {
        try await homeListWorkspaces(on: machine)
    }

    func requestSession(_ intent: CreateSessionIntent) async throws -> SessionID {
        try await homeRequestSession(intent)
    }

    func waitForSession(_ session: SessionKey, timeout: Duration) async -> Bool {
        await homeWaitForSession(session, timeout: timeout)
    }
}
