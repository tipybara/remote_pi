import Observation
import RemotePiProtocol
import SwiftUI

/// Which session the UI is pointed at, and the three hints the chat needs to
/// paint its top bar correctly on frame 1 (spec 08 §2.1, §8.2, §11.2).
///
/// ## Identity
///
/// The selection is `(PeerID, RoomID)` and nothing else — never a title, never
/// a `cwd`, never a list index, never `started_at`. `title`, `device` and
/// `online` ride along **only** as first-frame hints so the chat bar does not
/// flash "—" / "reconnecting" while its view model loads the real records.
/// They are display values: nothing may key, sort or compare on them.
///
/// The Flutter version normalises the epk on every comparison because it
/// stores it as a string in two different Base64 spellings. Here ``PeerID``
/// holds the 32 raw bytes, so `==` is already correct and ``sessionKey``
/// already stable — the normalisation the spec demands is structural rather
/// than a helper you can forget to call. That is the whole reason the Kit
/// models a peer as bytes.
///
/// ## Not restored across launches
///
/// By design (spec 08 §11.2): the app starts with nothing selected and the
/// detail pane shows its placeholder. The *store* separately persists a
/// last-open pointer for cold-start restore on Home; that is a different
/// thing, and it is restored as a whole `SessionKey`, never as half of one.
@MainActor
@Observable
final class SessionSelection {
    /// The selected session plus its first-frame display hints.
    struct Selected: Equatable, Sendable {
        let key: SessionKey
        /// Resolved title at selection time: room name → cwd basename →
        /// device nickname → short key.
        let title: String
        /// Device label: nickname → session name → short key.
        let device: String
        /// Whether the room was live when it was opened.
        let online: Bool
    }

    private(set) var current: Selected?

    init(current: Selected? = nil) {
        self.current = current
    }

    var key: SessionKey? { current?.key }

    /// Stable identity string for `ForEach`/`.id(...)` and for keying the
    /// detail pane so switching sessions tears the chat down and rebuilds it
    /// (`ValueKey('chat-<sessionKey>')`, spec 08 §11.2).
    var sessionKey: String? { current?.key.storageKey }

    /// `true` when `key` is the selected session. Use this for the tile
    /// highlight — and only in two-pane mode: on phone the list is covered by
    /// the pushed chat, so a persistent highlight is meaningless
    /// (`home_page.dart:432-437`).
    func matches(_ key: SessionKey) -> Bool {
        current?.key == key
    }

    /// Selecting the already-selected session is a **no-op**, so re-tapping
    /// the open row does not rebuild the detail pane (spec 08 §11.2). The
    /// hints are not refreshed either: they exist to bridge the first frame,
    /// and the chat by then has better values than these.
    func select(key: SessionKey, title: String, device: String, online: Bool) {
        guard current?.key != key else { return }
        current = Selected(key: key, title: title, device: device, online: online)
    }

    /// Drops the selection — the last session on a machine went away, or the
    /// pairing was revoked. The detail pane returns to its placeholder.
    func clear() {
        current = nil
    }
}

/// Dismisses a chat-scoped sheet when the selected session changes
/// (`DismissOnSessionChange`, spec 08 §11.2).
///
/// On tablet the detail pane can swap underneath an open sheet, leaving it
/// hovering over a different session — and any sub-picker stacked above it.
/// Apply this to **every** sheet opened from the chat (quick actions, model
/// picker, attach, session info). Home's sheets must not use it.
///
/// ```swift
/// .sheet(isPresented: $showQuickActions) {
///     QuickActionsSheet(...)
///         .dismissOnSessionChange(selection)
/// }
/// ```
private struct DismissOnSessionChange: ViewModifier {
    let selection: SessionSelection
    @Environment(\.dismiss) private var dismiss
    @State private var mounted: SessionKey?

    func body(content: Content) -> some View {
        content
            .onAppear { mounted = selection.key }
            .onChange(of: selection.key) { _, now in
                guard let mounted, mounted != now else { return }
                dismiss()
            }
    }
}

extension View {
    func dismissOnSessionChange(_ selection: SessionSelection) -> some View {
        modifier(DismissOnSessionChange(selection: selection))
    }
}
