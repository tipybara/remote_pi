import RemotePiProtocol
import SwiftUI

/// One paired machine (spec 08 §9.3, `peer_list_item.dart`).
///
/// Title is the nickname when there is one, with the pair-time session name as
/// a muted second line so the machine is still recognisable after it is
/// renamed. Trailing pencil opens the nickname editor.
///
/// ## Revoke
///
/// Swipe end-to-start, exactly like the Flutter `Dismissible` — but through
/// `.swipeActions`, which does **not** remove the row itself. That is the
/// behaviour the spec's `confirmDismiss` contract wants for free: the row only
/// disappears when the model has actually revoked the pairing, so a cancelled
/// confirmation "snaps back" without any restore logic.
///
/// `allowsFullSwipe: false` on purpose. A full swipe would fire a destructive,
/// non-undoable action — one that requires re-pairing from the Mac — off a
/// gesture with no deliberate stop.
///
/// A `.contextMenu` duplicates both actions: swipe actions are discoverable
/// only by trying, and VoiceOver surfaces them as rotor items rather than as
/// buttons. Neither path skips the confirmation.
struct PeerRow: View {
    let record: PeerRecord
    let isRevoking: Bool
    let onEditNickname: () -> Void
    let onRevoke: () -> Void

    @Environment(\.theme) private var theme

    private var hasNickname: Bool {
        guard let nickname = record.nickname else { return false }
        return !nickname.isEmpty
    }

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.displayLabel)
                    .font(theme.type.sans(14, weight: .medium))
                    .foregroundStyle(theme.colors.text)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if hasNickname, let sessionName = record.sessionName, !sessionName.isEmpty {
                    Text(sessionName)
                        .font(theme.type.sans(12))
                        .foregroundStyle(theme.colors.muted2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                // The hostname is the only thing that separates two machines
                // sharing a nickname, so it is worth the line when it differs
                // from what is already shown. The Flutter row has an empty
                // "platform" slot here waiting on a protocol field that still
                // does not exist; `hostname` does exist and does the job.
                if let hostname = record.hostname,
                   !hostname.isEmpty,
                   hostname != record.displayLabel,
                   hostname != record.sessionName {
                    Text(hostname)
                        .font(theme.type.mono(11))
                        .foregroundStyle(theme.colors.muted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            if isRevoking {
                ProgressView()
                    .controlSize(.small)
                    .tint(theme.colors.muted)
                    .frame(width: 34, height: 34)
            } else {
                Button(action: onEditNickname) {
                    Image(systemName: "pencil")
                        .font(.system(size: 15))
                        .foregroundStyle(theme.colors.muted2)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit nickname")
            }
        }
        .padding(.leading, AppMetrics.gutter)
        .padding(.trailing, 6)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.colors.bg)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.colors.border)
                .frame(height: AppMetrics.hairline)
        }
        .contentShape(Rectangle())
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive, action: onRevoke) {
                Label("Revoke", systemImage: "trash")
            }
        }
        .contextMenu {
            Button("Edit nickname", systemImage: "pencil", action: onEditNickname)
            Button("Revoke", systemImage: "trash", role: .destructive, action: onRevoke)
        }
        .disabled(isRevoking)
        .accessibilityElement(children: .combine)
    }
}
