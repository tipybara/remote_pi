import RemotePiProtocol
import RemotePiSession

/// Presentation vocabulary for the Kit's ``SessionFilter``.
///
/// It lives in `Shell/` rather than in `HomeScreen.swift` because the filter's
/// labels and counts are shared vocabulary — Home renders the tabs, and the
/// tablet shell and any future search surface need the same three names in the
/// same order. A screen file is the wrong home for something another screen
/// depends on.
extension SessionFilter {
    /// Fixed order and labels (spec 08 §7.3): **All · Online · Offline**.
    /// The Kit's enum is intentionally not `CaseIterable` — case order is a
    /// presentation decision, and it is made here, once.
    static let ordered: [SessionFilter] = [.all, .online, .offline]

    var label: String {
        switch self {
        case .all: "All"
        case .online: "Online"
        case .offline: "Offline"
        }
    }
}

extension AppModel {
    /// Session count for one tab, **independent of the active tab**
    /// (spec 08 §7.3): the Online badge shows how many are online whether or
    /// not Online is selected.
    ///
    /// Cheap by construction — `SessionCatalog.build` is pure and synchronous
    /// over an in-memory snapshot — so it is fine to call once per tab per
    /// render. It does not touch the network or the store.
    func count(for filter: SessionFilter) -> Int {
        SessionCatalog.build(peers: peers, snapshot: snapshot, filter: filter)
            .reduce(0) { $0 + $1.sessions.count }
    }
}
