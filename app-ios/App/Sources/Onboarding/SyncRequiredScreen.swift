import Observation
import SwiftUI

/// The Sync Required gate's own tiny state machine (spec 08 §4).
///
/// One boolean in the Flutter original (`_checking`). It gets a second one
/// here: whether the last check changed nothing. See
/// ``SyncRequirements/stillUnavailable``.
@MainActor
@Observable
final class SyncRequiredModel {
    private(set) var isChecking = false
    /// `true` after a `Check again` that left us on this screen.
    private(set) var lastCheckFoundNothing = false

    init() {}

    /// Runs one re-check.
    ///
    /// The screen does **not** decide where to go. `recheck` re-runs the
    /// identity gate and re-resolves the boot phase; if sync became available
    /// the shell replaces this view, and this model's tail simply never
    /// matters. If it did not, we are still here and say so.
    ///
    /// Re-entrancy is guarded here rather than only by disabling the button: a
    /// double-tap can land two touches before the first `isChecking = true`
    /// propagates to the button's `disabled` state.
    func recheck(_ perform: () async -> Void) async {
        guard !isChecking else { return }
        isChecking = true
        lastCheckFoundNothing = false
        await perform()
        isChecking = false
        lastCheckFoundNothing = true
    }
}

/// `/sync-required` — a hard, **sticky** gate (spec 08 §4).
///
/// The Owner Ed25519 key has no persistence path other than iCloud Keychain;
/// without it the app cannot proceed, and a user who got past this screen with
/// no key would pair a device whose identity dies with the app's container.
///
/// The stickiness is structural and lives in `BootCoordinator`: this is a whole
/// -app *phase*, not a route, so there is no stack to pop, no tab to switch and
/// no sheet to dismiss. That is also why this screen deliberately offers **no**
/// "continue anyway", "skip", or "remind me later" affordance — the only exit
/// is `recheck` reporting that the key can be stored. Do not add one.
struct SyncRequiredScreen: View {
    /// Diagnostic detail from the identity gate. May be empty.
    let reason: String
    let recheck: () async -> Void

    @State private var model = SyncRequiredModel()
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            theme.colors.bg.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Image(systemName: "icloud.slash")
                            .font(.system(size: 44, weight: .light))
                            .foregroundStyle(theme.colors.accent)
                            .accessibilityHidden(true)
                            .padding(.top, 24)
                            .padding(.bottom, 20)

                        Text(SyncRequirements.title)
                            .font(theme.type.mono(20, weight: .semibold))
                            .foregroundStyle(theme.colors.text)
                            .padding(.bottom, 10)

                        Text(SyncRequirements.why)
                            .font(theme.type.mono(12))
                            .foregroundStyle(theme.colors.muted2)
                            .lineSpacing(4)
                            .fixedSize(horizontal: false, vertical: true)

                        // The gate's own words, when it had any. Kept separate
                        // from the fixed "why" copy so a Keychain error string
                        // never reads as product text.
                        if !reason.trimmingCharacters(in: .whitespaces).isEmpty,
                           reason != SyncRequirements.why {
                            Text(reason)
                                .font(theme.type.mono(11))
                                .foregroundStyle(theme.colors.muted)
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 10)
                        }

                        Text(SyncRequirements.listLabel)
                            .font(theme.type.mono(11, weight: .semibold))
                            .tracking(0.4)
                            .foregroundStyle(theme.colors.muted)
                            .padding(.top, 20)
                            .padding(.bottom, 10)

                        VStack(spacing: 10) {
                            ForEach(SyncRequirements.ios) { requirement in
                                RequirementCard(requirement: requirement)
                            }
                        }

                        if model.lastCheckFoundNothing {
                            Text(SyncRequirements.stillUnavailable)
                                .font(theme.type.mono(11))
                                .foregroundStyle(theme.colors.warning)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 14)
                                // Announced, not just drawn: the user tapped a
                                // button and the only feedback is this line.
                                .accessibilityAddTraits(.updatesFrequently)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 20)
                }
                .scrollBounceBehavior(.basedOnSize)

                PrimaryButton(title: SyncRequirements.checkAgain, isBusy: model.isChecking) {
                    Task { await model.recheck(recheck) }
                }
                .padding(.bottom, 32)
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: AppMetrics.onboardingMaxWidth)
        }
    }
}

/// A numbered instruction card (`sync_required_page.dart:182-262`).
struct RequirementCard: View {
    let requirement: SyncRequirement

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(requirement.number)")
                .font(theme.type.mono(11, weight: .semibold))
                .foregroundStyle(theme.colors.accent)
                .frame(width: 22, height: 22)
                .background(theme.colors.accent.opacity(0.15), in: Circle())
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(requirement.title)
                    .font(theme.type.mono(13, weight: .semibold))
                    .foregroundStyle(theme.colors.text)
                Text(requirement.path)
                    .font(theme.type.mono(11))
                    .foregroundStyle(theme.colors.muted2)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(requirement.spokenPath)
                if let note = requirement.note {
                    Text(note)
                        .font(theme.type.mono(10.5))
                        .italic()
                        .foregroundStyle(theme.colors.muted)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(theme.colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(theme.colors.border, lineWidth: AppMetrics.hairline)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        // `.contain`, not `.combine`: combining then overriding the label is
        // how these cards would end up announcing "Step 1. Sign in to iCloud"
        // and silently dropping the path and the note — which are the only
        // parts that tell the user what to actually do.
        .accessibilityElement(children: .contain)
    }
}
