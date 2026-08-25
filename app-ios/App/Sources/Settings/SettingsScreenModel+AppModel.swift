import Foundation
import RemotePiProtocol
import SwiftUI

// ============================================================================
// The adapter from the real app to ``SettingsHost``.
//
// Split from `SettingsScreenModel.swift` on purpose: everything above the line
// is `AppModel`-shaped and only builds inside the app target, everything in the
// model file is plain Swift and can be tested against a fake host.
// ============================================================================

/// The part of Settings' host surface that `AppModel` does **not** expose yet.
///
/// ## Why a protocol and a runtime cast
///
/// Settings needs eight peer/connection primitives that live behind
/// `AppModel`'s `private` store, directory, publisher and connection manager.
/// I am not allowed to edit `AppModel.swift`, and stubbing the calls out would
/// ship a revoke button that silently does nothing.
///
/// So: the surface is declared here, `AppModelSettingsHost` looks for it at
/// runtime, and until someone writes
///
/// ```swift
/// extension AppModel: SettingsAppModelBridge { … }
/// ```
///
/// every peer-mutating action fails **loudly** with ``SettingsWiringError``
/// instead of quietly succeeding. Adding that conformance is the entire
/// integration step — nothing in this directory changes.
///
/// Each member below names the `AppModel` internals it needs.
@MainActor
protocol SettingsAppModelBridge: AnyObject {
    /// `store.savePeer(record)` + `peers = try await store.loadPeers()`, then
    /// `publisher.publish(intent: .setNickname(record.peer))` — a nickname is
    /// part of the Owner's `mesh_versions` member entry.
    func settingsSavePeer(_ record: PeerRecord) async throws

    /// `peers = try await store.loadPeers()`; returns the new list.
    @discardableResult
    func settingsReloadPeers() async throws -> [PeerRecord]

    /// `directory.deleteSilent(peer)` — **not** `directory.delete(peer)`.
    /// See the trap note on ``SettingsHost/deletePeerSilent(_:)``.
    func settingsDeletePeerSilent(_ peer: PeerID) async throws

    /// `store.clearSelectedSession()` (or whatever
    /// `coordinator.restoreSelection()` reads) *and* `openedSession = nil`.
    func settingsClearSelectedSession() async

    /// Persist a peer-only pointer with **no** room half.
    func settingsSelectPeerWithoutRoom(_ peer: PeerID) async

    /// The machine the live socket is dialled into — the peer
    /// `startManagedSession` was built with, not `peers.first`.
    var settingsActivePeer: PeerID? { get }

    /// `tearDownConnection()`, exposed. Distinct from `connect()`, which tears
    /// down and immediately re-dials: after revoking the last pairing there is
    /// nothing to dial and the socket must simply stop.
    func settingsDisconnect() async

    /// `manager.subscribe(to:)` + `coordinator.start(watching:)` for exactly
    /// this set.
    func settingsSubscribe(to peers: [PeerID]) async

    /// `publisher.publish(allowEmpty:)`, with `MeshPublishResult` flattened to
    /// ``MembershipPublish`` so the screen model never imports the Kit.
    func settingsPublishMembership(allowEmpty: Bool) async -> MembershipPublish

    /// `BootCoordinator.reevaluate()`. The coordinator is `@State` in
    /// `RootShell` and is **not** in the environment, so Settings cannot reach
    /// it; route it through `AppModel` or inject the coordinator.
    func settingsReevaluateBootPhase()
}

/// Raised when a peer-mutating action is invoked before
/// ``SettingsAppModelBridge`` is wired. Deliberately user-visible: a revoke
/// that appears to work but leaves the pairing in place is far worse than an
/// error message.
struct SettingsWiringError: LocalizedError {
    let what: String
    var errorDescription: String? {
        "\(what) is not wired yet (AppModel does not conform to "
            + "SettingsAppModelBridge)."
    }
}

/// Adapts `AppModel` to ``SettingsHost``.
@MainActor
final class AppModelSettingsHost: SettingsHost {
    private let app: AppModel
    private let bridge: (any SettingsAppModelBridge)?

    init(app: AppModel) {
        self.app = app
        // `as Any` first: `AppModel` is `final` and does not (yet) declare the
        // conformance, and a direct `as?` on a final class the compiler knows
        // cannot conform is a warning. Going through `Any` asks the runtime
        // instead, which is exactly what we want — the answer changes the day
        // the conformance is added, with no edit here.
        self.bridge = (app as Any) as? SettingsAppModelBridge
    }

    // MARK: Pairings

    var peers: [PeerRecord] { app.peers }

    @discardableResult
    func reloadPeers() async throws -> [PeerRecord] {
        guard let bridge else { return app.peers }
        return try await bridge.settingsReloadPeers()
    }

    func savePeer(_ record: PeerRecord) async throws {
        guard let bridge else { throw SettingsWiringError(what: "Saving a nickname") }
        try await bridge.settingsSavePeer(record)
    }

    func deletePeerSilent(_ peer: PeerID) async throws {
        guard let bridge else { throw SettingsWiringError(what: "Revoking a pairing") }
        try await bridge.settingsDeletePeerSilent(peer)
    }

    // MARK: Relay

    var relayURL: String { app.relayURLText }

    func setRelayURL(_ url: String) {
        // `AppModel.relayURLText` writes through to `UserDefaults` in `didSet`.
        app.relayURLText = url
    }

    // MARK: Selection pointer

    var selectedSession: SessionKey? { app.openedSession?.key }

    func clearSelectedSession() async {
        await bridge?.settingsClearSelectedSession()
    }

    func selectPeerWithoutRoom(_ peer: PeerID) async {
        await bridge?.settingsSelectPeerWithoutRoom(peer)
    }

    // MARK: Connection

    var activePeer: PeerID? {
        // Falling back to `peers.first` mirrors what `startManagedSession`
        // actually dials today. It is an approximation and is wrong the moment
        // the app can dial a peer other than the first — hence the bridge.
        bridge?.settingsActivePeer ?? app.peers.first?.peer
    }

    func disconnect() async {
        // Without the bridge this is a no-op rather than a lie: `connect()`
        // tears the old socket down before dialling, so the *save-relay* path
        // is still correct. The revoke path is the one that needs a real
        // disconnect, and it fails earlier at `deletePeerSilent`.
        await bridge?.settingsDisconnect()
    }

    func reconnect() async {
        // `AppModel.connect()` tears down, re-dials, and calls
        // `restoreOpenedSessionIfNeeded()`, which restores the pointer as a
        // whole `SessionKey` — both halves, per spec 08 §9.1.
        //
        // ⚠️ Known divergence, reported to the integration agent:
        // `restoreOpenedSessionIfNeeded()` bails out when the stored
        // `PeerRecord.relayURL` host differs from the new one, which is
        // exactly the case this screen creates. The spec says carry the
        // pointer across a relay change; today it is dropped.
        await app.connect()
    }

    func subscribe(to peers: [PeerID]) async {
        await bridge?.settingsSubscribe(to: peers)
    }

    // MARK: Mesh

    func publishMembership(allowEmpty: Bool) async -> MembershipPublish {
        guard let bridge else {
            return .deferred("membership publishing is not wired")
        }
        return await bridge.settingsPublishMembership(allowEmpty: allowEmpty)
    }

    // MARK: Preferences / shell

    var onboardingCompleted: Bool {
        get { app.preferences.onboardingCompleted }
        set { app.preferences.onboardingCompleted = newValue }
    }

    func reevaluateBootPhase() {
        bridge?.settingsReevaluateBootPhase()
    }
}

extension SettingsScreenModel: ScreenModel {
    func bind(to app: AppModel) {
        bind(host: AppModelSettingsHost(app: app))
    }
}
