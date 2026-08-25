import Foundation
import RemotePiProtocol

/// Everything Settings needs from the app, as *primitives* rather than as one
/// `revoke()` call.
///
/// ## Why the protocol is this fine-grained
///
/// The whole risk in this screen is the **order** of the revoke steps
/// (spec 08 §9.3): delete silently, publish with `allowEmpty` computed from
/// what remains, re-subscribe, and only then re-dial. If `revoke` were a
/// single host method, that order would live in `AppModel` — untestable from a
/// package, and re-derivable only by reading it. Modelling the primitives puts
/// the order in ``SettingsScreenModel``, where a fake host can record the call
/// sequence and a test can assert it.
///
/// Everything is `@MainActor` because `AppModel` is; the async methods are the
/// ones that hop to an actor in the Kit.
@MainActor
protocol SettingsHost: AnyObject {
    // ── Pairings ───────────────────────────────────────────────────────────

    /// The current paired-machine list. Read inside `withObservationTracking`
    /// by the model, so the live implementation must forward to an
    /// `@Observable` storage — otherwise Settings will not notice a machine
    /// paired while the sheet is open.
    var peers: [PeerRecord] { get }

    /// Re-reads pairings from the store and refreshes ``peers``.
    @discardableResult
    func reloadPeers() async throws -> [PeerRecord]

    /// Upsert one record — the nickname edit. Goes through the *republishing*
    /// save: a nickname is part of the `mesh_versions` member entry, so the
    /// other devices of this Owner should learn it.
    func savePeer(_ record: PeerRecord) async throws

    /// Delete **without** firing the directory's republish hook (spec 08 §9.3
    /// step 3, trap T7). The hook's default publish is refused by the
    /// empty-membership safety net when this was the last machine, which
    /// leaves the relay holding a blob that still lists the revoked machine —
    /// and the next 60 s pull resurrects it locally.
    func deletePeerSilent(_ peer: PeerID) async throws

    // ── Relay ──────────────────────────────────────────────────────────────

    /// The effective relay URL right now (override, else the default).
    var relayURL: String { get }

    /// Persists the override. Does **not** reconnect — the model calls
    /// ``reconnect()`` afterwards so the order is visible at the call site.
    func setRelayURL(_ url: String)

    // ── Selection pointer (both halves, always) ────────────────────────────

    /// The persisted "last chat the user had open", as a whole ``SessionKey``.
    /// Never half of one — that is the plan-61 bug this client exists to not
    /// have (spec 08 §2.3).
    var selectedSession: SessionKey? { get }

    /// Drops the pointer entirely. Used when it points at the machine being
    /// revoked.
    func clearSelectedSession() async

    /// Points at a machine with **no room**. The room half belonged to the
    /// machine that was just revoked, so carrying it over would restore a
    /// session that does not exist on the fallback peer.
    func selectPeerWithoutRoom(_ peer: PeerID) async

    // ── Connection ─────────────────────────────────────────────────────────

    /// The machine the live socket is currently dialled into, if any.
    var activePeer: PeerID? { get }

    func disconnect() async

    /// Dial the relay again and restore the pointer — **both halves**
    /// (spec 08 §9.1). Reconnecting with the peer alone drops the user onto
    /// the machine's fallback room, i.e. a different chat than the one they
    /// were reading when they opened Settings.
    func reconnect() async

    /// Presence/room subscription for exactly this set of machines. After a
    /// revoke it must stop including the removed key, or the relay keeps
    /// pushing updates about a pairing this device no longer has.
    func subscribe(to peers: [PeerID]) async

    // ── Mesh membership ────────────────────────────────────────────────────

    /// Publishes the signed membership blob.
    ///
    /// - Parameter allowEmpty: **compute this as `remaining.isEmpty` at the
    ///   call site.** This is the only place in the app that opts out of the
    ///   empty-membership safety net; hard-coding `true` revokes every machine
    ///   the Owner has.
    func publishMembership(allowEmpty: Bool) async -> MembershipPublish

    // ── Preferences / shell ────────────────────────────────────────────────

    var onboardingCompleted: Bool { get set }

    /// Ask the shell to re-run the boot redirect table. Revoking the last
    /// pairing resets `onboardingCompleted`, and without this the user stays
    /// on a Home that has nothing in it until the next launch.
    func reevaluateBootPhase()
}

/// What a membership publish did, flattened to the two outcomes Settings can
/// act on.
///
/// The Kit's `MeshPublishResult` has eight cases; Settings only needs "the
/// relay now agrees" versus "it does not, and here is what to tell the user".
/// Flattening here keeps `RemotePiPairing` out of the screen model, which is
/// what lets the model compile and be tested without the Kit's actor graph.
enum MembershipPublish: Equatable, Sendable {
    /// Written, or folded into an in-flight publish that will carry it.
    case published
    /// Not written. The local pairing is still gone — this is a warning, never
    /// a failed revoke.
    case deferred(String)
}
