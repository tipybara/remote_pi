import Foundation
import RemotePiProtocol

/// The per-session `list_models` cache (spec 08 §8.11, `actions_repository.dart:13-21`).
///
/// ## Why it is keyed by `SessionKey` and not by peer
///
/// Two sessions on the same Mac can run different models, and the catalogue
/// reply carries a `current` that belongs to exactly one of them. Caching per
/// machine would show session A's current model as ticked in session B's
/// picker — a wrong check mark on a destructive-ish switch.
///
/// ## Three invalidation paths, all of them explicit
///
/// 1. a local ``QuickActionsModel/setModel(_:)`` succeeded — we know `current`
///    moved, so the entry is dropped rather than patched;
/// 2. the room's `room_meta.model` disagrees with the cached `current` — an
///    external switch (another paired device, or `/model` in the TUI);
/// 3. the picker's refresh button.
///
/// There is deliberately **no TTL**. A time-based expiry would produce a
/// picker that is sometimes stale and sometimes not for reasons the user
/// cannot see; the three signals above cover every way the answer changes.
@MainActor
final class ModelCatalogueCache {
    /// Shared instance, so the catalogue survives the sheet being dismissed
    /// and re-opened — which is the whole point of caching it. MainActor
    /// isolation is what makes a mutable static safe here under Swift 6.
    static let shared = ModelCatalogueCache()

    private var entries: [SessionKey: ModelCatalogue] = [:]

    init() {}

    func value(for session: SessionKey) -> ModelCatalogue? {
        entries[session]
    }

    func store(_ catalogue: ModelCatalogue, for session: SessionKey) {
        entries[session] = catalogue
    }

    func invalidate(_ session: SessionKey) {
        entries.removeValue(forKey: session)
    }

    func invalidateAll() {
        entries.removeAll()
    }

    /// Drops the entry when the room's live `room_meta.model` disagrees with
    /// the cached `current` — invalidation path 2.
    ///
    /// Compares against `current`, not against the whole model list: a Pi that
    /// gains or loses a model without switching the active one has not
    /// invalidated anything the user is looking at, and refetching on every
    /// meta broadcast would put a round-trip behind every `working` flip.
    func invalidateIfCurrentDisagrees(with facts: RoomFacts, for session: SessionKey) {
        guard let liveName = facts.modelName, let cached = entries[session] else { return }
        guard let current = cached.current else { return }
        if current.name != liveName {
            entries.removeValue(forKey: session)
        }
    }
}
