import RemotePiProtocol
import RemotePiSession
import SwiftUI

/// Opening a session, in the one order that works (spec 08 §7.8).
///
/// ```
/// 1. await app.openChat(row)     // persist the pointer, retarget the socket,
///                                // request a sync — the peer is passed
///                                // explicitly, because Home can tap a machine
///                                // we are not currently dialled into
/// 2. selection.select(...)       // AFTER step 1, so the detail pane's fresh
///                                // model reads the already-updated pointer
/// 3. compact only: push .chat    // tablet does not navigate at all
/// ```
///
/// Step 2 before step 1 is a real bug, not a style preference: the tablet
/// detail pane rebuilds the moment the selection changes, and it would read
/// the *previous* stored pointer.
///
/// The three display values handed to ``SessionSelection`` are first-frame
/// hints for the chat's top bar (§8.2) and nothing more.
@MainActor
struct SessionOpener {
    let app: AppModel
    let selection: SessionSelection
    let navigator: AppNavigator
    let layout: LayoutClass

    func open(_ row: SessionRow) async {
        await app.openChat(row)
        selection.select(
            key: row.key,
            title: row.displayName,
            device: app.peer(row.key.peer)?.displayLabel ?? row.key.peer.shortDescription,
            online: app.isLive(row.key)
        )
        if layout == .compact {
            navigator.push(.chat(row.key))
        }
    }
}

extension PeerRecord {
    /// Device label: nickname → session name captured at pair time → short
    /// key (`_deviceFor`, spec 08 §7.8). Editable, so never a key or a sort
    /// input.
    var displayLabel: String {
        if let nickname, !nickname.isEmpty { return nickname }
        if let sessionName, !sessionName.isEmpty { return sessionName }
        return peer.shortDescription
    }
}
